import 'teams_apps.dart';
import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
import 'people_picker.dart';

String _initials(String n) { final p = n.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList(); return p.isEmpty ? '?' : (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase(); }
int _unread(MatrixService m, Room t) => m.channelsOf(t).fold(0, (a, r) => a + r.notificationCount);

/// Teams, as in Microsoft Teams: teams with channels; each channel has Posts (threaded) and Files.
class TeamsScreen extends StatelessWidget {
  const TeamsScreen({super.key});
  @override
  Widget build(BuildContext c) {
    final m = c.watch<MatrixService>(); final cs = Theme.of(c).colorScheme;
    final invites = m.client.rooms.where((r) => r.isSpace && r.membership == Membership.invite).toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Teams'), actions: [
        TextButton.icon(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const _Discover())), icon: const Icon(Icons.travel_explore), label: const Text('Discover teams'))]),
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.group_add), label: const Text('New team'), onPressed: () => _newTeam(c, m)),
      body: m.teams.isEmpty && invites.isEmpty
        ? Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.groups_2_outlined, size: 56, color: cs.primary), const SizedBox(height: 12),
            Text('No teams yet', style: Theme.of(c).textTheme.titleMedium), const SizedBox(height: 6),
            const Text('A team brings people together with encrypted channels for posts, files and meetings.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: [FilledButton.icon(onPressed: () => _newTeam(c, m), icon: const Icon(Icons.group_add), label: const Text('Create a team')),
              OutlinedButton.icon(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const _Discover())), icon: const Icon(Icons.travel_explore), label: const Text('Join a public team'))])])))
        : ListView(padding: const EdgeInsets.all(8), children: [
            for (final t in invites) Card(child: ListTile(leading: const CircleAvatar(child: Icon(Icons.mail_outline)), title: Text(t.getLocalizedDisplayname()),
              subtitle: const Text('You are invited to this team'),
              trailing: Wrap(spacing: 6, children: [TextButton(onPressed: () => t.leave(), child: const Text('Decline')),
                FilledButton(onPressed: () => m.joinTeam(t.id), child: const Text('Join'))]))),
            for (final t in m.teams) Card(child: ListTile(
              onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => TeamScreen(teamId: t.id))),
              leading: CircleAvatar(backgroundColor: cs.primaryContainer, child: Text(_initials(t.getLocalizedDisplayname()), style: TextStyle(color: cs.onPrimaryContainer))),
              title: Text(t.getLocalizedDisplayname(), style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([if (t.topic.isNotEmpty) t.topic, '${m.channelsOf(t).length} channels · ${t.summary.mJoinedMemberCount ?? 0} members',
                if (t.joinRules == JoinRules.public) 'Public'].join(' · '), maxLines: 2, overflow: TextOverflow.ellipsis),
              trailing: _unread(m, t) > 0 ? Badge(label: Text('${_unread(m, t)}')) : const Icon(Icons.chevron_right))),
          ]),
    );
  }

  static Future<void> _newTeam(BuildContext c, MatrixService m) async {
    final name = TextEditingController(), desc = TextEditingController(); var public = false; var people = <String>[];
    final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('New team'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Team name')),
        TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description (optional)')),
        const SizedBox(height: 8),
        SegmentedButton<bool>(segments: const [ButtonSegment(value: false, icon: Icon(Icons.lock), label: Text('Private')), ButtonSegment(value: true, icon: Icon(Icons.public), label: Text('Public'))],
          selected: {public}, onSelectionChanged: (v) => set(() => public = v.first)),
        Padding(padding: const EdgeInsets.only(top: 6), child: Text(public ? 'Anyone on this server can find and join it.' : 'Only people you add can join.', style: Theme.of(d).textTheme.bodySmall)),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.person_add), title: Text(people.isEmpty ? 'Add members' : '${people.length} member(s) to invite'),
          onTap: () async { final p = await pickPeople(d, multiple: true, title: 'Add members'); if (p != null) set(() => people = p.map((x) => x.userId).toList()); }),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create'))])));
    if (ok != true || name.text.trim().isEmpty) return;
    final id = await m.createTeam(name.text.trim(), people, description: desc.text.trim(), public: public);
    if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => TeamScreen(teamId: id)));
  }
}

