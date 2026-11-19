import '../services/locale.dart';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import '../services/workflow_runner.dart';

/// Workflows (docs/WORKFLOWS.md): describe it in a sentence, review the flow, dry-run, save and switch on.
class WorkflowsScreen extends StatefulWidget {
  const WorkflowsScreen({super.key});
  @override State<WorkflowsScreen> createState() => _S();
}

class _S extends State<WorkflowsScreen> {
  List<Map<String, dynamic>>? list; String? err;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final l = (await api.workflows()).cast<Map<String, dynamic>>(); if (mounted) setState(() { list = l; err = null; }); WorkflowRunner.instance.refresh(); }
    catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Future<void> _open([Map<String, dynamic>? w]) async {
    await Navigator.push(context, MaterialPageRoute(builder: (_) => WorkflowEditor(existing: w)));
    _load();
  }

  @override Widget build(BuildContext c) {
    final r = WorkflowRunner.instance;
    return Scaffold(
      appBar: AppBar(title: Text(L.t(context, 'Workflows')), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
      floatingActionButton: FloatingActionButton.extended(onPressed: () => _open(), icon: const Icon(Icons.add), label: Text(L.t(context, 'New workflow'))),
      body: list == null ? Center(child: err != null ? Text(err!) : const CircularProgressIndicator())
        : ListView(padding: const EdgeInsets.only(bottom: 96), children: [
            const Padding(padding: EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(
              'Workflows run on this device with your own rights: they read and post encrypted messages only in chats you are in, and only while the app is open. The server keeps versions and run status, never message content.',
              style: TextStyle(fontSize: 12))),
            if (r.lastError.isNotEmpty) ListTile(leading: const Icon(Icons.error_outline, color: Colors.red), title: Text(r.lastError), dense: true),
            if (list!.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No workflows yet. Describe one in a sentence to start.'))),
            for (final w in list!) Card(margin: const EdgeInsets.fromLTRB(12, 6, 12, 6), child: ExpansionTile(
              leading: const Icon(Icons.account_tree_outlined),
              title: Text('${w['name']}'),
              subtitle: Text('v${w['version']} · ${_trigger(w['definition']['trigger'] as Map)}'),
              trailing: Switch(value: w['enabled'] == true, onChanged: (v) async {
                try { await api.workflowEnable(w['id'] as String, v); _load(); }
                catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); }
              }),
              children: [
                Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: Row(children: [
                  TextButton.icon(icon: const Icon(Icons.edit_outlined), label: Text(L.t(context, 'Edit')), onPressed: () => _open(w)),
                  TextButton.icon(icon: const Icon(Icons.play_arrow), label: Text(L.t(context, 'Run now')), onPressed: () async {
                    final id = await WorkflowRunner.instance.runNow(w);
                    if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text(id != null ? 'Started' : WorkflowRunner.instance.lastError)));
                    setState(() {});
                  }),
                ])),
                FutureBuilder<List<dynamic>>(future: api.workflowRuns(w['id'] as String), builder: (_, s) {
                  final runs = s.data ?? const [];
                  if (runs.isEmpty) return const ListTile(dense: true, title: Text('No runs yet'));
                  return Column(children: [for (final run in runs.take(10)) ListTile(dense: true,
                    leading: Icon(switch (run['status']) { 'succeeded' => Icons.check_circle, 'running' => Icons.timelapse, _ => Icons.cancel },
                        color: switch (run['status']) { 'succeeded' => Colors.green, 'running' => Colors.blue, _ => Colors.red }),
                    title: Text('${run['status']} · v${run['version']} · ${(run['trigger'] as Map?)?['type'] ?? ''}'),
                    subtitle: Text('${DateFormat('d MMM HH:mm').format(DateTime.fromMillisecondsSinceEpoch(((run['started_at'] as num) * 1000).round()))} · '
                        '${(run['step_results'] as Map? ?? {}).entries.map((e) => '${e.key} ${(e.value as Map)['status']}${((e.value as Map)['error'] ?? '') != '' ? ' (${(e.value as Map)['error']})' : ''}').join(', ')}'))]);
                }),
              ])),
          ]),
    );
  }
}

String _trigger(Map t) => switch (t['type']) {
  'message' => 'when a message${(((t['match'] as Map?)?['keywords'] as List?) ?? const []).isNotEmpty ? ' mentions ${((t['match'] as Map)['keywords'] as List).join(' or ')}' : ''} arrives',
  'schedule' => 'on schedule ${t['cron']}', 'manual' => 'run by hand', _ => '${t['type']}' };

/// Draft from a sentence, review as a flow, dry-run, save.
class WorkflowEditor extends StatefulWidget {
  const WorkflowEditor({super.key, this.existing});
  final Map<String, dynamic>? existing;
  @override State<WorkflowEditor> createState() => _E();
}

