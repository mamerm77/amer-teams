import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'dart:typed_data';
import 'package:path_provider/path_provider.dart';
import 'package:pqcrypto/pqcrypto.dart';

/// Post-quantum hybrid call keys (protocol amer-pq-hybrid-v1). Mirrors tools/pq_hybrid.py.
///
/// Media key K = HKDF(salt=callId, ikm=K_c || K_pq, info="amer-call-key-v1|index").
/// K_c travels inside Megolm (classical); K_pq is wrapped per device with ML-KEM-768 (FIPS 203).
/// Both layers must be broken to recover K.
class PqHybrid {
  static const alg = 'amer-pq-hybrid-v1';
  static final _kem = PqcKem.kyber768;

  // ---------------- primitives ----------------
  static Uint8List hkdf(List<int> salt, List<int> ikm, List<int> info, int length) {
    final prk = hmacSha256(Uint8List.fromList(salt), Uint8List.fromList(ikm));
    final out = BytesBuilder(); var t = Uint8List(0); var i = 1;
    while (out.length < length) {
      t = hmacSha256(prk, Uint8List.fromList([...t, ...info, i])); out.add(t); i++;
    }
    return Uint8List.fromList(out.toBytes().sublist(0, length));
  }

  static Uint8List random(int n) { final r = Random.secure(); return Uint8List.fromList(List.generate(n, (_) => r.nextInt(256))); }
  static Uint8List _xor(List<int> a, List<int> b) => Uint8List.fromList(List.generate(a.length, (i) => a[i] ^ b[i]));
  static bool _eq(List<int> a, List<int> b) { if (a.length != b.length) return false; var d = 0; for (var i = 0; i < a.length; i++) { d |= a[i] ^ b[i]; } return d == 0; }
  static List<int> _info(String callId, int keyIndex, String userId, String deviceId) => utf8.encode('$callId|$keyIndex|$userId|$deviceId');

  /// (pk, sk). seed = d||z (64 bytes) only for test vectors.
  static (Uint8List, Uint8List) keygen([Uint8List? seed]) => _kem.generateKeyPair(seed);

  static Map<String, Uint8List> wrap(Uint8List pk, Uint8List kPq, String callId, int keyIndex, String userId, String deviceId, [Uint8List? m]) {
    final (ct, ss) = _kem.encapsulate(pk, m);
    final okm = hkdf(utf8.encode('amer-pq-wrap'), ss, _info(callId, keyIndex, userId, deviceId), 64);
    final w = _xor(kPq, okm.sublist(0, 32));
    final t = hmacSha256(okm.sublist(32), Uint8List.fromList([...ct, ...w]));
    return {'ct': ct, 'w': w, 't': t};
  }

  static Uint8List unwrap(Uint8List sk, Map<String, Uint8List> wr, String callId, int keyIndex, String userId, String deviceId) {
    final ss = _kem.decapsulate(sk, wr['ct']!);
    final okm = hkdf(utf8.encode('amer-pq-wrap'), ss, _info(callId, keyIndex, userId, deviceId), 64);
    final t = hmacSha256(okm.sublist(32), Uint8List.fromList([...wr['ct']!, ...wr['w']!]));
    if (!_eq(t, wr['t']!)) throw StateError('Post-quantum key failed authentication (wrong device or tampered)');
    return _xor(wr['w']!, okm.sublist(0, 32));
  }

  static Uint8List callKey(Uint8List kC, Uint8List kPq, String callId, int keyIndex) =>
      hkdf(utf8.encode(callId), [...kC, ...kPq], utf8.encode('amer-call-key-v1|$keyIndex'), 32);

  // ---------------- event helpers (base64 on the wire) ----------------
  /// devices: (userId, deviceId, pk). Returns (event content, K).
  static (Map<String, dynamic>, Uint8List) newKeyEvent(String callId, int keyIndex, List<(String, String, Uint8List)> devices) {
    final kC = random(32), kPq = random(32);
    final wraps = <String, dynamic>{
      for (final (u, d, pk) in devices)
        '$u|$d': wrap(pk, kPq, callId, keyIndex, u, d).map((k, v) => MapEntry(k, base64.encode(v))),
    };
    return ({'call_id': callId, 'key_index': keyIndex, 'alg': alg, 'kc': base64.encode(kC), 'wraps': wraps}, callKey(kC, kPq, callId, keyIndex));
  }

  static Uint8List openKeyEvent(Map<String, dynamic> ev, String userId, String deviceId, Uint8List sk) {
    if (ev['alg'] != alg) throw StateError('Call key is not post-quantum protected');
    final w = (ev['wraps'] as Map)['$userId|$deviceId'];
    if (w == null) throw StateError('No post-quantum key for this device yet');
    final wr = {for (final k in ['ct', 'w', 't']) k: base64.decode(w[k] as String)};
    final kPq = unwrap(sk, wr, ev['call_id'] as String, (ev['key_index'] as num).toInt(), userId, deviceId);
    return callKey(base64.decode(ev['kc'] as String), kPq, ev['call_id'] as String, (ev['key_index'] as num).toInt());
  }
}

/// This device's ML-KEM-768 key pair, created once and kept in the app's private storage.
class PqDeviceKey {
  PqDeviceKey._(this.pk, this.sk);
  final Uint8List pk, sk;
  static PqDeviceKey? _cached;

  static Future<PqDeviceKey> load() async {
    if (_cached != null) return _cached!;
    final f = File('${(await getApplicationSupportDirectory()).path}/pq_device_key.json');
    if (await f.exists()) {
      final j = jsonDecode(await f.readAsString());
      return _cached = PqDeviceKey._(base64.decode(j['pk']), base64.decode(j['sk']));
    }
    final (pk, sk) = PqHybrid.keygen();
    await f.writeAsString(jsonEncode({'alg': 'ML-KEM-768', 'pk': base64.encode(pk), 'sk': base64.encode(sk)}), flush: true);
    return _cached = PqDeviceKey._(pk, sk);
  }
}
