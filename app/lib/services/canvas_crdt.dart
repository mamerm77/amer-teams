/// Canvas CRDT (docs/CANVAS.md). A line-for-line port of tests/canvas_crdt_ref.py, which proves convergence
/// (500 random trials, any delivery order, duplicates). Keep the two identical.
///
/// Lists (RGA): blocks, each text block's characters, table rows and columns. Element id = [lamport, site].
/// Concurrent inserts at the same place are ordered by id, larger first; deletes leave tombstones.
/// Registers (LWW): block type, checked, table cells, title; the larger id wins.
/// Ops whose reference has not arrived yet wait in `pending`.
library;

int cmpId(List a, List b) {
  final c = (a[0] as int).compareTo(b[0] as int);
  return c != 0 ? c : '${a[1]}'.compareTo('${b[1]}');
}
bool sameId(List? a, List? b) => a == null || b == null ? a == b : a[0] == b[0] && '${a[1]}' == '${b[1]}';

class CrdtDoc {
  CrdtDoc(this.site);
  final String site;
  int clock = 0;
  final lists = <String, List<Map<String, Object?>>>{};
  final regs = <String, (List, Object?)>{};              // "obj\u0000key" -> (id, value)
  final pending = <Map<String, Object?>>[];
  final _seen = <String>{};

  bool _has(String lst, List? i) => i == null || (lists[lst] ?? const []).any((e) => sameId(e['id'] as List, i));
  bool _ready(Map<String, Object?> op) => switch (op['op']) {
    'ins' => _has(op['list'] as String, op['after'] as List?),
    'del' => (op['ids'] as List).every((i) => _has(op['list'] as String, i as List)),
    _ => true };

  void apply(Map<String, Object?> op) {
    pending.add(op);
    var progress = true;
    while (progress) {
      progress = false;
      for (final o in List.of(pending)) {
        if (_ready(o)) { pending.remove(o); _apply(o); progress = true; }
      }
    }
  }

  void _apply(Map<String, Object?> op) {
    final oid = op['id'] as List?;
    final tag = '${op['op']}|${op['list'] ?? op['obj']}|${oid ?? ''}|${op['ids'] ?? ''}';
    if (!_seen.add(tag)) return;                                // duplicate delivery is harmless
    if (oid != null) {
      final n = ((op['vals'] as List?) ?? const ['']).length;
      final top = (oid[0] as int) + n - 1;
      if (top > clock) clock = top;
    }
    switch (op['op']) {
      case 'ins':
        final lst = lists.putIfAbsent(op['list'] as String, () => []);
        final vals = op['vals'] as List;
        for (var k = 0; k < vals.length; k++) {
          final nid = [(oid![0] as int) + k, oid[1]];
          if (lst.any((e) => sameId(e['id'] as List, nid))) continue;   // already have it (e.g. from a snapshot)
          final after = k == 0 ? op['after'] as List? : [(oid[0] as int) + k - 1, oid[1]];
          var pos = after == null ? 0 : lst.indexWhere((e) => sameId(e['id'] as List, after)) + 1;
          while (pos < lst.length && cmpId(lst[pos]['id'] as List, nid) > 0) { pos++; }
          lst.insert(pos, {'id': nid, 'val': vals[k], 'del': false});
        }
      case 'del':
        final ids = (op['ids'] as List).cast<List>();
        for (final e in lists[op['list']] ?? const <Map<String, Object?>>[]) {
          if (ids.any((i) => sameId(e['id'] as List, i))) e['del'] = true;
        }
      case 'set':
        final k = '${op['obj']}\u0000${op['key']}', cur = regs[k];
        if (cur == null || cmpId(oid!, cur.$1) > 0) regs[k] = (oid!, op['val']);
    }
  }

  List _newId([int n = 1]) { final i = [clock + 1, site]; clock += n; return i; }
  List<Map<String, Object?>> visible(String lst) => (lists[lst] ?? const []).where((e) => e['del'] != true).toList();
  String text(String lst) => visible(lst).map((e) => e['val']).join();
  Object? get(String obj, String key) => regs['$obj\u0000$key']?.$2;

  Map<String, Object?> insert(String lst, int index, List<Object?> vals) {
    final vis = visible(lst);
    final op = <String, Object?>{'op': 'ins', 'list': lst, 'after': index > 0 ? vis[index - 1]['id'] : null, 'id': _newId(vals.length), 'vals': vals};
    _apply(op); return op;
  }
  Map<String, Object?> insertText(String lst, int index, String s) => insert(lst, index, s.split(''));
  Map<String, Object?> delete(String lst, int index, int n) {
    final op = <String, Object?>{'op': 'del', 'list': lst, 'ids': [for (final e in visible(lst).skip(index).take(n)) e['id']]};
    _apply(op); return op;
  }
  Map<String, Object?> set(String obj, String key, Object? val) {
    final op = <String, Object?>{'op': 'set', 'obj': obj, 'key': key, 'val': val, 'id': _newId()};
    _apply(op); return op;
  }

  /// Ops that turn [oldText] into [newText] (one edited span: what a text field produces per keystroke or paste).
  List<Map<String, Object?>> editText(String lst, String oldText, String newText) {
    var p = 0;
    while (p < oldText.length && p < newText.length && oldText[p] == newText[p]) { p++; }
    var s = 0;
    while (s < oldText.length - p && s < newText.length - p && oldText[oldText.length - 1 - s] == newText[newText.length - 1 - s]) { s++; }
    final ops = <Map<String, Object?>>[];
    final removed = oldText.length - p - s, added = newText.substring(p, newText.length - s);
    if (removed > 0) ops.add(delete(lst, p, removed));
    if (added.isNotEmpty) ops.add(insertText(lst, p, added));
    return ops;
  }

  /// Full state for a snapshot event (new joiners load this instead of replaying every update).
  Map<String, Object?> snapshot() => {'clock': clock, 'lists': lists,
    'regs': {for (final e in regs.entries) e.key: [e.value.$1, e.value.$2]}};
  static CrdtDoc fromSnapshot(String site, Map snap) {
    final d = CrdtDoc(site)..clock = snap['clock'] as int;
    (snap['lists'] as Map).forEach((k, v) => d.lists['$k'] = [for (final e in v as List) Map<String, Object?>.from(e as Map)]);
    (snap['regs'] as Map).forEach((k, v) => d.regs['$k'] = ((v as List)[0] as List, v[1]));
    return d;
  }
}