class _E extends State<WorkflowEditor> {
  final describe = TextEditingController(), json = TextEditingController(), sample = TextEditingController();
  Map<String, dynamic>? d; List<String> assumptions = [], errors = []; List<dynamic>? dry;
  bool busy = false, raw = false, enable = true; String? note;
  ApiService get api => context.read<ApiService>();
  Client get cl => context.read<MatrixService>().client;
  String _name(String? id) => id == null ? '?' : (cl.getRoomById(id)?.getLocalizedDisplayname() ?? id);

  @override void initState() {
    super.initState();
    if (widget.existing != null) _set(Map<String, dynamic>.from(widget.existing!['definition'] as Map));
  }
  void _set(Map<String, dynamic> def) {
    d = def; json.text = const JsonEncoder.withIndent('  ').convert(def); dry = null;
    final s = <String, Object?>{'trigger': {'sender': cl.userID, 'body': 'sample message', 'room': def['trigger']?['room']}};
    for (final st in (def['steps'] as List? ?? const [])) {
      if (st['type'] == 'ask_form') s['${st['id']}'] = {for (final f in (st['fields'] as List)) '$f': '1'};
      if (st['type'] == 'approval') s['${st['id']}'] = {'decision': 'approved'};
    }
    sample.text = const JsonEncoder.withIndent('  ').convert(s);
  }
  List<Map<String, String>> get _rooms => [for (final r in cl.rooms.where((r) => r.membership == Membership.join && !r.isSpace)) {'room_id': r.id, 'name': r.getLocalizedDisplayname()}];

  Future<void> _draft() async {
    setState(() { busy = true; note = null; });
    try {
      final r = await api.workflowDraft(describe.text.trim(), _rooms);
      _set(Map<String, dynamic>.from(r['definition'] as Map));
      assumptions = (r['assumptions'] as List).cast<String>(); errors = (r['errors'] as List).cast<String>();
    } catch (e) { note = '$e'.replaceFirst('Exception: ', ''); }
    if (mounted) setState(() => busy = false);
  }
  void _template() {
    final r = _rooms.isEmpty ? null : _rooms.first['room_id'];
    _set({'name': 'Approval request', 'trigger': {'type': 'message', 'room': r, 'match': {'keywords': ['approve']}},
      'steps': [{'id': 's1', 'type': 'approval', 'approvers': [cl.userID], 'timeout_h': 48, 'room': r},
                {'id': 's2', 'type': 'condition', 'if': r"$s1.decision == 'approved'", 'then': 's3', 'else': 's4'},
                {'id': 's3', 'type': 'post', 'room': r, 'text': 'Approved by {{s1.by}}', 'next': 'end'},
                {'id': 's4', 'type': 'post', 'room': r, 'text': 'Rejected by {{s1.by}}'}]});
    setState(() { assumptions = ['Edit the chat and approvers in the JSON below']; errors = []; raw = true; });
  }
  bool _readJson() {
    try { d = Map<String, dynamic>.from(jsonDecode(json.text) as Map); return true; }
    catch (e) { setState(() => errors = ['The JSON is not valid: $e']); return false; }
  }
  Future<void> _dry() async {
    if (raw && !_readJson()) return;
    setState(() => busy = true);
    try {
      final r = await api.workflowDryRun(d!, Map<String, Object?>.from(jsonDecode(sample.text) as Map));
      dry = r['steps'] as List; errors = [];
    } catch (e) { errors = ['$e'.replaceFirst('Exception: ', '')]; }
    if (mounted) setState(() => busy = false);
  }
  Future<void> _save() async {
    if (raw && !_readJson()) return;
    setState(() => busy = true);
    try {
      await api.workflowSave(d!, id: widget.existing?['id'] as String?, enabled: enable);
      if (mounted) Navigator.pop(context);
      return;
    } catch (e) { errors = ['$e'.replaceFirst('Exception: ', '')]; }
    if (mounted) setState(() => busy = false);
  }

