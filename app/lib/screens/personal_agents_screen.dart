import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/glass_box.dart';
import '../services/matrix_service.dart';

/// My agent team (docs/PERSONAL_AGENTS.md): give a goal, attach chats, watch the team, approve what it sends.
class PersonalAgentsScreen extends StatefulWidget {
  const PersonalAgentsScreen({super.key});
  @override State<PersonalAgentsScreen> createState() => _S();
}

class _S extends State<PersonalAgentsScreen> {
  final goal = TextEditingController(); final picked = <String>{};
  List<Map<String, dynamic>> projects = []; Map<String, dynamic>? budget; String? note; bool busy = false;
  final events = <String, List<Map<String, dynamic>>>{}; String? open; Timer? t;
  ApiService get api => context.read<ApiService>();
  Client get cl => context.read<MatrixService>().client;

  @override void initState() { super.initState(); GlassBox.instance.addListener(_r); _load(); t = Timer.periodic(const Duration(seconds: 4), (_) => _load()); }
  @override void dispose() { t?.cancel(); GlassBox.instance.removeListener(_r); super.dispose(); }
  void _r() { if (mounted) setState(() {}); }

  Future<void> _load() async {
    if (!mounted) return;
    try {
      final p = (await api.agentopsProjects()).cast<Map<String, dynamic>>().where((p) => p['scope'] == 'personal' && p['created_by'] == cl.userID).toList();
      final b = await api.agentBudget();
      if (open != null) events[open!] = (await api.agentopsEvents(projectId: open)).cast<Map<String, dynamic>>();
      await GlassBox.instance.poll();
      if (mounted) setState(() { projects = p; budget = b; });
    } catch (_) {}
  }

