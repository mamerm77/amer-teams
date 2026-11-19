import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/ai_gate.dart';
import '../services/api_service.dart';
import '../services/decisions_tasks.dart';

/// Meeting digital twin (docs/MEETING_TWIN.md): everything a recurring meeting has produced, built on this device from
/// the chat's own (end-to-end encrypted) history: every set of minutes, decisions, open and overdue actions, topics
/// that keep coming back, and "ask the meeting's history" across all of it.
class MeetingTwinScreen extends StatefulWidget {
  const MeetingTwinScreen({super.key, required this.room});
  final Room room;
  @override State<MeetingTwinScreen> createState() => _S();
}
class _S extends State<MeetingTwinScreen> {
  List<Event> minutes = [], decisions = []; List<Task> tasks = []; List<(String, int)> recurring = []; bool loading = true; String? answer; final q = TextEditingController(); bool asking = false;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final tl = await widget.room.getTimeline();
    for (var i = 0; i < 8 && tl.canRequestHistory; i++) { await tl.requestHistory(historyCount: 200); }   // up to ~1,600 events back
    final ev = tl.events;
    minutes = ev.where((e) => e.type == EventTypes.Message && (e.body.startsWith('📝 Minutes') || e.body.startsWith('📝 Post-incident'))).toList();
    decisions = ev.where((e) => e.type == kDecisionProposal).toList();
    tasks = tasksIn(ev);
    // topics that recur: capitalised terms / acronyms appearing in at least 3 different sets of minutes
    final perMin = minutes.map((m) => RegExp(r'\b([A-Z][A-Za-z0-9+/-]{2,}(?:\s[A-Z][A-Za-z0-9+/-]{2,})?)\b').allMatches(m.body).map((x) => x.group(1)!).toSet()).toList();
    final count = <String, int>{}; for (final s in perMin) { for (final t in s) { count[t] = (count[t] ?? 0) + 1; } }
    const skip = {'Minutes', 'Attendees', 'Agenda', 'Discussion', 'Decisions', 'Actions', 'Summary', 'Impact', 'Timeline', 'The', 'None', 'Owner', 'Due'};
    recurring = (count.entries.where((e) => e.value >= 3 && !skip.contains(e.key)).map((e) => (e.key, e.value)).toList()..sort((a, b) => b.$2.compareTo(a.$2))).take(12).toList();
    tl.cancelSubscriptions();
    if (mounted) setState(() => loading = false);
  }
  Future<void> _ask() async {
    final g = aiFor(widget.room); if (!g.allowed) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(g.where))); return; }
    setState(() { asking = true; answer = null; });
    final ctx = [for (final m in minutes.reversed) '=== ${m.originServerTs.toIso8601String().substring(0, 10)} ===\n${m.body}',
      '=== Decisions ===', for (final d in decisions) '${d.originServerTs.toIso8601String().substring(0, 10)}: ${d.content['text']}',
      '=== Actions ===', for (final t in tasks) '${t.title} · ${t.status}${t.due != null ? ' · due ${t.due!.toIso8601String().substring(0, 10)}' : ''}'].join('\n');
    final label = widget.room.getState('com.amerteams.sensitivity')?.content['label'] as String?;
    try {
      final r = await context.read<ApiService>().ask('${q.text}\nAnswer from this meeting series\' history only, and cite the meeting date for each point. Say so if the history does not say.',
          context: ctx.length > 50000 ? ctx.substring(ctx.length - 50000) : ctx, agent: 'assist', labels: [if (label != null) label], encrypted: widget.room.encrypted);
      if (mounted) setState(() => answer = '${r['answer']}\n\n${g.where}');
    } catch (e) { if (mounted) setState(() => answer = 'Could not ask: $e'); }
    if (mounted) setState(() => asking = false);
  }
  @override
  Widget build(BuildContext c) {
    final open = tasks.where((t) => t.status != 'done').toList(), overdue = open.where((t) => t.overdue).length;
    String d(DateTime t) => t.toIso8601String().substring(0, 10);
    return Scaffold(appBar: AppBar(title: Text('Meeting twin · ${widget.room.getLocalizedDisplayname()}')), body: loading ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 8, runSpacing: 8, children: [
        Chip(label: Text('${minutes.length} meetings with minutes')), Chip(label: Text('${decisions.length} decisions')),
        Chip(label: Text('${open.length} open actions')), if (overdue > 0) Chip(backgroundColor: Colors.red.withValues(alpha: 0.15), label: Text('$overdue overdue')),
      ]),
      const SizedBox(height: 8),
      TextField(controller: q, decoration: InputDecoration(hintText: 'Ask the meeting\'s history, e.g. "What did we decide about the Nokia spares?"',
        suffixIcon: asking ? const Padding(padding: EdgeInsets.all(12), child: SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))) : IconButton(tooltip: 'Ask', icon: const Icon(Icons.send), onPressed: _ask)), onSubmitted: (_) => _ask()),
      if (answer != null) Card(child: Padding(padding: const EdgeInsets.all(12), child: SelectableText(answer!))),
      if (recurring.isNotEmpty) ...[const ListTile(title: Text('Keeps coming back')), Wrap(spacing: 6, children: [for (final (t, n) in recurring) Chip(label: Text('$t ×$n'))])],
      ExpansionTile(title: Text('Open actions (${open.length})'), initiallyExpanded: open.isNotEmpty, children: [for (final t in open) ListTile(dense: true, leading: Icon(t.overdue ? Icons.warning_amber : Icons.radio_button_unchecked, color: t.overdue ? Colors.red : null),
        title: Text(t.title), subtitle: Text('${widget.room.unsafeGetUserFromMemoryOrFallback(t.owner).calcDisplayname()}${t.due != null ? ' · due ${d(t.due!)}' : ''}'))]),
      ExpansionTile(title: Text('Decisions (${decisions.length})'), children: [for (final e in decisions) ListTile(dense: true, title: Text('${e.content['text']}'), subtitle: Text(d(e.originServerTs)))]),
      ExpansionTile(title: Text('Every meeting (${minutes.length})'), children: [for (final m in minutes) ExpansionTile(title: Text(d(m.originServerTs)), children: [Padding(padding: const EdgeInsets.all(12), child: SelectableText(m.body))])]),
    ]));
  }
}
