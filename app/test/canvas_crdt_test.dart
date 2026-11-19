import 'dart:convert';
import 'dart:math';
import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/canvas_crdt.dart';

/// Same cases as tests/canvas_crdt_ref.py. Ops go through JSON, as they do in encrypted room events.
Map<String, Object?> wire(Map<String, Object?> op) => Map<String, Object?>.from(jsonDecode(jsonEncode(op)) as Map);

void main() {
  test('two offline edits to the same paragraph converge and both are kept', () {
    final a = CrdtDoc('A'), b = CrdtDoc('B');
    b.apply(wire(a.insertText('p', 0, 'The ring is ready')));
    final oa = a.insertText('p', 4, 'Dubai '), ob = b.insertText('p', 17, ' for traffic');
    a.apply(wire(ob)); b.apply(wire(oa));
    expect(a.text('p'), 'The Dubai ring is ready for traffic');
    expect(b.text('p'), a.text('p'));
  });
  test('concurrent inserts at the same place: same order everywhere', () {
    final a = CrdtDoc('A'), b = CrdtDoc('B');
    final oa = a.insertText('p', 0, 'X'), ob = b.insertText('p', 0, 'Y');
    a.apply(wire(ob)); b.apply(wire(oa));
    expect(a.text('p'), b.text('p')); expect(a.text('p').split('').toSet(), {'X', 'Y'});
  });
  test('delete against insert inside the deleted span', () {
    final a = CrdtDoc('A'), b = CrdtDoc('B'); b.apply(wire(a.insertText('p', 0, 'hello world')));
    final da = a.delete('p', 5, 6), ib = b.insertText('p', 8, '!!');
    a.apply(wire(ib)); b.apply(wire(da));
    expect(a.text('p'), 'hello!!'); expect(b.text('p'), 'hello!!');
  });
  test('out-of-order delivery is buffered', () {
    final a = CrdtDoc('A'), b = CrdtDoc('B');
    final o1 = a.insertText('p', 0, 'ab'), o2 = a.insertText('p', 2, 'cd'), o3 = a.delete('p', 1, 2);
    for (final o in [o3, o2, o1]) { b.apply(wire(o)); }
    expect(b.text('p'), 'ad'); expect(a.text('p'), 'ad'); expect(b.pending, isEmpty);
  });
  test('registers: last writer wins everywhere', () {
    final a = CrdtDoc('A'), b = CrdtDoc('B');
    final sa = a.set('b1', 'checked', true), sb = b.set('b1', 'checked', false);
    a.apply(wire(sb)); b.apply(wire(sa));
    expect(a.get('b1', 'checked'), b.get('b1', 'checked'));
  });
  test('editText produces the minimal ops', () {
    final a = CrdtDoc('A'); a.insertText('p', 0, 'abcdef');
    a.editText('p', 'abcdef', 'abXYef');
    expect(a.text('p'), 'abXYef');
  });
  test('snapshot round trip and replay is harmless', () {
    final a = CrdtDoc('A'); final ops = [a.insertText('p', 0, 'abc'), a.insertText('p', 3, 'def'), a.delete('p', 1, 1)];
    final b = CrdtDoc.fromSnapshot('B', jsonDecode(jsonEncode(a.snapshot())) as Map);
    for (final o in ops) { b.apply(wire(o)); }
    expect(b.text('p'), 'acdef');
    b.apply(wire(b.insertText('p', 5, '!'))); expect(b.text('p'), 'acdef!');
  });
  test('random convergence: 300 trials, any order, duplicates', () {
    for (var seed = 0; seed < 300; seed++) {
      final rnd = Random(seed); final docs = [for (var i = 0; i < 3; i++) CrdtDoc('d$i')]; final log = <(String, Map<String, Object?>)>[];
      for (var n = 0; n < 50; n++) {
        final d = docs[rnd.nextInt(3)], l = rnd.nextBool() ? 'b1:text' : 'b2:text', len = d.visible(l).length, r = rnd.nextDouble();
        final op = (r < .6 || len == 0) ? d.insertText(l, rnd.nextInt(len + 1), ['a', 'bc', 'xyz', 'Q'][rnd.nextInt(4)])
            : r < .85 ? (() { final i = rnd.nextInt(len); return d.delete(l, i, 1 + rnd.nextInt(min(3, len - i))); })()
            : d.set('b1', 'checked', rnd.nextBool());
        log.add((d.site, wire(op)));
      }
      for (final x in docs) {
        final order = [...log, ...log]..shuffle(rnd);
        for (final (s, o) in order) { if (s != x.site) x.apply(wire(o)); }
      }
      for (final x in docs.skip(1)) {
        expect(x.text('b1:text'), docs[0].text('b1:text'), reason: 'seed $seed');
        expect(x.text('b2:text'), docs[0].text('b2:text'), reason: 'seed $seed');
        expect(x.get('b1', 'checked'), docs[0].get('b1', 'checked'), reason: 'seed $seed');
        expect(x.pending, isEmpty);
      }
    }
  });
}
