import '../services/locale.dart';
import '../services/labels.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/ai_gate.dart';
import '../services/api_service.dart';

/// Skills, custom agents and the organisation's marketplace (docs/SKILLS.md).
class SkillsScreen extends StatefulWidget {
  const SkillsScreen({super.key, this.room, this.context});
  final Room? room; final String? context;          // opened from a chat: runs use that chat's recent messages
  @override State<SkillsScreen> createState() => _S();
}
class _S extends State<SkillsScreen> {
  List<dynamic>? mine, market, queue; String? err;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final api = context.read<ApiService>();
    try {
      final a = await api.listGet('/v1/skills/mine'), b = await api.listGet('/v1/skills/marketplace');
      List<dynamic>? q; try { q = await api.listGet('/v1/skills/review-queue'); } catch (_) {}
      if (mounted) setState(() { mine = a; market = b; queue = q; err = null; });
    } catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _edit([Map? s]) async {
    var kind = '${s?['kind'] ?? 'skill'}';
    final name = TextEditingController(text: s?['name']), desc = TextEditingController(text: s?['description']), ins = TextEditingController(text: s?['instructions']);
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text(s == null ? 'New skill or agent' : 'Edit ${s['name']}'),
      content: SizedBox(width: 520, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        if (s == null) SegmentedButton<String>(segments: const [ButtonSegment(value: 'skill', label: Text('Skill'), icon: Icon(Icons.bolt)), ButtonSegment(value: 'agent', label: Text('Custom agent'), icon: Icon(Icons.smart_toy_outlined))],
          selected: {kind}, onSelectionChanged: (v) => set(() => kind = v.first)),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: desc, decoration: const InputDecoration(labelText: 'What it is for')),
        TextField(controller: ins, minLines: 4, maxLines: 10, decoration: InputDecoration(labelText: 'Instructions',
          helperText: kind == 'skill' ? 'Use {{input_name}} for what the person fills in, e.g. Draft an RFP clause about {{topic}}.' : 'Who the agent is and how it answers, e.g. You are our DWDM capacity planner…', helperMaxLines: 3)),
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Save')))])));
    if (ok != true || !mounted) return;
    final api = context.read<ApiService>(); final body = {'kind': kind, 'name': name.text, 'description': desc.text, 'instructions': ins.text};
    try { s == null ? await api.postMap('/v1/skills', body) : await api.putMap('/v1/skills/${s['id']}', body); _load(); } catch (e) { _snack('$e'.replaceFirst('Exception: ', '')); }
  }

