// Must reproduce tests/pq_hybrid_test.py vectors byte for byte (independent ML-KEM implementations).
import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart' as c;
import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/pq_service.dart';

void main() {
  final vectors = jsonDecode(File('test/pq_vectors.json').readAsStringSync()) as List;
  for (final v in vectors) {
    test('vector ${v['call_id']}: ML-KEM-768 + hybrid key match the Python reference', () {
      final (pk, sk) = PqHybrid.keygen(base64.decode(v['seed']));
      expect(c.sha256.convert(pk).toString(), v['pk_sha256'], reason: 'public key');
      expect(c.sha256.convert(sk).toString(), v['sk_sha256'], reason: 'secret key');
      final w = PqHybrid.wrap(pk, base64.decode(v['kpq']), v['call_id'], v['key_index'], v['user'], v['device'], base64.decode(v['m']));
      expect(c.sha256.convert(w['ct']!).toString(), v['ct_sha256'], reason: 'ciphertext');
      expect(base64.encode(w['w']!), v['w'], reason: 'wrapped key');
      expect(base64.encode(w['t']!), v['t'], reason: 'tag');
      final kPq = PqHybrid.unwrap(sk, w, v['call_id'], v['key_index'], v['user'], v['device']);
      expect(base64.encode(kPq), v['kpq']);
      final k = PqHybrid.callKey(base64.decode(v['kc']), kPq, v['call_id'], v['key_index']);
      expect(base64.encode(k), v['K'], reason: 'final call key');
    });
  }
  test('round trip through key events, wrong device rejected', () {
    final (pa, sa) = PqHybrid.keygen(); final (pb, sb) = PqHybrid.keygen();
    final (ev, k) = PqHybrid.newKeyEvent('call', 0, [('@a:x', 'A', pa), ('@b:x', 'B', pb)]);
    final wire = jsonDecode(jsonEncode(ev)) as Map<String, dynamic>;
    expect(PqHybrid.openKeyEvent(wire, '@a:x', 'A', sa), k);
    expect(PqHybrid.openKeyEvent(wire, '@b:x', 'B', sb), k);
    expect(() => PqHybrid.openKeyEvent(wire, '@a:x', 'A', sb), throwsStateError);
  });
}
