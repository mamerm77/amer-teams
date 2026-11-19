import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/decisions_tasks.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

/// Task board for one chat, or my tasks across chats (room == null). Overdue first.
class TasksScreen extends StatefulWidget {
  const TasksScreen({super.key, this.room});
  final Room? room;
  @override State<TasksScreen> createState() => _S();
}

class _S extends State<TasksScreen> {
  Future<List<Task>>? f;
  @override void initState() { super.initState(); _load(); }
  void _load() => setState(() => f = widget.room == null ? myTasks(context.read<MatrixService>().client) : () async {
    final tl = await widget.room!.getTimeline(limit: 300); final t = tasksIn(tl.events); tl.cancelSubscriptions();
    for (final x in t.where((x) => x.owner == widget.room!.client.userID && x.status != 'done' && x.due != null)) { remindTask(x); }
    return t;
  }());

  static const cols = [('open', 'Open'), ('in_progress', 'In progress'), ('blocked', 'Blocked'), ('done', 'Done')];

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(widget.room == null ? 'My tasks' : 'Tasks · ${widget.room!.getLocalizedDisplayname()}'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
    floatingActionButton: widget.room == null ? null : FloatingActionButton.extended(icon: const Icon(Icons.add_task), label: Text(L.t(context, 'New task')),
      onPressed: () async { await editTask(c, widget.room!); _load(); }),
    body: FutureBuilder<List<Task>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final all = s.data!;
      if (all.isEmpty) return Center(child: Text(widget.room == null ? 'No tasks assigned to you' : 'No tasks in this chat yet'));
      return ListView(padding: const EdgeInsets.only(bottom: 96), children: [
        for (final (k, label) in cols) if (all.any((t) => t.status == k)) ...[
          Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 4), child: Text('$label (${all.where((t) => t.status == k).length})', style: Theme.of(c).textTheme.titleSmall)),
          for (final t in all.where((t) => t.status == k)) TaskTile(t: t, showRoom: widget.room == null, onChanged: _load),
        ],
      ]);
    }),
  );
}

class TaskTile extends StatelessWidget {
  const TaskTile({super.key, required this.t, this.showRoom = false, this.onChanged});
  final Task t; final bool showRoom; final VoidCallback? onChanged;
  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme, mine = t.owner == t.room.client.userID;
    final owner = t.room.unsafeGetUserFromMemoryOrFallback(t.owner).calcDisplayname();
    return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), child: ListTile(
      leading: Icon(t.status == 'done' ? Icons.check_circle : t.status == 'blocked' ? Icons.block : t.overdue ? Icons.warning_amber : Icons.radio_button_unchecked,
          color: t.status == 'done' ? Colors.green : t.overdue || t.status == 'blocked' ? cs.error : cs.primary),
      title: Text(t.title, style: t.status == 'done' ? TextStyle(decoration: TextDecoration.lineThrough, color: cs.outline) : null),
      subtitle: Text([owner, if (t.due != null) '${t.overdue ? 'overdue · ' : ''}due ${DateFormat('d MMM').format(t.due!)}', if (t.reason != null && t.status == 'blocked') 'blocked: ${t.reason}',
          if (showRoom) t.room.getLocalizedDisplayname(), if (t.c['decision_id'] != null) 'from a decision'].join(' · ')),
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: t.room.id))),
      trailing: PopupMenuButton<String>(tooltip: 'Task options', onSelected: (v) async {
        if (v == 'edit') { await editTask(c, t.room, task: t); }
        else if (v == 'blocked') {
          final r = TextEditingController();
          final why = await showDialog<String>(context: c, builder: (d) => AlertDialog(title: const Text('Blocked by'), content: TextField(controller: r, autofocus: true),
            actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, r.text), child: const Text('Save'))]));
          if (why != null) await saveTask(t.room, t.copyWith({'status': 'blocked', 'reason': why}));
        } else { await saveTask(t.room, t.copyWith({'status': v, 'reason': null})); }
        onChanged?.call();
      }, itemBuilder: (_) => [
        if (t.status != 'in_progress' && t.status != 'done') const PopupMenuItem(value: 'in_progress', child: Text('Start')),
        if (t.status != 'done') const PopupMenuItem(value: 'done', child: Text('Mark done')),
        if (t.status != 'blocked' && t.status != 'done') const PopupMenuItem(value: 'blocked', child: Text('Blocked…')),
        if (t.status == 'done' || t.status == 'blocked') const PopupMenuItem(value: 'open', child: Text('Reopen')),
        if (mine || t.room.getPowerLevelByUserId(t.room.client.userID!).level >= 50) const PopupMenuItem(value: 'edit', child: Text('Edit')),
      ]),
    ));
  }
}