class _Discover extends StatefulWidget { const _Discover(); @override State<_Discover> createState() => _DS(); }
class _DS extends State<_Discover> {
  final q = TextEditingController(); Future<List<PublishedRoomsChunk>>? f;
  @override void initState() { super.initState(); f = context.read<MatrixService>().discoverTeams(); }
  @override Widget build(BuildContext c) {
    final m = c.read<MatrixService>();
    return Scaffold(appBar: AppBar(title: TextField(controller: q, decoration: const InputDecoration(hintText: 'Search public teams', border: InputBorder.none),
        onSubmitted: (v) => setState(() => f = m.discoverTeams(search: v)))),
      body: FutureBuilder<List<PublishedRoomsChunk>>(future: f, builder: (_, s) {
        if (s.hasError) return Center(child: Text('Could not load teams: ${s.error}'));
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        if (s.data!.isEmpty) return const Center(child: Text('No public teams to join'));
        return ListView(children: [for (final t in s.data!) ListTile(
          leading: CircleAvatar(child: Text(_initials(t.name ?? '?'))), title: Text(t.name ?? t.roomId),
          subtitle: Text('${t.topic ?? ''}${(t.topic ?? '').isEmpty ? '' : ' · '}${t.numJoinedMembers} members', maxLines: 2),
          trailing: FilledButton(child: Text(L.t(context, 'Join')), onPressed: () async {
            await m.joinTeam(t.roomId);
            if (c.mounted) Navigator.pushReplacement(c, MaterialPageRoute(builder: (_) => TeamScreen(teamId: t.roomId)));
          }))]);
      }));
  }
}

/// Apps that can be added to a channel as tabs, as in Teams (docs/TEAMS_APPS.md).
final kChannelTabs = <String, Widget Function(Room)>{
  'Planner': (r) => PlannerApp(room: r), 'Lists': (r) => ListsApp(room: r), 'Notes': (r) => NotesApp(room: r), 'Forms': (r) => FormsApp(room: r),
  'Milestones': (r) => MilestonesApp(room: r), 'Goals': (r) => GoalsApp(room: r), 'Updates': (r) => UpdatesApp(room: r), 'Praise': (r) => PraiseApp(room: r),
};

