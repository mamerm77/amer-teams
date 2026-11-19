import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Tool connectors for a chat (docs/TOOL_CONNECTORS.md).
class ConnectorsScreen extends StatefulWidget {
  const ConnectorsScreen({super.key, required this.room});
  final Room room;
  @override State<ConnectorsScreen> createState() => _S();
}
class _S extends State<ConnectorsScreen> {
  List<dynamic>? rows; String? err;
  static const kinds = {'github': 'GitHub', 'gitlab': 'GitLab', 'jira': 'Jira', 'alertmanager': 'Prometheus Alertmanager', 'grafana': 'Grafana alerts', 'servicenow': 'ServiceNow', 'jenkins': 'Jenkins', 'generic': 'Any tool (JSON with "text")'};
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final r = await context.read<ApiService>().listGet('/v1/connectors?room_id=${Uri.encodeQueryComponent(widget.room.id)}'); if (mounted) setState(() => rows = r); }
    catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Future<void> _add() async {
    var kind = 'github'; final name = TextEditingController(text: 'GitHub');
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Add a connector'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(value: kind, isExpanded: true, items: [for (final k in kinds.entries) DropdownMenuItem(value: k.key, child: Text(k.value))], onChanged: (v) => set(() { kind = v!; name.text = kinds[v]!.split(' (').first; })),
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Name shown on each message')),
      const SizedBox(height: 8),
      const Text('The Connectors account joins this chat as a member, so it can post end-to-end encrypted messages here.', style: TextStyle(fontSize: 12)),
    ]), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Add'))])));
    if (ok != true || !mounted) return;
    final api = context.read<ApiService>();
    try {
      final r = await api.postMap('/v1/connectors', {'room_id': widget.room.id, 'kind': kind, 'name': name.text});
      if (widget.room.getParticipants().every((u) => u.id != r['invite'])) await widget.room.invite('${r['invite']}');
      final url = api.publicUrl('${r['path']}').toString();
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Webhook URL'), content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        SelectableText(url), const SizedBox(height: 8),
        Text('Paste it into ${kinds[kind]}\'s webhook settings (content type JSON). It is shown only now; anyone with it can post here, so keep it secret.', style: const TextStyle(fontSize: 12))]),
        actions: [FilledButton(onPressed: () { Clipboard.setData(ClipboardData(text: url)); Navigator.pop(d); }, child: const Text('Copy and close'))]));
      _load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Connectors')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add_link), label: const Text('Add connector')),
    body: err != null ? Center(child: Text(err!)) : rows == null ? const Center(child: CircularProgressIndicator()) : ListView(children: [
      if (rows!.isEmpty) const ListTile(title: Text('No connectors yet'), subtitle: Text('Post Jira, GitHub, GitLab, Alertmanager, Grafana, ServiceNow or Jenkins events into this chat.')),
      for (final r in rows!) ListTile(leading: const Icon(Icons.extension), title: Text('${r['name']} · ${kinds[r['kind']] ?? r['kind']}'),
        subtitle: Text('${r['uses']} messages posted${r['last_used'] != null ? ' · last ${DateTime.fromMillisecondsSinceEpoch((r['last_used'] as int) * 1000).toLocal().toString().substring(0, 16)}' : ''}'),
        trailing: IconButton(tooltip: 'Remove (the URL stops working)', icon: const Icon(Icons.delete_outline), onPressed: () async { await context.read<ApiService>().deletePath('/v1/connectors/${r['id']}'); _load(); })),
    ]));
}
