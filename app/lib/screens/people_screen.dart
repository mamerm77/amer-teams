import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';
import 'people_picker.dart';

/// People (Microsoft Teams' Contacts): your contacts and contact groups, everyone in the organisation, invitations
/// you sent, and your own contact card. docs/PEOPLE.md.
class PeopleScreen extends StatefulWidget { const PeopleScreen({super.key}); @override State<PeopleScreen> createState() => _S(); }
class _S extends State<PeopleScreen> {
  List<Map> contacts = [], groups = [], invites = []; String? err;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final r = await api.getMap('/v1/people/contacts'); final i = await api.listGet('/v1/people/invites');
      if (mounted) setState(() { contacts = (r['contacts'] as List).cast<Map>(); groups = (r['groups'] as List).cast<Map>(); invites = i.cast<Map>(); err = null; });
    } catch (e) { if (mounted) setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  Future<void> _addContacts() async {
    final p = await pickPeople(context, multiple: true, title: 'Add contacts'); if (p == null) return;
    for (final x in p) { try { await api.putMap('/v1/people/contacts', {'user_id': x.userId}); } catch (_) {} }
    _snack('Added ${p.length} to your contacts'); _load();
  }
  Future<void> _group([Map? g]) async {
    final name = TextEditingController(text: g?['name'] ?? '');
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text(g == null ? 'New contact group' : 'Rename or change group'),
      content: TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Group name, e.g. Optical team')),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Choose people'))]));
    if (ok != true || name.text.trim().isEmpty || !mounted) return;
    final p = await pickPeople(context, multiple: true, title: 'People in ${name.text.trim()}'); if (p == null) return;
    final members = {...((g?['members'] as List?) ?? const []).map((x) => '$x'), ...p.map((x) => x.userId)}.toList();
    await api.putMap('/v1/people/groups', {'name': name.text.trim(), 'members': members});
    if (g != null && g['name'] != name.text.trim()) await api.deletePath('/v1/people/groups/${Uri.encodeComponent('${g['name']}')}');
    _load();
  }
  Future<void> _chatWith(List<String> ids) async {
    final m = context.read<MatrixService>();
    try {
      final id = ids.length == 1 ? await m.client.startDirectChat(ids.first, enableEncryption: true) : await m.client.createGroupChat(invite: ids, enableEncryption: true, groupName: null);
      if (mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(roomId: id)));
    } catch (e) { _snack('Could not start the chat: $e'); }
  }
  Future<void> _myCard() async {
    final me = context.read<MatrixService>().userId; Map<String, dynamic> cur = {};
    try { cur = await api.getMap('/v1/people/profile/${Uri.encodeComponent(me)}'); } catch (_) {}
    if (!mounted) return;
    final f = {for (final k in ['email', 'phone', 'title', 'dept', 'office']) k: TextEditingController(text: '${cur[k] ?? ''}')};
    const labels = {'email': 'Work email', 'phone': 'Phone', 'title': 'Job title', 'dept': 'Department', 'office': 'Office / location'};
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('My contact details'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Colleagues find you by these and see them on your profile card.'),
        for (final k in f.keys) TextField(controller: f[k], decoration: InputDecoration(labelText: labels[k]))])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
    if (ok != true) return;
    try { await api.putMap('/v1/people/me', {for (final e in f.entries) e.key: e.value.text.trim().isEmpty ? null : e.value.text.trim()}); _snack('Saved'); }
    catch (e) { _snack('$e'.replaceFirst('Exception: ', '')); }
  }

  Widget _contact(Map m) => ListTile(
    leading: CircleAvatar(child: Text('${m['display_name']}'.isEmpty ? '?' : '${m['display_name']}'.characters.first.toUpperCase())),
    title: Text('${m['display_name']}'),
    subtitle: Text([if (m['title'] != null) m['title'], if (m['dept'] != null) m['dept'], if (m['email'] != null) m['email'], if (m['phone'] != null) m['phone']].join(' · ').ifEmpty('${m['user_id']}')),
    trailing: Row(mainAxisSize: MainAxisSize.min, children: [
      IconButton(tooltip: 'Chat', icon: const Icon(Icons.chat_bubble_outline), onPressed: () => _chatWith(['${m['user_id']}'])),
      PopupMenuButton<String>(tooltip: 'Contact options', onSelected: (v) async {
        if (v == 'fav') { await api.putMap('/v1/people/contacts', {'user_id': m['user_id'], 'favourite': m['favourite'] != true}); }
        if (v == 'remove') { await api.deletePath('/v1/people/contacts/${Uri.encodeComponent('${m['user_id']}')}'); }
        _load();
      }, itemBuilder: (_) => [PopupMenuItem(value: 'fav', child: Text(m['favourite'] == true ? 'Remove from favourites' : 'Add to favourites')), const PopupMenuItem(value: 'remove', child: Text('Remove contact'))]),
    ]));

  @override Widget build(BuildContext c) {
    final names = {for (final x in contacts) '${x['user_id']}': '${x['display_name']}'};
    return DefaultTabController(length: 3, child: Scaffold(
      appBar: AppBar(title: const Text('People'), actions: [TextButton.icon(icon: const Icon(Icons.badge_outlined), label: const Text('My contact details'), onPressed: _myCard)],
        bottom: TabBar(tabs: [Tab(text: 'Contacts (${contacts.length})'), Tab(text: 'Groups (${groups.length})'), Tab(text: 'Invitations (${invites.length})')])),
      body: err != null ? Center(child: Text(err!)) : TabBarView(children: [
        RefreshIndicator(onRefresh: _load, child: ListView(children: [
          Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, runSpacing: 8, children: [
            FilledButton.icon(icon: const Icon(Icons.person_add), label: const Text('Add contacts'), onPressed: _addContacts),
            OutlinedButton.icon(icon: const Icon(Icons.mail_outline), label: const Text('Invite someone new'), onPressed: () async { await invitePerson(c); _load(); }),
          ])),
          if (contacts.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No contacts yet. Add colleagues you work with often: search by name, email, phone, job title or department.')),
          for (final m in contacts) _contact(m),
        ])),
        ListView(children: [
          Padding(padding: const EdgeInsets.all(12), child: Align(alignment: Alignment.centerLeft, child: FilledButton.icon(icon: const Icon(Icons.group_add), label: const Text('New contact group'), onPressed: () => _group()))),
          if (groups.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Groups let you add several people at once: to a chat, a team, a call or a meeting.')),
          for (final g in groups) Card(child: ExpansionTile(leading: const Icon(Icons.groups), title: Text('${g['name']}'), subtitle: Text('${(g['members'] as List).length} people'),
            children: [
              for (final u in (g['members'] as List)) ListTile(dense: true, title: Text(names['$u'] ?? '$u'), subtitle: Text('$u')),
              OverflowBar(children: [
                TextButton.icon(icon: const Icon(Icons.chat), label: const Text('Group chat'), onPressed: () => _chatWith((g['members'] as List).map((x) => '$x').toList())),
                TextButton.icon(icon: const Icon(Icons.edit), label: const Text('Edit'), onPressed: () => _group(g)),
                TextButton.icon(icon: const Icon(Icons.delete_outline), label: const Text('Delete'), onPressed: () async { await api.deletePath('/v1/people/groups/${Uri.encodeComponent('${g['name']}')}'); _load(); }),
              ]),
            ])),
        ]),
        RefreshIndicator(onRefresh: _load, child: ListView(children: [
          if (invites.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Invite people who are not on Amer Teams yet: they get a one-time link to create an account.')),
          for (final i in invites) ListTile(
            leading: Icon(i['status'] == 'joined' ? Icons.how_to_reg : i['status'] == 'expired' ? Icons.timer_off_outlined : Icons.hourglass_top, color: i['status'] == 'joined' ? Colors.green : null),
            title: Text('${i['name']}'), subtitle: Text('${i['email'] ?? i['phone']} · ${i['status'] == 'joined' ? 'joined as ${i['user_id']}${i['added'] == true ? ', added to your teams and chats' : ''}' : i['status']}'),
            trailing: i['status'] == 'pending' ? TextButton(onPressed: () async { await api.deletePath('/v1/people/invites/${i['id']}'); _load(); }, child: const Text('Cancel')) : null),
        ])),
      ])));
  }
}

extension on String { String ifEmpty(String other) => isEmpty ? other : this; }

/// Runs on every app start and every few minutes: people you invited who have now created their account are added
/// to the teams (with their channels) and chats you chose, by your own app (so invitations stay end-to-end encrypted).
Future<int> addJoinedInvitees(MatrixService m, ApiService api) async {
  var n = 0;
  try {
    for (final i in (await api.listGet('/v1/people/invites')).cast<Map>().where((i) => i['status'] == 'joined' && i['added'] != true)) {
      final uid = '${i['user_id']}';
      for (final rid in (i['rooms'] as List).map((x) => '$x')) {
        final r = m.client.getRoomById(rid); if (r == null) continue;
        try { if (r.isSpace) { await m.addTeamMembers(r, [uid]); } else { await r.invite(uid); } } catch (_) {}
      }
      await api.postMap('/v1/people/invites/${i['id']}/added', {}); n++;
    }
  } catch (_) {}
  return n;
}
