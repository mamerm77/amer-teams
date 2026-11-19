import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Guest accounts and the data-residency report (docs/GUEST_ACCOUNTS.md, docs/DATA_RESIDENCY.md).
class GuestAccountsScreen extends StatefulWidget {
  const GuestAccountsScreen({super.key});
  @override State<GuestAccountsScreen> createState() => _S();
}
class _S extends State<GuestAccountsScreen> {
  List<dynamic>? guests; Map<String, dynamic>? res; String? err;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final api = context.read<ApiService>();
    try { final g = await api.guestAccounts(); final r = await api.getMap('/v1/admin/residency'); if (mounted) setState(() { guests = g; res = r; }); }
    catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Future<void> _new() async {
    final u = TextEditingController(), n = TextEditingController(), e = TextEditingController(); var days = 30;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('New guest account'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Name')),
        TextField(controller: e, decoration: const InputDecoration(labelText: 'Work email')),
        TextField(controller: u, decoration: const InputDecoration(labelText: 'Username (becomes guest.username)')),
        DropdownButtonFormField<int>(value: days, decoration: const InputDecoration(labelText: 'Expires after'), items: const [7, 30, 90, 180].map((x) => DropdownMenuItem(value: x, child: Text('$x days'))).toList(), onChanged: (v) => set(() => days = v!)),
        const SizedBox(height: 8), const Text('Guests cannot create chats, invite people or join anything they were not invited to. Enforced by the server.', style: TextStyle(fontSize: 12)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create'))])));
    if (ok != true || !mounted) return;
    try {
      final r = await context.read<ApiService>().postMap('/v1/admin/guest-accounts', {'username': u.text, 'display_name': n.text, 'email': e.text, 'days': days});
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Guest account created'), content: SelectableText('${r['user_id']}\nOne-time password: ${r['password']}\n\n${r['note']}'),
        actions: [TextButton(onPressed: () { Clipboard.setData(ClipboardData(text: '${r['user_id']}  ${r['password']}')); Navigator.pop(d); }, child: const Text('Copy and close'))]));
      _load();
    } catch (x) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$x'))); }
  }
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Guests and data residency')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.person_add), label: const Text('Guest account')),
    body: err != null ? Center(child: Text(err!)) : guests == null ? const Center(child: CircularProgressIndicator()) : ListView(children: [
      const ListTile(title: Text('Guest accounts')),
      if (guests!.isEmpty) const ListTile(dense: true, title: Text('None')),
      for (final g in guests!) ListTile(leading: Icon(g['deactivated_at'] != null ? Icons.person_off : Icons.person_outline), title: Text('${g['user_id']}'),
        subtitle: Text('${g['email_domain']} · sponsor ${g['sponsor']} · ${g['deactivated_at'] != null ? 'ended' : 'expires ${DateTime.fromMillisecondsSinceEpoch((g['expires_at'] as int) * 1000).toString().substring(0, 10)}'}'),
        trailing: g['deactivated_at'] != null ? null : TextButton(onPressed: () async { await context.read<ApiService>().postMap('/v1/admin/guest-accounts/${Uri.encodeComponent(g['user_id'])}/end', {}); _load(); }, child: const Text('End now'))),
      const Divider(),
      ListTile(title: Text('Data residency (required: ${res?['required_region']})'), subtitle: Text(res?['all_in_region'] == true ? 'Everything the server can read is declared in region' : 'Some items are outside the region or not declared')),
      for (final i in (res?['items'] as List? ?? [])) ListTile(dense: true,
        leading: Icon(i['status'] == 'in region' ? Icons.check_circle : i['status'] == 'check' ? Icons.help_outline : Icons.warning_amber, color: i['status'] == 'in region' ? Colors.green : Colors.orange),
        title: Text('${i['data']}'), subtitle: Text('${i['stored'] == '' ? 'not declared' : i['stored']} · ${i['readable_by_server'] ? 'server can read' : 'server cannot read'}${i['note'] != null ? '\n${i['note']}' : ''}')),
    ]));
}
