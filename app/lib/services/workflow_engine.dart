/// Pure workflow logic, shared by the runner and the editor (docs/WORKFLOWS.md). It mirrors
/// services/orchestrator/app/workflows.py: the server validates and dry-runs; this side runs on the owner's device.
library;

const kWfContent = 'com.amerteams.workflow';            // marks messages a workflow sent (forms, approvals, posts)
const kWfResponse = 'com.amerteams.workflow.response';  // encrypted room event: a form answer or an approval decision

Object? wfRef(String path, Map<String, Object?> ctx) {
  Object? cur = ctx;
  for (final p in path.replaceFirst(r'$', '').split('.')) { cur = cur is Map ? cur[p] : null; }
  return cur;
}

String wfRender(String text, Map<String, Object?> ctx) =>
    text.replaceAllMapped(RegExp(r'\{\{\s*([\w.]+)\s*\}\}'), (m) => '${wfRef(m.group(1)!, ctx) ?? ''}');

Object? _lit(String v) {
  v = v.trim();
  if (v.length >= 2 && (v[0] == "'" || v[0] == '"') && v.endsWith(v[0])) return v.substring(1, v.length - 1);
  return double.tryParse(v) ?? v;
}

/// "$s1.amount > 500000", "$s3.decision == 'approved'", "$trigger.body contains quote".
bool wfEvaluate(String cond, Map<String, Object?> ctx) {
  for (final op in const ['>=', '<=', '!=', '==', '>', '<', ' contains ']) {
    final i = cond.indexOf(op);
    if (i < 0) continue;
    final l = cond.substring(0, i).trim(), r = cond.substring(i + op.length).trim();
    if (!l.startsWith(r'$') || r.isEmpty) return false;
    final a = wfRef(l, ctx), b = r.startsWith(r'$') ? wfRef(r, ctx) : _lit(r);
    switch (op.trim()) {
      case 'contains': return '$a'.toLowerCase().contains('$b'.toLowerCase());
      case '==': return b is double ? double.tryParse('$a') == b : '$a' == '$b';
      case '!=': return b is double ? double.tryParse('$a') != b : '$a' != '$b';
    }
    final x = double.tryParse('$a'), y = b is double ? b : double.tryParse('$b');
    if (x == null || y == null) return false;
    return switch (op) { '>' => x > y, '<' => x < y, '>=' => x >= y, _ => x <= y };
  }
  return false;
}

/// The step after [id], following condition branches and "next".
String? wfNext(List<Map<String, Object?>> steps, String id, Map<String, Object?> ctx) {
  final i = steps.indexWhere((s) => s['id'] == id);
  if (i < 0) return null;
  final s = steps[i];
  if (s['type'] == 'condition') { final n = (wfEvaluate('${s['if']}', ctx) ? s['then'] : s['else']) as String?; return n == 'end' ? null : n; }
  final n = s['next'] as String?;
  if (n == 'end') return null;
  if (n != null) return n;
  return i + 1 < steps.length ? steps[i + 1]['id'] as String : null;
}

/// Does a message match a message trigger's rules?
bool wfMatches(Map<String, Object?> trigger, {required String roomId, required String body, required bool hasFile, required String sender}) {
  if (trigger['type'] != 'message' || trigger['room'] != roomId) return false;
  final m = (trigger['match'] as Map?) ?? const {};
  if (m['has_file'] == true && !hasFile) return false;
  final kw = ((m['keywords'] as List?) ?? const []).map((e) => '$e'.toLowerCase());
  if (kw.isNotEmpty && !kw.any((k) => body.toLowerCase().contains(k))) return false;
  final from = m['from'];
  if (from is String && from.isNotEmpty && from != sender) return false;
  return true;
}

bool _cronField(String f, int v, int lo, int hi) {
  for (final part in f.split(',')) {
    var step = 1, range = part;
    if (part.contains('/')) { step = int.tryParse(part.split('/')[1]) ?? 1; range = part.split('/')[0]; }
    int a, b;
    if (range == '*') { a = lo; b = hi; }
    else if (range.contains('-')) { a = int.parse(range.split('-')[0]); b = int.parse(range.split('-')[1]); }
    else { a = int.parse(range); b = part.contains('/') ? hi : a; }
    if (v >= a && v <= b && (v - a) % step == 0) return true;
  }
  return false;
}

/// Standard 5-field cron (minute hour day month weekday; Sunday = 0 or 7), in the device's local time.
bool wfCronDue(String cron, DateTime t) {
  final f = cron.trim().split(RegExp(r'\s+'));
  if (f.length != 5) return false;
  try {
    final dow = t.weekday % 7;
    return _cronField(f[0], t.minute, 0, 59) && _cronField(f[1], t.hour, 0, 23) && _cronField(f[2], t.day, 1, 31) &&
        _cronField(f[3], t.month, 1, 12) && (_cronField(f[4], dow, 0, 7) || (dow == 0 && _cronField(f[4], 7, 0, 7)));
  } catch (_) { return false; }
}

/// Who a form or approval goes to: user IDs, or references like "$trigger.sender".
List<String> wfPeople(Object? v, Map<String, Object?> ctx) => [
  for (final x in (v is List ? v : [v]))
    if (x is String) ('${x.startsWith(r'$') ? wfRef(x, ctx) ?? '' : x}')
].where((s) => s.startsWith('@')).toList();
