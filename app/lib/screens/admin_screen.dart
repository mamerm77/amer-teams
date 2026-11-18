import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import 'call_trace_screen.dart';

/// User administration for server admins: invite codes and accounts.
class AdminScreen extends StatefulWidget { const AdminScreen({super.key}); @override State<AdminScreen> createState() => _S(); }
class _S extends State<AdminScreen> {
  List users = [], invites = []; String? err;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final r = await Future.wait([api.users(), api.invites()]); setState(() { users = r[0]; invites = r[1]; err = null; }); }
    catch (e) { setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  void _msg(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _invite() async {
    final r = await api.createInvite(uses: 1, days: 7);
    final code = r['token'] as String;
    await Clipboard.setData(ClipboardData(text: code));
    if (!mounted) return;
    await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Invite code created'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 22)),
        const SizedBox(height: 8), const Text('Copied. Valid for one sign-up within 7 days.')]),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Done'))]));
    _load();
  }

  Future<void> _newUser() async {
    final u = TextEditingController(), n = TextEditingController(), p = TextEditingController(); var adm = false;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Create user'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: u, decoration: const InputDecoration(labelText: 'Username')),
        TextField(controller: n, decoration: const InputDecoration(labelText: 'Display name')),
        TextField(controller: p, decoration: const InputDecoration(labelText: 'Temporary password')),
        CheckboxListTile(value: adm, onChanged: (v) => set(() => adm = v!), title: const Text('Administrator'), contentPadding: EdgeInsets.zero)]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create'))])));
    if (ok != true) return;
    try { final r = await api.createUser(u.text.trim(), p.text, name: n.text.trim(), admin: adm); _msg('Created ${r['user_id']}'); _load(); }
    catch (e) { _msg('$e'.replaceFirst('Exception: ', '')); }
  }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Users'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
    body: err != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(err!)))
      : ListView(padding: const EdgeInsets.all(12), children: [
        Wrap(spacing: 8, children: [
          FilledButton.icon(onPressed: _invite, icon: const Icon(Icons.vpn_key), label: const Text('New invite code')),
          OutlinedButton.icon(onPressed: _newUser, icon: const Icon(Icons.person_add), label: const Text('Create user')),
          OutlinedButton.icon(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const CallTraceScreen())), icon: const Icon(Icons.timeline), label: const Text('Call trace'))]),
        const SizedBox(height: 16), Text('Accounts (${users.length})', style: Theme.of(c).textTheme.titleMedium),
        for (final u in users) ListTile(
          leading: Icon(u['deactivated'] ? Icons.person_off : u['admin'] ? Icons.admin_panel_settings : Icons.person),
          title: Text(u['display_name'] ?? u['user_id']), subtitle: Text('${u['user_id']}${u['deactivated'] ? ' · deactivated' : ''}'),
          trailing: u['deactivated'] ? null : PopupMenuButton<String>(onSelected: (a) async {
            if (a == 'deact') { await api.deactivate(u['user_id']); _msg('Deactivated'); }
            if (a == 'reset') { final t = TextEditingController();
              final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('New password'), content: TextField(controller: t),
                actions: [FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Reset'))]));
              if (ok == true) { await api.resetPassword(u['user_id'], t.text); _msg('Password reset; user signed out everywhere'); } }
            _load();
          }, itemBuilder: (_) => const [PopupMenuItem(value: 'reset', child: Text('Reset password')), PopupMenuItem(value: 'deact', child: Text('Deactivate'))])),
        const SizedBox(height: 16), Text('Invite codes', style: Theme.of(c).textTheme.titleMedium),
        for (final i in invites) ListTile(dense: true, leading: const Icon(Icons.vpn_key_outlined),
          title: Text(i['token'], style: const TextStyle(fontFamily: 'monospace')),
          subtitle: Text('used ${i['completed']}/${i['uses_allowed'] ?? '∞'}')),
      ]));
}
