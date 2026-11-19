import 'dart:convert';
import 'dart:math';
import 'package:cryptography/cryptography.dart';
import 'package:http/http.dart' as http;
import 'api_service.dart';

/// The app's side of the AI enclave proxy (docs/ENCRYPTED_AI.md). The request is encrypted here to the proxy's key, so
/// the orchestrator in between relays ciphertext only; the answer comes back encrypted to a one-time key of ours.
class EnclaveClient {
  EnclaveClient._();
  static final instance = EnclaveClient._();
  /// The measurement this build trusts (SHA-256 of services/enclave/enclave.py), pinned at build time.
  static const pinned = String.fromEnvironment('ENCLAVE_MEASUREMENT');
  Map<String, dynamic>? att; String status = 'not checked'; DateTime? _at;

  /// Fetch and check the attestation. Hardware reports are not verified by this build yet, so only the software proxy
  /// ("none") is usable, and only with the organisation's permission; a measurement that differs from the pinned one
  /// is refused (a changed proxy).
  Future<bool> check(ApiService api, {required bool unattestedAllowed}) async {
    if (_at != null && DateTime.now().difference(_at!) < const Duration(minutes: 10) && att != null) return usable(unattestedAllowed);
    try {
      final r = await http.get(api.url('/v1/ai/enclave/attestation'), headers: api.headers);
      if (r.statusCode != 200) { att = null; status = 'no enclave'; return false; }
      att = jsonDecode(r.body) as Map<String, dynamic>; _at = DateTime.now();
    } catch (_) { att = null; status = 'no enclave'; return false; }
    return usable(unattestedAllowed);
  }
  bool usable(bool unattestedAllowed) {
    final a = att; if (a == null) return false;
    if (pinned.isNotEmpty && a['measurement'] != pinned) { status = 'refused: the proxy is not the build this app trusts'; return false; }
    if (a['type'] != 'none') { status = 'refused: hardware attestation reports cannot be verified by this build yet'; return false; }
    if (!unattestedAllowed) { status = 'not allowed: the proxy is not hardware-attested'; return false; }
    status = 'software proxy (not hardware-attested)'; return true;
  }

  Future<String> ask(ApiService api, {required String prompt, String context = '', String system = ''}) async {
    final pk = base64.decode(att!['public_key'] as String);
    final x = X25519(); final kp = await x.newKeyPair(); final epk = (await kp.extractPublicKey()).bytes;
    final shared = await x.sharedSecretKey(keyPair: kp, remotePublicKey: SimplePublicKey(pk, type: KeyPairType.x25519));
    final hk = Hkdf(hmac: Hmac.sha256(), outputLength: 32);
    Future<SecretKey> key(String info) => hk.deriveKey(secretKey: shared, nonce: [...epk, ...pk], info: utf8.encode(info));
    final aes = AesGcm.with256bits(); final rnd = Random.secure();
    final nonce = List<int>.generate(12, (_) => rnd.nextInt(256));
    final box = await aes.encrypt(utf8.encode(jsonEncode({'prompt': prompt, 'context': context, 'system': system})), secretKey: await key('amer-enclave-v1 request'), nonce: nonce);
    final r = await http.post(api.url('/v1/ai/enclave/infer'), headers: api.headers, body: jsonEncode({'v': 1, 'epk': base64.encode(epk),
        'nonce': base64.encode(nonce), 'ct': base64.encode([...box.cipherText, ...box.mac.bytes])}));
    if (r.statusCode != 200) throw Exception('The enclave proxy refused the request (${r.statusCode})');
    final j = jsonDecode(r.body) as Map<String, dynamic>; final ct = base64.decode(j['ct'] as String);
    final clear = await aes.decrypt(SecretBox(ct.sublist(0, ct.length - 16), nonce: base64.decode(j['nonce'] as String), mac: Mac(ct.sublist(ct.length - 16))),
        secretKey: await key('amer-enclave-v1 response'));
    return (jsonDecode(utf8.decode(clear)) as Map)['answer'] as String;
  }
}
