import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:cryptography/cryptography.dart';

/// Wraps the call key to a browser guest's one-time X25519 public key (docs/GUESTS.md).
/// key = HKDF-SHA256(X25519(eph, guest), salt = epk || guest_pk, info = "amer-guest-v1"); AES-256-GCM over the key string.
class GuestKeys {
  static Future<Map<String, Object>> wrap(String sharedKey, String guestPkB64, int idx, String to) async {
    final gpk = base64.decode(guestPkB64);
    if (gpk.length != 32) throw ArgumentError('bad guest key');
    final x = X25519(); final eph = await x.newKeyPair();
    final epk = Uint8List.fromList((await eph.extractPublicKey()).bytes);
    final shared = await x.sharedSecretKey(keyPair: eph, remotePublicKey: SimplePublicKey(gpk, type: KeyPairType.x25519));
    final k = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, nonce: [...epk, ...gpk], info: utf8.encode('amer-guest-v1'));
    final nonce = List<int>.generate(12, (_) => Random.secure().nextInt(256));
    final box = await AesGcm.with256bits().encrypt(utf8.encode(sharedKey), secretKey: k, nonce: nonce);
    return {'t': 'gk', 'to': to, 'idx': idx, 'epk': base64.encode(epk), 'nonce': base64.encode(nonce), 'ct': base64.encode([...box.cipherText, ...box.mac.bytes])};
  }
}
