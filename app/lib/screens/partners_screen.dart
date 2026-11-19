import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

/// Administrators: partner organisations (docs/PARTNERS.md).
class PartnersScreen extends StatefulWidget {
  const PartnersScreen({super.key});
  @override State<PartnersScreen> createState() => _S();
}
class _S extends State<PartnersScreen> {
  List<dynamic>? ps; String? err;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { try { final x = await api.adminPartners(); if (mounted) setState(() => ps = x); } catch (e) { if (mounted) setState(() => err = '$e'); } }
  Future<void> _add() async {
    final s = TextEditingController(), n = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Add a partner organisation'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: s, decoration: const InputDecoration(labelText: 'Their server name (e.g. vendor.example.com)')),
      TextField(controller: n, decoration: const InputDecoration(labelText: 'Note (e.g. Ciena)'))]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Approve on our side')))]));
    if (ok != true) return;
    try {
      final r = await api.addPartner(s.text.trim().toLowerCase(), n.text.trim());
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Approved on our side'), content: SelectableText(
          'Give this one-time code to ${r['server']}\'s administrator. Their Amer Teams server confirms with it, and the connection becomes active.\n\n${r['code']}\n\n'
          'If they run another Matrix server, confirm here once they have allowed your server.'),
        actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(L.t(context, 'Done')))]));
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
    _load();
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: Text(L.t(context, 'Partner organisations'))),
    floatingActionButton: FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add_business), label: Text(L.t(context, 'Add partner'))),
    body: ps == null ? Center(child: err != null ? Text(err!) : const CircularProgressIndicator()) : ListView(children: [
      const Padding(padding: EdgeInsets.all(12), child: Text('Only active partners can connect. Everything from any other server is refused by the chat server itself, and ordinary chats can never be reached from outside.', style: TextStyle(fontSize: 12))),
      if (ps!.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('No partners yet'))),
      for (final p in ps!) ListTile(leading: Icon(p['state'] == 'active' ? Icons.link : p['state'] == 'disconnected' ? Icons.link_off : Icons.hourglass_top, color: p['state'] == 'active' ? Colors.green : null),
        title: Text('${p['server']}'), subtitle: Text('${'${p['state']}'.replaceAll('_', ' ')}${(p['note'] ?? '') != '' ? ' · ${p['note']}' : ''}'),
        trailing: PopupMenuButton<String>(onSelected: (a) async { try { await api.partnerAction('${p['server']}', a); } catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'))); } _load(); },
          itemBuilder: (_) => [
            if (p['state'] == 'approved_by_us') const PopupMenuItem(value: 'confirmed', child: Text('They confirmed: activate')),
            if (p['state'] == 'active') const PopupMenuItem(value: 'suspend', child: Text('Suspend')),
            if (p['state'] == 'suspended') const PopupMenuItem(value: 'resume', child: Text('Resume')),
            if (p['state'] != 'disconnected') const PopupMenuItem(value: 'disconnect', child: Text('Disconnect'))])),
    ]));
}

/// Start a channel shared with an active partner organisation.
Future<void> newSharedChannel(BuildContext c) async {
  final api = c.read<ApiService>(), m = c.read<MatrixService>();
  List<dynamic> partners;
  try { partners = await api.activePartners(); } catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'))); return; }
  if (!c.mounted) return;
  if (partners.isEmpty) { ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('No partner organisation is active yet. An administrator adds them in Users → Partners.'))); return; }
  final name = TextEditingController(), people = TextEditingController(); String server = '${partners.first['server']}';
  final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('New shared channel'), content: Column(mainAxisSize: MainAxisSize.min, children: [
    TextField(controller: name, decoration: const InputDecoration(labelText: 'Channel name')),
    DropdownButtonFormField<String>(value: server, decoration: const InputDecoration(labelText: 'Partner organisation'),
      items: [for (final p in partners) DropdownMenuItem(value: '${p['server']}', child: Text('${p['server']}${(p['note'] ?? '') != '' ? ' (${p['note']})' : ''}'))], onChanged: (v) => set(() => server = v!)),
    TextField(controller: people, decoration: InputDecoration(labelText: 'Invite (comma separated)', hintText: '@name:$server')),
    const Padding(padding: EdgeInsets.only(top: 8), child: Text('End-to-end encrypted. Card numbers, IBANs and Emirates IDs are stopped on your device before they are sent.', style: TextStyle(fontSize: 12))),
  ]), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Create')))])));
  if (ok != true || name.text.trim().isEmpty) return;
  final inv = people.text.split(',').map((x) => x.trim()).where((x) => x.startsWith('@')).toList();
  try {
    final id = await m.createSharedChannel(name.text.trim(), [server], inv);
    if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: id)));
  } catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Could not create the channel: $e'))); }
}
