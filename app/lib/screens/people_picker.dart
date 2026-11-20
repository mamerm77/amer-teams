import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';

/// Choose people, as in Microsoft Teams' "Add people" box (docs/PEOPLE.md):
/// - search everyone on this server by name, username, email, phone, job title or department;
/// - your contacts (favourites first) and contact groups are shown before you type; a group adds all its members;
/// - nobody found and you typed an email or phone number: invite them to create an account. [inviteRooms] are the
///   teams or chats they will be added to once they join.
Future<List<Profile>?> pickPeople(BuildContext context, {bool multiple = false, String title = 'Choose people', List<String> inviteRooms = const []}) =>
    Navigator.push<List<Profile>>(context, MaterialPageRoute(builder: (_) => _Picker(multiple: multiple, title: title, inviteRooms: inviteRooms)));

class _Picker extends StatefulWidget {
  const _Picker({required this.multiple, required this.title, required this.inviteRooms});
  final bool multiple; final String title; final List<String> inviteRooms;
  @override State<_Picker> createState() => _S();
}
class _S extends State<_Picker> {
  final q = TextEditingController(); List<Map> results = []; final chosen = <String, Profile>{}; Timer? debounce; bool busy = false, canInvite = false;
  List<Map> contacts = []; List<Map> groups = [];
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _loadContacts(); _search(''); }

  Future<void> _loadContacts() async {
    try { final r = await api.getMap('/v1/people/contacts'); if (mounted) setState(() { contacts = (r['contacts'] as List).cast<Map>(); groups = (r['groups'] as List).cast<Map>(); }); } catch (_) {}
  }
  Future<void> _search(String t) async {
    setState(() => busy = true);
    try {
      final r = await api.getMap('/v1/people/search?q=${Uri.encodeQueryComponent(t)}');
      if (mounted) setState(() { results = (r['results'] as List).cast<Map>(); canInvite = r['can_invite'] == true; });
    } catch (_) {                                            // older server: the Matrix user directory (names only)
      try {
        final c = context.read<MatrixService>().client;
        final r = await c.searchUserDirectory(t.isEmpty ? (c.userID!.split(':').last) : t, limit: 30);
        if (mounted) setState(() => results = [for (final p in r.results.where((p) => p.userId != c.userID)) {'user_id': p.userId, 'display_name': p.displayName ?? p.userId}]);
      } catch (_) { if (mounted) setState(() => results = []); }
    } finally { if (mounted) setState(() => busy = false); }
  }

  Profile _p(Map m) => Profile(userId: '${m['user_id']}', displayName: '${m['display_name'] ?? m['user_id']}');
  void _toggle(Map m) {
    final p = _p(m);
    if (!widget.multiple) { Navigator.pop(context, [p]); return; }
    setState(() => chosen.containsKey(p.userId) ? chosen.remove(p.userId) : chosen[p.userId] = p);
  }
  void _addGroup(Map g) {
    final members = (g['members'] as List).map((x) => '$x').toList();
    final names = {for (final c in contacts) '${c['user_id']}': '${c['display_name']}'};
    setState(() { for (final m in members) { chosen[m] = Profile(userId: m, displayName: names[m] ?? m); } });
    if (!widget.multiple) Navigator.pop(context, chosen.values.toList());
  }

  String _sub(Map m) => [if (m['title'] != null) m['title'], if (m['dept'] != null) m['dept'], m['email'] ?? m['user_id']].join(' · ');

  Widget _person(Map m, {bool star = false}) {
    final id = '${m['user_id']}'; final name = '${m['display_name'] ?? id}';
    return ListTile(
      leading: CircleAvatar(child: Text(name.replaceAll('@', '').isEmpty ? '?' : name.replaceAll('@', '').characters.first.toUpperCase())),
      title: Row(children: [Flexible(child: Text(name, overflow: TextOverflow.ellipsis)), if (star) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.star, size: 14, color: Colors.amber))]),
      subtitle: Text(_sub(m), maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: widget.multiple ? Checkbox(value: chosen.containsKey(id), onChanged: (_) => _toggle(m)) : null,
      onTap: () => _toggle(m));
  }

  @override Widget build(BuildContext c) {
    final typing = q.text.trim().isNotEmpty;
    return Scaffold(
      appBar: AppBar(title: Text(widget.title), actions: [
        if (widget.multiple) Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(c, chosen.values.toList()), child: Text('Add (${chosen.length})')))]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(12), child: TextField(controller: q, autofocus: true,
          decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Name, email, phone, job title or department', border: OutlineInputBorder()),
          onChanged: (t) { setState(() {}); debounce?.cancel(); debounce = Timer(const Duration(milliseconds: 250), () => _search(t)); })),
        if (chosen.isNotEmpty) SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12), children: [
          for (final p in chosen.values) Padding(padding: const EdgeInsets.only(right: 6), child: InputChip(label: Text(p.displayName ?? p.userId), onDeleted: () => setState(() => chosen.remove(p.userId))))])),
        if (busy) const LinearProgressIndicator(),
        Expanded(child: ListView(children: [
          if (!typing && groups.isNotEmpty) ...[
            const _Head('Contact groups'),
            for (final g in groups) ListTile(leading: const CircleAvatar(child: Icon(Icons.groups)), title: Text('${g['name']}'), subtitle: Text('${(g['members'] as List).length} people'),
              trailing: TextButton(onPressed: () => _addGroup(g), child: const Text('Add all')), onTap: () => _addGroup(g)),
          ],
          if (!typing && contacts.isNotEmpty) ...[const _Head('Your contacts'), for (final m in contacts) _person(m, star: m['favourite'] == true)],
          if (results.isNotEmpty) ...[_Head(typing ? 'People' : 'Everyone in your organisation'),
            for (final m in results.where((m) => typing || !contacts.any((x) => x['user_id'] == m['user_id']))) _person(m)],
          if (typing && results.isEmpty && !busy) Padding(padding: const EdgeInsets.all(24), child: Column(children: [
            Text('Nobody here matches “${q.text.trim()}”.'),
            const SizedBox(height: 8),
            if (canInvite) FilledButton.icon(icon: const Icon(Icons.person_add_alt_1), label: Text('Invite ${q.text.trim()} to Amer Teams'),
              onPressed: () => invitePerson(c, contact: q.text.trim(), rooms: widget.inviteRooms))
            else const Text('To invite someone new, type their email address or phone number.', textAlign: TextAlign.center),
          ])),
        ])),
      ]));
  }
}

