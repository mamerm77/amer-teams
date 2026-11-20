import 'package:matrix/matrix.dart';
import 'decisions_tasks.dart';
import 'labels.dart';
import 'matrix_service.dart';

/// The agent office works on real data and acts for real (docs/VIRTUAL_OFFICE.md, "Teams agents"):
/// - the app sends a chat's recent messages as context (decrypted here, on your device; Guardian checks it on the
///   server and blocks Confidential/Restricted chats);
/// - agents propose actions on that chat (post a message, create a task, schedule a meeting);
/// - nothing runs until you approve; then this device runs them with your own keys, so the server never sees or
///   sends the content in clear.
class OfficeContext {
  OfficeContext(this.room, this.text, this.label);
  final Room room; final String text; final String? label;

  static Future<OfficeContext> of(Room room, {int messages = 80}) async {
    final tl = await room.getTimeline(limit: 300);
    final evs = tl.events.where((e) => e.type == EventTypes.Message && !e.redacted).take(messages).toList().reversed;
    final taskList = tasksIn(tl.events);
    tl.cancelSubscriptions();
    final lines = [for (final e in evs) '${e.originServerTs.toIso8601String().substring(0, 16)} ${e.senderFromMemoryOrFallback.calcDisplayname()} (${e.senderId}): ${e.body}'];
    final head = "Chat '${room.getLocalizedDisplayname()}' room_id: ${room.id}\nMembers: ${room.getParticipants().map((u) => '${u.calcDisplayname()} (${u.id})').join(', ')}";
    final open = taskList.where((t) => t.status != 'done').map((t) => '- ${t.title}${t.due != null ? ' (due ${t.due!.toIso8601String().substring(0, 10)})' : ''}').join('\n');
    return OfficeContext(room, '$head\nOpen tasks:\n${open.isEmpty ? '(none)' : open}\n\nRecent messages:\n${lines.join('\n')}', labelOf(room));
  }
}

/// Runs approved actions; returns a one-line summary of what was done.
Future<String> runOfficeActions(MatrixService m, List actions) async {
  final c = m.client; var posts = 0, tasks = 0, meetings = 0; final skipped = <String>[];
  for (final a in actions.whereType<Map>()) {
    final room = c.getRoomById('${a['room']}');
    if (room == null || room.membership != Membership.join) { skipped.add('${a['type']}'); continue; }
    try {
      switch (a['type']) {
        case 'post':
          await room.sendTextEvent('${a['text']}'); posts++;
        case 'task':
          await saveTask(room, {'task_id': 'agent-${DateTime.now().microsecondsSinceEpoch}-$tasks', 'title': '${a['title']}',
            'owner': (a['assignee'] is String && '${a['assignee']}'.startsWith('@')) ? a['assignee'] : c.userID, 'due': a['due'], 'status': 'open'});
          tasks++;
        case 'meeting':
          final start = DateTime.tryParse('${a['start']}');
          if (start == null) { skipped.add('meeting'); continue; }
          await m.sendMeeting(room, title: '${a['title']}', start: start.toLocal(), minutes: (a['minutes'] is num) ? (a['minutes'] as num).toInt() : 30);
          meetings++;
      }
    } catch (_) { skipped.add('${a['type']}'); }
  }
  final done = [if (posts > 0) '$posts message${posts == 1 ? '' : 's'} posted', if (tasks > 0) '$tasks task${tasks == 1 ? '' : 's'} created', if (meetings > 0) '$meetings meeting${meetings == 1 ? '' : 's'} scheduled'];
  return '${done.isEmpty ? 'Nothing to do' : done.join(', ')}${skipped.isEmpty ? '' : ' · ${skipped.length} skipped'}';
}

String describeAction(Map a, Client c) {
  final room = c.getRoomById('${a['room']}')?.getLocalizedDisplayname() ?? 'a chat';
  return switch (a['type']) {
    'post' => 'Post in $room: “${a['text']}”',
    'task' => 'Create task in $room: ${a['title']}${a['due'] != null ? ' (due ${a['due']})' : ''}',
    'meeting' => 'Schedule in $room: ${a['title']} at ${a['start']} (${a['minutes'] ?? 30} min)',
    _ => '${a['type']}',
  };
}