/// One team: channels, members, meet, leave.
class TeamScreen extends StatelessWidget {
  const TeamScreen({super.key, required this.teamId}); final String teamId;
  @override Widget build(BuildContext c) {
    final m = c.watch<MatrixService>(); final t = m.client.getRoomById(teamId); final cs = Theme.of(c).colorScheme;
    if (t == null || t.membership != Membership.join) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final channels = m.channelsOf(t)..sort((a, b) => a.getLocalizedDisplayname() == 'General' ? -1 : b.getLocalizedDisplayname() == 'General' ? 1 : a.getLocalizedDisplayname().compareTo(b.getLocalizedDisplayname()));
    final members = t.getParticipants().where((u) => u.membership == Membership.join).toList();
    final canManage = t.canInvite;
    return Scaffold(
      appBar: AppBar(title: Text(t.getLocalizedDisplayname()), actions: [
        PopupMenuButton<String>(onSelected: (v) async {
          if (v == 'leave') {
            final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text('Leave ${t.getLocalizedDisplayname()}?'), content: const Text('You will leave the team and all of its channels.'),
              actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Leave'))]));
            if (ok == true) { await m.leaveTeam(t); if (c.mounted) Navigator.pop(c); }
          }
        }, itemBuilder: (_) => const [PopupMenuItem(value: 'leave', child: ListTile(leading: Icon(Icons.logout), title: Text('Leave team')))])]),
      body: ListView(padding: const EdgeInsets.all(12), children: [
        if (t.topic.isNotEmpty) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text(t.topic)),
        Wrap(spacing: 8, runSpacing: 8, children: [
          FilledButton.icon(icon: const Icon(Icons.video_call), label: const Text('Meet now'), onPressed: channels.isEmpty ? null :
            () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: channels.first.id, meeting: true)))),
          if (canManage) OutlinedButton.icon(icon: const Icon(Icons.person_add), label: const Text('Add members'), onPressed: () async {
            final p = await pickPeople(c, multiple: true, title: 'Add members to ${t.getLocalizedDisplayname()}');
            if (p != null && p.isNotEmpty) { await m.addTeamMembers(t, p.map((x) => x.userId).toList());
              if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Invited ${p.length} to the team and its channels'))); }
          }),
          if (canManage) OutlinedButton.icon(icon: const Icon(Icons.add), label: const Text('Add channel'), onPressed: () async {
            final n = TextEditingController(), d = TextEditingController(); var private = false;
            final ok = await showDialog<bool>(context: c, builder: (x) => StatefulBuilder(builder: (x, set) => AlertDialog(title: const Text('New channel'), content: Column(mainAxisSize: MainAxisSize.min, children: [
              TextField(controller: n, autofocus: true, decoration: const InputDecoration(labelText: 'Channel name')),
              TextField(controller: d, decoration: const InputDecoration(labelText: 'Description (optional)')),
              const SizedBox(height: 8),
              SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('Standard'), icon: Icon(Icons.tag)), ButtonSegment(value: true, label: Text('Private'), icon: Icon(Icons.lock))],
                selected: {private}, onSelectionChanged: (v) => set(() => private = v.first)),
              Padding(padding: const EdgeInsets.only(top: 6), child: Text(private ? 'Only the people you choose can see it.' : 'Everyone in the team can see it.', style: Theme.of(x).textTheme.bodySmall)),
            ]),
              actions: [TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(x, true), child: const Text('Create'))])));
            if (ok != true || n.text.trim().isEmpty || !c.mounted) return;
            List<String>? who;
            if (private) { final p = await pickPeople(c, multiple: true, title: 'Who can see ${n.text.trim()}?'); if (p == null) return; who = p.map((x) => x.userId).toList(); }
            await m.createChannel(t.id, n.text.trim(), description: d.text.trim(), members: who);
          }),
        ]),
        const SizedBox(height: 12),
        Text('Channels', style: Theme.of(c).textTheme.titleSmall),
        for (final ch in [...channels.where((x) => m.isFavourite(x) && !m.isHidden(x)), ...channels.where((x) => !m.isFavourite(x) && !m.isHidden(x))]) Card(child: ListTile(
          leading: Icon(m.channelSettings(ch)['private'] == true ? Icons.lock : Icons.tag, color: cs.primary),
          title: Text(ch.getLocalizedDisplayname(), style: TextStyle(fontWeight: ch.notificationCount > 0 ? FontWeight.w700 : null)),
          subtitle: ch.topic.isEmpty ? null : Text(ch.topic, maxLines: 1, overflow: TextOverflow.ellipsis),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (m.isFavourite(ch)) const Icon(Icons.star, size: 16, color: Colors.amber),
            if (m.channelSettings(ch)['moderated'] == true) const Tooltip(message: 'Moderated: only moderators start posts', child: Icon(Icons.shield_outlined, size: 16)),
            if (ch.notificationCount > 0) Badge(label: Text('${ch.notificationCount}')),
            PopupMenuButton<String>(tooltip: 'Channel options', onSelected: (v) async {
              if (v == 'fav') await m.toggleChannelPref(ch, 'favourite');
              if (v == 'hide') await m.toggleChannelPref(ch, 'hidden');
              if (v == 'mod') await m.setChannelSettings(ch, {'moderated': m.channelSettings(ch)['moderated'] != true});
              if (v == 'members' && c.mounted) { final p = await pickPeople(c, multiple: true, title: 'Add people to ${ch.getLocalizedDisplayname()}'); for (final u in p ?? const []) { try { await ch.invite(u.userId); } catch (_) {} } }
            }, itemBuilder: (_) => [
              PopupMenuItem(value: 'fav', child: Text(m.isFavourite(ch) ? 'Remove from favourites' : 'Add to favourites')),
              const PopupMenuItem(value: 'hide', child: Text('Hide')),
              if (ch.getPowerLevelByUserId(m.userId).level >= 50) PopupMenuItem(value: 'mod', child: Text(m.channelSettings(ch)['moderated'] == true ? 'Turn off moderation' : 'Moderate: only moderators start posts')),
              if (m.channelSettings(ch)['private'] == true && ch.canInvite) const PopupMenuItem(value: 'members', child: Text('Add people to this private channel')),
            ])]),
          onTap: () async {
            if (ch.membership != Membership.join) { try { await ch.join(); } catch (_) {} }
            if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => ChannelScreen(roomId: ch.id, teamName: t.getLocalizedDisplayname())));
          })),
        if (channels.any(m.isHidden)) ExpansionTile(leading: const Icon(Icons.visibility_off_outlined), title: Text('Hidden channels (${channels.where(m.isHidden).length})'), children: [
          for (final ch in channels.where(m.isHidden)) ListTile(dense: true, leading: const Icon(Icons.tag), title: Text(ch.getLocalizedDisplayname()), trailing: TextButton(onPressed: () => m.toggleChannelPref(ch, 'hidden'), child: const Text('Show')))]),
        for (final cid in t.spaceChildren.map((x) => x.roomId).whereType<String>().where((id) => m.client.getRoomById(id) == null))
          Card(child: ListTile(leading: const Icon(Icons.tag), title: const Text('Channel you have not joined'), subtitle: const Text('Private channels need an invitation'), trailing: TextButton(child: const Text('Join'), onPressed: () async {
            try { await m.client.joinRoom(cid); } catch (_) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('This is a private channel. Ask its owner to add you.'))); } }))),
        const SizedBox(height: 12),
        Text('Members (${members.length})', style: Theme.of(c).textTheme.titleSmall),
        for (final u in members) ListTile(dense: true, leading: CircleAvatar(radius: 16, child: Text(_initials(u.calcDisplayname()), style: const TextStyle(fontSize: 12))),
          title: Text(u.calcDisplayname()), subtitle: Text(u.id),
          trailing: t.getPowerLevelByUserId(u.id).level >= 100 ? const Chip(label: Text('Owner')) : t.getPowerLevelByUserId(u.id).level >= 50 ? const Chip(label: Text('Admin')) : null),
      ]));
  }
}