  /// The attached chats are read and decrypted here; their recent text goes with the goal.
  Future<void> _start() async {
    setState(() { busy = true; note = null; });
    try {
      final att = <Map<String, Object?>>[];
      for (final id in picked) {
        final r = cl.getRoomById(id); if (r == null) continue;
        final tl = await r.getTimeline(limit: 100);
        final text = tl.events.where((e) => e.type == EventTypes.Message).take(100).toList().reversed
            .map((e) => '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${e.body}').join('\n');
        tl.cancelSubscriptions();
        att.add({'room_id': id, 'name': r.getLocalizedDisplayname(), 'text': text});
      }
      final res = await api.personalStart(goal.text.trim(), att);
      open = res['project_id'] as String; goal.clear(); picked.clear();
      await _load();
    } catch (e) { note = '$e'.replaceFirst('Exception: ', ''); }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _edit(Map<String, dynamic> a) async {
    final p = Map<String, Object?>.from(a['payload'] as Map);
    final key = p.containsKey('text') ? 'text' : 'title';
    final c = TextEditingController(text: '${p[key]}');
    final v = await showDialog<String>(context: context, builder: (d) => AlertDialog(title: const Text('Edit before approving'),
      content: TextField(controller: c, maxLines: 6, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Approve edited'))]));
    if (v != null) await GlassBox.instance.decide(a['id'] as String, 'edit', edited: {...p, key: v});
  }
  Future<void> _reject(Map<String, dynamic> a) async {
    final c = TextEditingController();
    final v = await showDialog<String>(context: context, builder: (d) => AlertDialog(title: const Text('Reject'),
      content: TextField(controller: c, decoration: const InputDecoration(labelText: 'Reason (the agent will re-plan)')),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, c.text), child: const Text('Reject'))]));
    if (v != null) await GlassBox.instance.decide(a['id'] as String, 'reject', reason: v);
  }

  Widget _approval(BuildContext c, Map<String, dynamic> a) {
    final pv = Map<String, Object?>.from(a['preview'] as Map), cs = Theme.of(c).colorScheme;
    final exp = DateTime.fromMillisecondsSinceEpoch(((a['expires_at'] as num) * 1000).round());
    return Card(margin: const EdgeInsets.fromLTRB(12, 6, 12, 6), color: cs.tertiaryContainer, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [const Icon(Icons.pan_tool_outlined), const SizedBox(width: 8), Expanded(child: Text('Your ${a['agent']} wants to ${a['tool'] == 'send_message' ? 'send a message' : 'book a meeting'}', style: const TextStyle(fontWeight: FontWeight.w600)))]),
      const SizedBox(height: 6),
      if ('${pv['plan'] ?? ''}'.isNotEmpty) Text('Why: ${pv['plan']}'),
      Text('To: ${pv['target'] ?? ''}'),
      Container(width: double.infinity, margin: const EdgeInsets.symmetric(vertical: 8), padding: const EdgeInsets.all(10), color: cs.surface,
        child: Text(pv['kind'] == 'message' ? '${pv['text']}' : '${pv['title']} · ${pv['start']} · ${pv['duration_min']} min')),
      if ((pv['data_touched'] as List?)?.isNotEmpty == true) Text('Data touched: ${(pv['data_touched'] as List).join(', ')}', style: const TextStyle(fontSize: 12)),
      Text('Cost: not estimated · expires ${TimeOfDay.fromDateTime(exp).format(c)}', style: TextStyle(fontSize: 12, color: cs.outline)),
      const SizedBox(height: 6),
      Wrap(spacing: 8, children: [
        OutlinedButton(onPressed: () => _reject(a), child: const Text('Reject')),
        OutlinedButton(onPressed: () => _edit(a), child: const Text('Edit')),
        FilledButton(onPressed: () => GlassBox.instance.decide(a['id'] as String, 'approve'), child: const Text('Approve')),
      ]),
    ])));
  }

  String _line(Map<String, dynamic> e) {
    final d = Map<String, dynamic>.from(e['data'] as Map? ?? {});
    return switch (e['type']) {
      'tool.started' => '${e['agent']} → ${d['summary'] ?? d['tool']}', 'tool.failed' => '${e['agent']} ✗ ${d['tool']}: ${d['error']}',
      'agent.message' => '${e['agent']}: ${d['text']}', 'handoff' => '${e['agent']} hands to ${d['to']}: ${d['brief']}',
      'approval.requested' => '⏸ waiting for your approval (${d['tool']})', 'approval.decided' => '▶ approval ${d['status']}',
      'deliverable.saved' => '📄 saved ${d['title']}', 'project.finished' => d['ok'] == true ? '✓ finished' : '✗ ended: ${d['error'] ?? d['subtype'] ?? ''}',
      _ => '${e['type']}' };
  }

  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    final rooms = cl.rooms.where((r) => r.membership == Membership.join && !r.isSpace).take(30).toList();
    final used = (budget?['tokens_used'] as num?) ?? 0, cap = (budget?['tokens_cap'] as num?) ?? 1;
    return Scaffold(
      appBar: AppBar(title: const Text('My agent team')),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        for (final a in GlassBox.instance.awaiting) _approval(c, a),
        Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: goal, minLines: 2, maxLines: 4, onChanged: (_) => setState(() {}), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Goal',
            hintText: 'Prepare the vendor comparison for Sunday from the optical team chat')),
          const SizedBox(height: 8),
          Text('Attach chats the team may read (decrypted on this device and sent with the goal):', style: TextStyle(fontSize: 12, color: cs.outline)),
          Wrap(spacing: 6, children: [for (final r in rooms) FilterChip(label: Text(r.getLocalizedDisplayname()), selected: picked.contains(r.id),
            onSelected: (v) => setState(() => v ? picked.add(r.id) : picked.remove(r.id)))]),
          const SizedBox(height: 8),
          FilledButton.icon(onPressed: busy || goal.text.trim().length < 10 ? null : _start, icon: const Icon(Icons.rocket_launch_outlined), label: const Text('Start my team')),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(note!, style: TextStyle(color: cs.error))),
          const SizedBox(height: 8),
          LinearProgressIndicator(value: (used / cap).clamp(0, 1).toDouble()),
          Text('This month: $used of $cap tokens. At the limit the team stops.', style: const TextStyle(fontSize: 12)),
          const SizedBox(height: 4),
          Text('Your team reads only what you attach, saves its work here, and sends nothing until you approve it.', style: TextStyle(fontSize: 12, color: cs.outline)),
        ])),
        for (final p in projects) Card(margin: const EdgeInsets.fromLTRB(12, 6, 12, 6), child: ExpansionTile(
          initiallyExpanded: p['project_id'] == open,
          onExpansionChanged: (v) { if (v) { open = p['project_id'] as String; _load(); } },
          leading: Icon(p['status'] == 'running' ? Icons.timelapse : p['status'] == 'done' ? Icons.check_circle : Icons.cancel,
              color: p['status'] == 'running' ? Colors.blue : p['status'] == 'done' ? Colors.green : Colors.red),
          title: Text('${p['name']}'), subtitle: Text('${p['status']}${p['cost_usd'] != null ? ' · \$${(p['cost_usd'] as num).toStringAsFixed(3)}' : ''}'),
          children: [
            if (p['status'] == 'running') TextButton.icon(icon: const Icon(Icons.stop), label: const Text('Stop the team'), onPressed: () => api.personalStop(p['project_id'] as String)),
            for (final e in (events[p['project_id']] ?? const []).reversed.take(40)) ListTile(dense: true, title: Text(_line(e), maxLines: 3, overflow: TextOverflow.ellipsis)),
            FutureBuilder<List<dynamic>>(future: api.deliverables(p['project_id'] as String), builder: (_, s) => Column(children: [
              for (final d in s.data ?? const []) ListTile(leading: const Icon(Icons.description_outlined), title: Text('${d['name']}'),
                onTap: () => showDialog(context: c, builder: (x) => AlertDialog(title: Text('${d['name']}'),
                  content: SingleChildScrollView(child: SelectableText('${d['markdown']}')),
                  actions: [TextButton(onPressed: () => Navigator.pop(x), child: const Text('Close'))])))])),
          ])),
      ]),
    );
  }
}