  Widget _step(BuildContext c, Map s) {
    final cs = Theme.of(c).colorScheme;
    final (icon, text) = switch (s['type']) {
      'post' => (Icons.send_outlined, 'Post in ${_name(s['room'] as String?)}: “${s['text']}”'),
      'ask_form' => (Icons.assignment_outlined, 'Ask ${s['to']} for ${(s['fields'] as List?)?.join(', ')}'),
      'approval' => (Icons.verified_outlined, 'Ask ${(s['approvers'] as List?)?.join(', ')} to approve${s['timeout_h'] != null ? ' within ${s['timeout_h']} h' : ''}'),
      'condition' => (Icons.call_split, 'If ${s['if']} → ${s['then'] ?? 'next'}, otherwise → ${s['else'] ?? 'next'}'),
      'wait' => (Icons.hourglass_empty, 'Wait ${s['minutes']} minutes'),
      'run_agent' => (Icons.auto_awesome, 'Ask Amer: ${s['prompt']}'),
      'http' => (Icons.http, 'Call ${s['url']} (admin-approved hosts only)'),
      'create_task' => (Icons.add_task, 'Create task “${s['title']}” for ${s['assignee'] ?? 'me'}${s['due_days'] != null ? ', due in ${s['due_days']} days' : ''}'),
      _ => (Icons.help_outline, '${s['type']}'),
    };
    return Column(children: [
      Card(margin: const EdgeInsets.symmetric(horizontal: 12), child: ListTile(leading: CircleAvatar(child: Icon(icon, size: 18)),
        title: Text(text), subtitle: Text('${s['id']}${s['next'] == 'end' ? ' · then stop' : s['next'] != null ? ' · then ${s['next']}' : ''}', style: TextStyle(color: cs.outline)))),
      Icon(Icons.arrow_downward, size: 18, color: cs.outline),
    ]);
  }

  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return Scaffold(
      appBar: AppBar(title: Text(widget.existing == null ? 'New workflow' : 'Edit ${widget.existing!['name']}'), actions: [
        if (d != null) TextButton(onPressed: () => setState(() { if (raw) _readJson(); else json.text = const JsonEncoder.withIndent('  ').convert(d); raw = !raw; }), child: Text(raw ? 'Flow' : 'JSON')),
        if (d != null) FilledButton(onPressed: busy ? null : _save, child: Text(L.t(context, 'Save')))]),
      body: ListView(padding: const EdgeInsets.only(bottom: 32), children: [
        if (widget.existing == null) Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          TextField(controller: describe, minLines: 2, maxLines: 4, decoration: const InputDecoration(border: OutlineInputBorder(),
            labelText: 'Describe the workflow', hintText: 'When someone posts a quote in RFP, ask Sara to approve it and post the result in RFP log')),
          const SizedBox(height: 8),
          Row(children: [
            FilledButton.icon(onPressed: busy ? null : _draft, icon: const Icon(Icons.auto_awesome), label: Text(L.t(context, 'Draft with Amer'))),
            const SizedBox(width: 8), TextButton(onPressed: _template, child: Text(L.t(context, 'Start from a template'))),
          ]),
          if (note != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(note!, style: TextStyle(color: cs.error))),
        ])),
        if (busy) const LinearProgressIndicator(),
        if (d != null) ...[
          if (assumptions.isNotEmpty) Card(margin: const EdgeInsets.all(12), color: cs.secondaryContainer, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Amer assumed', style: TextStyle(fontWeight: FontWeight.w600)), for (final a in assumptions) Text('• $a')]))),
          for (final e in errors) ListTile(dense: true, leading: Icon(Icons.error_outline, color: cs.error), title: Text(e, style: TextStyle(color: cs.error))),
          if (raw) Padding(padding: const EdgeInsets.all(12), child: TextField(controller: json, maxLines: 18, style: const TextStyle(fontFamily: 'monospace', fontSize: 12), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Definition (JSON)')))
          else ...[
            ListTile(title: Text('${d!['name']}', style: Theme.of(c).textTheme.titleMedium), subtitle: Text(_trigger((d!['trigger'] as Map?) ?? {}) +
                ((d!['trigger'] as Map?)?['room'] != null ? ' in ${_name((d!['trigger'] as Map)['room'] as String?)}' : ''))),
            Icon(Icons.arrow_downward, size: 18, color: cs.outline),
            for (final s in (d!['steps'] as List? ?? const [])) _step(c, s as Map),
            const Center(child: Text('Done')),
          ],
          ExpansionTile(title: const Text('Dry run (sends nothing)'), children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: TextField(controller: sample, maxLines: 8, style: const TextStyle(fontFamily: 'monospace', fontSize: 12), decoration: const InputDecoration(border: OutlineInputBorder(), labelText: 'Sample data'))),
            Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.all(8), child: OutlinedButton.icon(onPressed: busy ? null : _dry, icon: const Icon(Icons.science_outlined), label: Text(L.t(context, 'Dry run'))))),
            if (dry != null) for (final s in dry!) ListTile(dense: true, leading: const Icon(Icons.check, size: 16), title: Text('${s['step']}: ${s['would']}')),
          ]),
          SwitchListTile(title: const Text('Switch on after saving'), value: enable, onChanged: (v) => setState(() => enable = v)),
          Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: FilledButton.icon(onPressed: busy ? null : _save, icon: const Icon(Icons.save_outlined),
            label: Text(widget.existing == null ? 'Save workflow' : 'Save as version ${(widget.existing!['version'] as int) + 1}'))),
        ],
      ]),
    );
  }
}
