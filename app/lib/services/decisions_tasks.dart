import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:matrix/matrix.dart';
import 'api_service.dart';
import 'later.dart';

/// Decisions and tasks (docs/DECISIONS.md). Texts travel only as encrypted room events; the server ledger keeps
/// metadata and the text's hash, and checks the quorum from each person's own confirmation.
const kDecisionProposal = 'com.amerteams.decision.proposal', kDecisionConfirm = 'com.amerteams.decision.confirm', kTask = 'com.amerteams.task';

String textHash(String t) => sha256.convert(utf8.encode(t)).toString();

/// Decision language in English and Arabic ("we agreed", "decided", "go with", "تم الاتفاق", "قررنا").
final _decisionRx = RegExp(r"\b(we agreed|agreed to|we('ve| have)? decided|decision:|let'?s go with|we('ll| will) go with|go with)\b|تم الاتفاق|اتفقنا|قررنا|تقرر", caseSensitive: false);
bool looksLikeDecision(String t) => _decisionRx.hasMatch(t);

String newId(String prefix) => '$prefix${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';

Future<void> proposeDecision(Room room, {required String text, required String owner, String? due, String? sourceEvent, String? decisionId, int version = 1, int? supersedes}) =>
    room.sendEvent({'decision_id': decisionId ?? newId('dec'), 'version': version, 'text': text, 'owner': owner, if (due != null) 'due': due,
        if (sourceEvent != null) 'source_event': sourceEvent, if (supersedes != null) 'supersedes': supersedes,
        'body': '🧭 Proposed decision: $text'}, type: kDecisionProposal);

/// Confirm a proposal: an encrypted confirmation in the chat (so everyone sees who confirmed) and the server
/// confirmation under my own sign-in (which is what the ledger counts). Returns the server's answer.
Future<Map<String, dynamic>> confirmDecision(Room room, ApiService api, Event p) async {
  final c = p.content;
  await room.sendEvent({'decision_id': c['decision_id'], 'version': c['version'], 'body': 'Confirmed the decision'}, type: kDecisionConfirm);
  final r = await api.confirmDecision({'room_id': room.id, 'decision_id': c['decision_id'], 'version': c['version'], 'event_id': p.eventId,
      'owner': c['owner'], 'due': c['due'], 'text_hash': textHash('${c['text']}'), 'supersedes': c['supersedes'], 'proposed_at': p.originServerTs.millisecondsSinceEpoch});
  // a decision with an owner and a due date becomes a task for its owner (created once, by the owner's app)
  if (r['status'] == 'confirmed' && r['already'] != true && c['owner'] == room.client.userID && c['due'] != null) {
    await saveTask(room, {'task_id': 'task-${c['decision_id']}-v${c['version']}', 'title': '${c['text']}', 'owner': c['owner'], 'due': c['due'],
        'status': 'open', 'source_event': p.eventId, 'decision_id': c['decision_id']});
  }
  return r;
}

// ---------- tasks: encrypted room events; the latest event for a task id wins ----------
Future<void> saveTask(Room room, Map<String, Object?> t) => room.sendEvent({...t,
  'body': '${t['status'] == 'done' ? '✅' : '📌'} Task: ${t['title']}${t['status'] != 'open' ? ' (${'${t['status']}'.replaceAll('_', ' ')})' : ''}'}, type: kTask);

class Task {
  Task(this.e);
  final Event e;
  Map<String, Object?> get c => e.content;
  String get id => '${c['task_id']}'; String get title => '${c['title']}'; String get owner => '${c['owner'] ?? ''}';
  String get status => '${c['status'] ?? 'open'}'; String? get reason => c['reason'] as String?;
  DateTime? get due => DateTime.tryParse('${c['due'] ?? ''}');
  bool get overdue => due != null && status != 'done' && DateTime.now().isAfter(due!.add(const Duration(days: 1)));
  Room get room => e.room;
  Map<String, Object?> copyWith(Map<String, Object?> x) => {for (final k in ['task_id', 'title', 'owner', 'due', 'status', 'reason', 'source_event', 'decision_id']) if (c[k] != null) k: c[k], ...x};
}

/// Latest state of each task among [events] (newest first, as timelines give them).
List<Task> tasksIn(Iterable<Event> events) {
  final seen = <String>{}, out = <Task>[];
  for (final e in events.where((e) => e.type == kTask)) { if (seen.add('${e.content['task_id']}')) out.add(Task(e)); }
  return out;
}

/// My tasks across chats (recent history of each), overdue first, then by due date.
Future<List<Task>> myTasks(Client c) async {
  final out = <Task>[];
  for (final r in c.rooms.where((r) => r.membership == Membership.join)) {
    try {
      final tl = await r.getTimeline(limit: 200);
      out.addAll(tasksIn(tl.events).where((t) => t.owner == c.userID));
      tl.cancelSubscriptions();
    } catch (_) {}
  }
  out.sort((a, b) => a.overdue != b.overdue ? (a.overdue ? -1 : 1) : (a.due ?? DateTime(9999)).compareTo(b.due ?? DateTime(9999)));
  for (final t in out.where((t) => t.status != 'done' && t.due != null)) { remindTask(t); }
  return out;
}

/// Reminders 24 h and 1 h before the due date (due dates are days: due at 17:00 local).
final _reminded = <String>{};
void remindTask(Task t) {
  final at = DateTime(t.due!.year, t.due!.month, t.due!.day, 17);
  for (final before in const [Duration(hours: 24), Duration(hours: 1)]) {
    final when = at.subtract(before), key = '${t.id}|${before.inHours}';
    if (when.isAfter(DateTime.now()) && _reminded.add(key)) {
      Reminders.instance.add(t.room.id, t.e.eventId, 'Task due ${before.inHours == 24 ? 'tomorrow' : 'in an hour'}: ${t.title}', when, key: key);
    }
  }
}