/// A channel: Posts (each post with its own thread of replies) and Files, as in Microsoft Teams.
class ChannelScreen extends StatefulWidget {
  const ChannelScreen({super.key, required this.roomId, required this.teamName}); final String roomId, teamName;
  @override State<ChannelScreen> createState() => _CS();
}
class _CS extends State<ChannelScreen> {
  Timeline? tl; final post = TextEditingController();
  Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  @override void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) async { tl = await room.getTimeline(onUpdate: () { if (mounted) setState(() {}); }); if (mounted) setState(() {}); }); }
  @override void dispose() { tl?.cancelSubscriptions(); super.dispose(); }

  Future<void> _schedule(BuildContext c) async {
    final title = TextEditingController(); var start = DateTime.now().add(Duration(minutes: 60 - DateTime.now().minute)); var minutes = 30;
    final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Channel meeting'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Title')),
        const SizedBox(height: 8),
        OutlinedButton.icon(icon: const Icon(Icons.event), label: Text(DateFormat('EEE d MMM, HH:mm').format(start)), onPressed: () async {
          final dd = await showDatePicker(context: d, initialDate: start, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
          if (dd == null || !d.mounted) return; final tt = await showTimePicker(context: d, initialTime: TimeOfDay.fromDateTime(start));
          if (tt != null) set(() => start = DateTime(dd.year, dd.month, dd.day, tt.hour, tt.minute)); }),
        DropdownButton<int>(value: minutes, items: [for (final n in const [15, 30, 45, 60, 90]) DropdownMenuItem(value: n, child: Text('$n min'))], onChanged: (v) => set(() => minutes = v ?? 30)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Schedule'))])));
    if (ok != true || title.text.trim().isEmpty || !c.mounted) return;
    await c.read<MatrixService>().sendMeeting(room, title: title.text.trim(), start: start, minutes: minutes);
    if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Meeting posted in the channel and added to everyone\'s calendar')));
  }

  String? _thread(Event e) { final r = e.content.tryGetMap<String, Object?>('m.relates_to'); return r?['rel_type'] == 'm.thread' ? r!['event_id'] as String? : null; }

  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme; final evs = tl?.events ?? const <Event>[];
    final posts = evs.where((e) => e.type == EventTypes.Message && _thread(e) == null && e.relationshipType != RelationshipTypes.edit && !e.redacted).toList();
    final replies = <String, List<Event>>{};
    for (final e in evs) { final t = _thread(e); if (t != null && e.type == EventTypes.Message) (replies[t] ??= []).add(e); }
    final m = context.watch<MatrixService>();
    final tabs = ((m.channelSettings(room)['tabs'] as List?) ?? const []).map((x) => '$x').where(kChannelTabs.containsKey).toList();
    final canPost = m.canStartPost(room);
    return DefaultTabController(length: 2 + tabs.length, child: Scaffold(
      appBar: AppBar(title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text(room.getLocalizedDisplayname()), Text(widget.teamName, style: Theme.of(c).textTheme.labelSmall)]),
        actions: [
          IconButton(tooltip: 'Meet in this channel', icon: const Icon(Icons.video_call), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, meeting: true)))),
          IconButton(tooltip: 'Schedule a channel meeting', icon: const Icon(Icons.event), onPressed: () => _schedule(c)),
          PopupMenuButton<String>(tooltip: 'Add a tab', icon: const Icon(Icons.add_box_outlined), onSelected: (k) async {
            final cur = [...tabs]; cur.contains(k) ? cur.remove(k) : cur.add(k);
            try { await m.setChannelSettings(room, {'tabs': cur}); } catch (_) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Only channel owners can change tabs'))); }
          }, itemBuilder: (_) => [for (final e in kChannelTabs.entries) CheckedPopupMenuItem(value: e.key, checked: tabs.contains(e.key), child: Text(e.key))]),
        ],
        bottom: TabBar(isScrollable: true, tabs: [const Tab(text: 'Posts'), const Tab(text: 'Files'), for (final t in tabs) Tab(text: t)])),
      body: TabBarView(children: [
        Column(children: [
          Expanded(child: tl == null ? const Center(child: CircularProgressIndicator())
            : posts.isEmpty ? const Center(child: Text('No posts yet. Start a conversation below.'))
            : ListView.builder(reverse: true, padding: const EdgeInsets.all(8), itemCount: posts.length, itemBuilder: (_, i) {
                final p = posts[i]; final rs = replies[p.eventId] ?? const <Event>[];
                return Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Row(children: [CircleAvatar(radius: 14, child: Text(_initials(p.senderFromMemoryOrFallback.calcDisplayname()), style: const TextStyle(fontSize: 11))), const SizedBox(width: 8),
                    Text(p.senderFromMemoryOrFallback.calcDisplayname(), style: const TextStyle(fontWeight: FontWeight.w600)), const SizedBox(width: 8),
                    Text(DateFormat('d MMM HH:mm').format(p.originServerTs), style: Theme.of(c).textTheme.labelSmall)]),
                  const SizedBox(height: 6), SelectableText(p.getDisplayEvent(tl!).body),
                  if (rs.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${rs.first.senderFromMemoryOrFallback.calcDisplayname()}: ${rs.first.body}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: cs.onSurfaceVariant))),
                  Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.reply, size: 18),
                    label: Text(rs.isEmpty ? 'Reply' : '${rs.length} ${rs.length == 1 ? 'reply' : 'replies'}'),
                    onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, threadRootId: p.eventId))))),
                ])));
              })),
          if (!canPost) const SafeArea(child: Padding(padding: EdgeInsets.all(12), child: Row(children: [Icon(Icons.shield_outlined, size: 18), SizedBox(width: 8),
            Expanded(child: Text('This channel is moderated: only moderators start new posts. You can reply to any post.'))]))),
          if (canPost) SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
            Expanded(child: TextField(controller: post, minLines: 1, maxLines: 5, decoration: const InputDecoration(hintText: 'Start a new post (encrypted)', border: OutlineInputBorder()))),
            const SizedBox(width: 8),
            FilledButton(onPressed: () async { final t = post.text.trim(); if (t.isEmpty) return; post.clear(); await room.sendTextEvent(t); }, child: Text(L.t(context, 'Post')))]))),
        ]),
        ChatScreen(roomId: room.id, filesOnly: true),
        for (final t in tabs) kChannelTabs[t]!(room),
      ])));
  }
}