  Future<void> _run(Map s) async {
    final r = widget.room; if (r != null) { final g = aiFor(r); if (!g.allowed) { _snack(g.where); return; } }
    final ctrls = {for (final i in (s['kind'] == 'agent' ? ['input'] : (s['inputs'] as List).cast<String>())) i: TextEditingController()};
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text('${s['name']}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        if (widget.context != null) const Text('Uses this chat\'s recent messages as context.', style: TextStyle(fontSize: 12)),
        for (final e in ctrls.entries) TextField(controller: e.value, minLines: 1, maxLines: 4, decoration: InputDecoration(labelText: e.key == 'input' ? 'Your request' : e.key.replaceAll('_', ' '))),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Run')))]));
    if (ok != true || !mounted) return;
    final label = widget.room == null ? null : labelOf(widget.room!);
    try {
      final res = await context.read<ApiService>().postMap('/v1/skills/${s['id']}/run', {'values': {for (final e in ctrls.entries) e.key: e.value.text}, 'context': widget.context ?? '',
        'labels': [if (label != null) label], 'encrypted': widget.room?.encrypted ?? false});
      if (!mounted) return;
      await showModalBottomSheet(context: context, isScrollControlled: true, builder: (b) => DraggableScrollableSheet(expand: false, initialChildSize: 0.7, builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.all(16), children: [
        Text('${s['name']} · only you see this', style: Theme.of(b).textTheme.titleMedium), const SizedBox(height: 8), SelectableText('${res['answer']}'),
        if (widget.room != null && res['blocked'] != true && res['error'] != true) Padding(padding: const EdgeInsets.only(top: 12), child: FilledButton.icon(icon: const Icon(Icons.share), label: Text(L.t(context, 'Share in chat')),
          onPressed: () async { Navigator.pop(b); await widget.room!.sendTextEvent('${res['answer']}'); })),
      ])));
    } catch (e) { _snack('$e'.replaceFirst('Exception: ', '')); }
  }

  Widget _tile(Map s, {bool market = false, bool review = false}) => ListTile(
    leading: Icon(s['kind'] == 'agent' ? Icons.smart_toy_outlined : Icons.bolt),
    title: Text('${s['name']}'),
    subtitle: Text([if ('${s['description'] ?? ''}'.isNotEmpty) s['description'], if (!market) 'status: ${s['status']}${'${s['review_note'] ?? ''}'.isNotEmpty ? ' (${s['review_note']})' : ''} · v${s['version']}', if (market) '${s['installs']} installs · by ${s['owner']}'].join('\n')),
    isThreeLine: true,
    trailing: Wrap(spacing: 4, children: [
      if (review) ...[
        IconButton(tooltip: 'Approve', icon: const Icon(Icons.check), onPressed: () async { await context.read<ApiService>().postMap('/v1/skills/${s['id']}/review', {'approve': true}); _load(); }),
        IconButton(tooltip: 'Reject', icon: const Icon(Icons.close), onPressed: () async {
          final t = TextEditingController();
          final why = await showDialog<String>(context: context, builder: (d) => AlertDialog(title: const Text('Why is it rejected?'), content: TextField(controller: t), actions: [FilledButton(onPressed: () => Navigator.pop(d, t.text), child: Text(L.t(context, 'Reject')))]));
          if (why != null && why.isNotEmpty && mounted) { await context.read<ApiService>().postMap('/v1/skills/${s['id']}/review', {'approve': false, 'note': why}); _load(); } }),
      ] else if (market && s['installed'] != true) FilledButton.tonal(onPressed: () async { await context.read<ApiService>().postMap('/v1/skills/${s['id']}/install', {}); _load(); }, child: Text(L.t(context, 'Install')))
      else ...[
        IconButton(tooltip: 'Run', icon: const Icon(Icons.play_arrow), onPressed: () => _run(s)),
        if (!market && s['status'] == 'private') IconButton(tooltip: 'Submit to the marketplace', icon: const Icon(Icons.storefront), onPressed: () async { await context.read<ApiService>().postMap('/v1/skills/${s['id']}/submit', {}); _snack('Sent for review'); _load(); }),
        if (!market) IconButton(tooltip: 'Edit', icon: const Icon(Icons.edit), onPressed: () => _edit(s)),
      ],
    ]));

  @override
  Widget build(BuildContext c) => DefaultTabController(length: queue == null ? 2 : 3, child: Scaffold(
    appBar: AppBar(title: Text(L.t(context, 'Skills and agents')), bottom: TabBar(tabs: [const Tab(text: 'Mine'), const Tab(text: 'Marketplace'), if (queue != null) Tab(text: 'Review (${queue!.length})')])),
    floatingActionButton: FloatingActionButton.extended(onPressed: () => _edit(), icon: const Icon(Icons.add), label: Text(L.t(context, 'New'))),
    body: err != null ? Center(child: Text(err!)) : mine == null ? const Center(child: CircularProgressIndicator()) : TabBarView(children: [
      ListView(children: [if (mine!.isEmpty) const ListTile(title: Text('No skills yet'), subtitle: Text('Make one for a task you repeat, or install one from the marketplace.')), for (final s in mine!) _tile(s, market: s['owner'] != context.read<ApiService>().me)]),
      ListView(children: [if (market!.isEmpty) const ListTile(title: Text('Nothing published in your organisation yet')), for (final s in market!) _tile(s, market: true)]),
      if (queue != null) ListView(children: [if (queue!.isEmpty) const ListTile(title: Text('Nothing to review')), for (final s in queue!) _tile(s, review: true)]),
    ])));
}