class _Head extends StatelessWidget {
  const _Head(this.t); final String t;
  @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(t, style: Theme.of(c).textTheme.titleSmall?.copyWith(color: Theme.of(c).colorScheme.primary)));
}

/// Invite someone without an account (email or phone): creates a one-time sign-up link, emailed when the server has
/// email set up, and always shown here to copy or share. When they join, your app adds them to [rooms].
Future<void> invitePerson(BuildContext c, {String contact = '', List<String> rooms = const []}) async {
  final isMail = contact.contains('@');
  final name = TextEditingController(), mail = TextEditingController(text: isMail ? contact : ''), phone = TextEditingController(text: isMail ? '' : contact);
  final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: const Text('Invite to Amer Teams'),
    content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Their name')),
      TextField(controller: mail, keyboardType: TextInputType.emailAddress, decoration: const InputDecoration(labelText: 'Email')),
      TextField(controller: phone, keyboardType: TextInputType.phone, decoration: const InputDecoration(labelText: 'or phone, e.g. +971 50 123 4567')),
      if (rooms.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 10), child: Text('They will be added to ${rooms.length == 1 ? 'this team or chat' : '${rooms.length} teams or chats'} when they join.', style: Theme.of(d).textTheme.bodySmall)),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create invitation'))]));
  if (ok != true || name.text.trim().isEmpty || !c.mounted) return;
  Map<String, dynamic> r;
  try { r = await c.read<ApiService>().postMap('/v1/people/invite', {'name': name.text.trim(), if (mail.text.trim().isNotEmpty) 'email': mail.text.trim(), if (phone.text.trim().isNotEmpty) 'phone': phone.text.trim(), 'rooms': rooms}); }
  catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); return; }
  if (!c.mounted) return;
  await showDialog(context: c, builder: (d) => AlertDialog(title: Text(r['emailed'] == true ? 'Invitation emailed' : 'Invitation ready to share'),
    content: SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(r['emailed'] == true ? 'We emailed ${mail.text.trim()}. You can also send this message yourself:' : 'Send this message by email, WhatsApp or SMS. The link works once, for ${r['expires_in_days']} days.'),
      const SizedBox(height: 10),
      Container(padding: const EdgeInsets.all(10), decoration: BoxDecoration(border: Border.all(color: Theme.of(d).colorScheme.outlineVariant), borderRadius: BorderRadius.circular(8)),
        child: SelectableText('${r['message']}')),
      const SizedBox(height: 8),
      Text('When they create their account they appear in your contacts${rooms.isEmpty ? '' : ' and are added automatically'}. See People → Invitations.', style: Theme.of(d).textTheme.bodySmall),
    ])),
    actions: [TextButton(onPressed: () { Clipboard.setData(ClipboardData(text: '${r['message']}')); ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Copied'))); }, child: const Text('Copy message')),
      FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Done'))]));
}