/// New or edited task: title, owner (a member of the chat), due date.
Future<void> editTask(BuildContext c, Room room, {Task? task, String? title, String? sourceEvent}) async {
  final t = TextEditingController(text: task?.title ?? title ?? '');
  final members = room.getParticipants().where((u) => u.membership == Membership.join && !u.id.startsWith('@amer')).toList();
  String owner = task?.owner ?? room.client.userID!; DateTime? due = task?.due;
  final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text(task == null ? 'New task' : 'Edit task'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: t, autofocus: true, decoration: const InputDecoration(labelText: 'Task')),
      DropdownButtonFormField<String>(value: members.any((u) => u.id == owner) ? owner : null, decoration: const InputDecoration(labelText: 'Owner'),
        items: [for (final u in members) DropdownMenuItem(value: u.id, child: Text(u.calcDisplayname()))], onChanged: (v) => set(() => owner = v ?? owner)),
      ListTile(contentPadding: EdgeInsets.zero, title: Text(due == null ? 'No due date' : 'Due ${DateFormat('EEE d MMM').format(due!)}'), trailing: const Icon(Icons.event),
        onTap: () async { final x = await showDatePicker(context: d, initialDate: due ?? DateTime.now().add(const Duration(days: 1)), firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
          if (x != null) set(() => due = x); }),
    ]),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))])));
  if (ok != true || t.text.trim().isEmpty) return;
  final dueS = due == null ? null : DateFormat('yyyy-MM-dd').format(due!);
  await saveTask(room, task != null ? task.copyWith({'title': t.text.trim(), 'owner': owner, 'due': dueS})
      : {'task_id': newId('task'), 'title': t.text.trim(), 'owner': owner, if (dueS != null) 'due': dueS, 'status': 'open', if (sourceEvent != null) 'source_event': sourceEvent});
}

/// Propose a decision from a message (or edit one into a new version): text, owner, due date.
Future<void> proposeDialog(BuildContext c, Room room, {String text = '', String? sourceEvent, Event? previous}) async {
  final t = TextEditingController(text: previous != null ? '${previous.content['text']}' : text);
  final members = room.getParticipants().where((u) => u.membership == Membership.join && !u.id.startsWith('@amer')).toList();
  String owner = previous?.content['owner'] as String? ?? room.client.userID!; DateTime? due = DateTime.tryParse('${previous?.content['due'] ?? ''}');
  final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text(previous == null ? 'Propose a decision' : 'New version of this decision'),
    content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: t, maxLines: 4, decoration: const InputDecoration(labelText: 'Decision')),
      DropdownButtonFormField<String>(value: members.any((u) => u.id == owner) ? owner : null, decoration: const InputDecoration(labelText: 'Owner'),
        items: [for (final u in members) DropdownMenuItem(value: u.id, child: Text(u.calcDisplayname()))], onChanged: (v) => set(() => owner = v ?? owner)),
      ListTile(contentPadding: EdgeInsets.zero, title: Text(due == null ? 'No due date' : 'Due ${DateFormat('EEE d MMM').format(due!)}'), trailing: const Icon(Icons.event),
        onTap: () async { final x = await showDatePicker(context: d, initialDate: due ?? DateTime.now().add(const Duration(days: 7)), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 730)));
          if (x != null) set(() => due = x); }),
      const Text('The owner and one other member confirm it; then it enters the ledger.', style: TextStyle(fontSize: 12)),
    ]),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Propose'))])));
  if (ok != true || t.text.trim().isEmpty) return;
  await proposeDecision(room, text: t.text.trim(), owner: owner, due: due == null ? null : DateFormat('yyyy-MM-dd').format(due!), sourceEvent: sourceEvent ?? previous?.content['source_event'] as String?,
      decisionId: previous?.content['decision_id'] as String?, version: previous == null ? 1 : ((previous.content['version'] as num).toInt() + 1),
      supersedes: previous == null ? null : (previous.content['version'] as num).toInt());
}

/// Decisions I own, from the ledger (metadata), with the text found on this device in the encrypted chat.
class MyDecisionsScreen extends StatelessWidget {
  const MyDecisionsScreen({super.key});
  /// The server keeps sha256("amer-room|<room id>"); this device knows its rooms, so it can match them.
  static String roomHash(String id) => textHash('amer-room|$id');
  Future<List<(Map, Room?, String?)>> _load(BuildContext c) async {
    final cl = c.read<MatrixService>().client; final api = c.read<ApiService>();
    final ds = await api.myDecisions(cl.userID!);
    final byHash = {for (final r in cl.rooms) roomHash(r.id): r};
    final out = <(Map, Room?, String?)>[];
    for (final d in ds.cast<Map>()) {
      final room = byHash[(d['room_hash'] ?? '') as String];
      String? text;
      if (room != null) { try { text = (await room.getEventById('${d['event_id']}'))?.content['text'] as String?; } catch (_) {} }
      out.add((d, room, text));
    }
    return out;
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('My decisions')), body: FutureBuilder<List<(Map, Room?, String?)>>(future: _load(c), builder: (_, s) {
    if (s.hasError) return Center(child: Text('${s.error}'));
    if (!s.hasData) return const Center(child: CircularProgressIndicator());
    if (s.data!.isEmpty) return const Center(child: Text('No confirmed decisions you own'));
    return ListView(children: [for (final (d, room, text) in s.data!) ListTile(leading: Icon(d['status'] == 'done' ? Icons.check_circle : Icons.gavel),
      title: Text(text ?? 'Decision ${d['decision_id']} (text in a chat not on this device)'),
      subtitle: Text('v${d['version']} · ${d['status']}${d['due'] != null ? ' · due ${d['due']}' : ''} · ${room?.getLocalizedDisplayname() ?? ''} · confirmed by ${(d['confirmed_by'] as List).length}'),
      onTap: room == null ? null : () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id))))]);
  }));
}
