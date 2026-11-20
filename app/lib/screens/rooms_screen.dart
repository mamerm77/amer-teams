import '../services/availability.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';
import 'package:intl/intl.dart';
import '../services/call_manager.dart' show peerName;
import 'copilot_screen.dart' show openAmerChat;
import 'people_picker.dart';
import 'notifications_screen.dart';
import 'partners_screen.dart';
import 'search_screen.dart';
import '../services/locale.dart';
import 'followed_threads_screen.dart';
import '../services/quick_views.dart';

/// One-line preview of a chat's last event, as a person reads it (technical events never shown).
String previewOf(Event? e, Room r, String me) {
  if (e == null) return '🔒 End-to-end encrypted chat';
  if (e.redacted) return '🚫 Message deleted';
  final who = r.isDirectChat || e.senderId == me ? '' : '${e.senderFromMemoryOrFallback.calcDisplayname().split(' ').first}: ';
  switch (e.type) {
    case EventTypes.Message:
      return who + switch (e.messageType) {
        MessageTypes.Image => '📷 Photo', MessageTypes.Video => '🎬 Video', MessageTypes.Audio => '🎤 Voice message',
        MessageTypes.File => '📎 ${e.body}', MessageTypes.Location => '📍 Location', _ => e.body.split('\n').first };
    case EventTypes.Encrypted: return '🔒 Encrypted message';
    case 'com.amerteams.call.invite': return (e.content['call_id'] as String? ?? '').startsWith('meet-') ? '📅 Meeting started' : e.content['media'] == 'audio' ? '📞 Voice call' : '📹 Video call';
    case 'com.amerteams.call.end': return e.content['outcome'] == 'missed' ? '📞 Missed call' : '📞 Call ended';
    case 'com.amerteams.reaction': return '${who}reacted ${(e.content['com.amerteams.reaction'] as Map?)?['key'] ?? ''}';
    case 'org.matrix.msc3381.poll.start': return '${who}📊 Poll';
    case 'com.amerteams.checklist': return '${who}☑ Checklist';
  }
  if (e.type.startsWith('com.amerteams.call.')) return '📞 Call';
  return '🔒 End-to-end encrypted chat';
}

/// The open chat in the two-pane layout (chat list on the left, the chat on the right), as in Teams and Slack.
final selectedChat = ValueNotifier<String?>(null);
bool twoPane(BuildContext c) => MediaQuery.sizeOf(c).width >= 1000;
void openChat(BuildContext c, String roomId) {
  if (twoPane(c)) { selectedChat.value = roomId; return; }
  Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)));
}

class RoomsScreen extends StatefulWidget { const RoomsScreen({super.key}); @override State<RoomsScreen> createState() => _RS(); }
class _RS extends State<RoomsScreen> {
  String filter = 'all'; final q = TextEditingController(); bool searching = false;
  @override
  Widget build(BuildContext c) {
    final m = c.watch<MatrixService>();
    // One way to put a chat aside, as in Teams: Hide (comes back with a new message). Chats archived by older versions count as hidden.
    final hiddenAt = _hidden(m);
    bool archived(Room r) => r.tags.containsKey(TagType.lowPriority) || (hiddenAt[r.id] != null && (r.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0) <= hiddenAt[r.id]!);
    var list = m.chats.where((r) => switch (filter) {
      'unread' => r.notificationCount > 0 || r.isUnread, 'people' => r.isDirectChat, 'groups' => !r.isDirectChat,
      'mentions' => r.highlightCount > 0, 'drafts' => Drafts.instance.of(r.id) != null,
      'pinned' => r.isFavourite, 'archived' => archived(r), _ => !archived(r) }).toList();
    if (q.text.isNotEmpty) list = list.where((r) => r.getLocalizedDisplayname().toLowerCase().contains(q.text.toLowerCase())).toList();
    list = [...list.where((x) => x.isFavourite), ...list.where((x) => !x.isFavourite)];
    return Scaffold(
      appBar: AppBar(title: searching ? TextField(controller: q, autofocus: true, decoration: const InputDecoration(hintText: 'Search chats', border: InputBorder.none), onChanged: (_) => setState(() {})) : Text(t(c, 'Chats')),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(48), child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          for (final (k, l) in [('all', 'All'), ('unread', 'Unread'), ('mentions', '@Mentions'), ('drafts', 'Drafts'), ('people', 'People'), ('groups', 'Groups'), ('pinned', 'Favourites'), ('archived', 'Hidden')])
            Padding(padding: const EdgeInsets.only(right: 6, bottom: 8), child: ChoiceChip(label: Text(t(c, l)), selected: filter == k, onSelected: (_) async { if (k == 'drafts') await Drafts.instance.load(); setState(() => filter = k); })),
          Padding(padding: const EdgeInsets.only(right: 6, bottom: 8), child: ActionChip(avatar: const Icon(Icons.forum_outlined, size: 16), label: const Text('Followed threads'),
            onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const FollowedThreadsScreen()))))]))),
        actions: [
        IconButton(icon: Icon(searching ? Icons.close : Icons.search), onPressed: () => setState(() { searching = !searching; q.clear(); })),
        IconButton(tooltip: 'Search everywhere', icon: const Icon(Icons.manage_search), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SearchScreen()))),
        IconButton(tooltip: 'New shared channel (partner organisation)', icon: const Icon(Icons.handshake_outlined), onPressed: () => newSharedChannel(c)),
        IconButton(tooltip: 'Notifications', icon: const Icon(Icons.notifications_outlined), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const NotificationsScreen()))),
        IconButton(tooltip: 'Set your status', icon: const Icon(Icons.emoji_emotions_outlined), onPressed: () => showAvailability(c)),
        ]),
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: Text(t(c, 'New chat')), onPressed: () => _new(c, m)),
      body: Builder(builder: (_) {
        final cs = Theme.of(c).colorScheme; final me = m.userId;
        final invites = m.client.rooms.where((r) => r.membership == Membership.invite && !r.isSpace).toList();
        final chats = list.where((r) => r.membership == Membership.join).toList()
          ..sort((a, b) { if (a.isFavourite != b.isFavourite) return a.isFavourite ? -1 : 1;
                         return (b.lastEvent?.originServerTs ?? DateTime(2000)).compareTo(a.lastEvent?.originServerTs ?? DateTime(2000)); });
        if (invites.isEmpty && chats.isEmpty) {
          return Center(child: Padding(padding: const EdgeInsets.all(32), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.forum_outlined, size: 56, color: cs.primary), const SizedBox(height: 12),
            Text(filter == 'all' ? 'No chats yet' : 'Nothing here', style: Theme.of(c).textTheme.titleMedium), const SizedBox(height: 6),
            const Text('Every chat is end-to-end encrypted. Start one with a colleague, or ask Amer anything.', textAlign: TextAlign.center),
            const SizedBox(height: 16),
            Wrap(spacing: 8, children: [FilledButton.icon(onPressed: () => _new(c, m), icon: const Icon(Icons.add), label: const Text('New chat')),
              OutlinedButton.icon(onPressed: () => openAmerChat(c), icon: const Icon(Icons.auto_awesome), label: const Text('Chat with Amer'))])])));
        }
        return ListView(children: [
          if (invites.isNotEmpty) Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Invitations', style: Theme.of(c).textTheme.labelLarge?.copyWith(color: cs.primary))),
          for (final r in invites) ListTile(
            leading: CircleAvatar(backgroundColor: cs.tertiaryContainer, child: const Icon(Icons.mail_outline)),
            title: Text(peerName(r)),
            subtitle: Text('${r.isDirectChat ? 'wants to chat with you' : 'invited you to a group'} · encrypted'),
            trailing: Wrap(spacing: 6, children: [
              TextButton(onPressed: () async { await r.leave(); }, child: const Text('Decline')),
              FilledButton(onPressed: () async { await r.join(); if (c.mounted) openChat(c, r.id); }, child: const Text('Accept'))])),
          if (invites.isNotEmpty) const Divider(),
          if (filter != 'all' || searching) for (final r in chats) _tile(c, r, m, cs, me)
          else ...() {
            // Teams' chat list: Favourites, your own sections, recent chats, then Muted at the bottom; hidden chats
            // stay out until someone posts a new message (docs/CHAT_LIST.md).
            final sec = _sections(m), hidden = _hidden(m);
            bool isHidden(Room r) { final at = hidden[r.id]; return at != null && (r.lastEvent?.originServerTs.millisecondsSinceEpoch ?? 0) <= at; }
            final visible = chats.where((r) => !isHidden(r)).toList();
            final inSection = {for (final x in sec) ...((x['rooms'] as List?) ?? const []).map((e) => '$e')};
            final fav = visible.where((r) => r.isFavourite).toList();
            final muted = visible.where((r) => !r.isFavourite && !inSection.contains(r.id) && r.pushRuleState != PushRuleState.notify).toList();
            final recent = visible.where((r) => !r.isFavourite && !inSection.contains(r.id) && r.pushRuleState == PushRuleState.notify).toList();
            Widget head(String t, {String? section, bool collapsed = false, int n = 0}) => InkWell(
              onTap: section == null ? null : () => _toggleSection(m, section),
              onLongPress: section == null ? null : () => _sectionMenu(c, m, section),
              child: Padding(padding: const EdgeInsets.fromLTRB(16, 12, 8, 4), child: Row(children: [
                if (section != null) Icon(collapsed ? Icons.chevron_right : Icons.expand_more, size: 18),
                Text(t, style: Theme.of(c).textTheme.labelLarge?.copyWith(color: cs.primary)), const Spacer(),
                if (collapsed && n > 0) Badge(label: Text('$n')),
                if (section != null) IconButton(tooltip: 'Section options', visualDensity: VisualDensity.compact, icon: const Icon(Icons.more_horiz, size: 18), onPressed: () => _sectionMenu(c, m, section)),
              ])));
            return [
              if (fav.isNotEmpty) ...[head('Favourites'), for (final r in fav) _tile(c, r, m, cs, me)],
              for (final x in sec) ...() {
                final rs = visible.where((r) => ((x['rooms'] as List?) ?? const []).contains(r.id) && !r.isFavourite).toList();
                final col = x['collapsed'] == true;
                return [head('${x['name']}', section: '${x['name']}', collapsed: col, n: rs.where((r) => r.notificationCount > 0).length), if (!col) for (final r in rs) _tile(c, r, m, cs, me)];
              }(),
              if (fav.isNotEmpty || sec.isNotEmpty) head('Chats'),
              for (final r in recent) _tile(c, r, m, cs, me),
              if (muted.isNotEmpty) ...[head('Muted'), for (final r in muted) _tile(c, r, m, cs, me)],
              if (hidden.isNotEmpty) Padding(padding: const EdgeInsets.all(8), child: TextButton.icon(icon: const Icon(Icons.visibility_outlined), label: Text('Hidden chats (${chats.where(isHidden).length})'),
                onPressed: () => _showHidden(c, m, chats.where(isHidden).toList()))),
            ];
          }(),
        ]);
      }),
    );
  }
  Widget _tile(BuildContext c, Room r, MatrixService m, ColorScheme cs, String me) {
            final name = peerName(r); final unread = r.notificationCount > 0 || r.isUnread;
    final typers = r.typingUsers.where((u) => u.id != me).toList();
    final ev = r.lastEvent; final mine = ev?.senderId == me;
    return ListTile(
      onTap: () => openChat(c, r.id),
      onLongPress: () => _menu(c, r),
      leading: CircleAvatar(backgroundColor: cs.primaryContainer, child: Text(_initials(name), style: TextStyle(color: cs.onPrimaryContainer))),
      title: Row(children: [
        Expanded(child: Text(name, overflow: TextOverflow.ellipsis, style: TextStyle(fontWeight: unread ? FontWeight.w700 : null))),
        if (ev != null) Text(_when(ev.originServerTs), style: Theme.of(c).textTheme.labelSmall?.copyWith(color: unread ? cs.primary : null))]),
      subtitle: Row(children: [
        if (typers.isNotEmpty) Expanded(child: Text('typing…', style: TextStyle(color: cs.primary)))
        else ...[
          if (mine && ev != null && ev.type == EventTypes.Message) Padding(padding: const EdgeInsets.only(right: 3),
            child: Icon(ev.receipts.any((x) => x.user.id != me) ? Icons.done_all : Icons.done, size: 14, color: ev.receipts.any((x) => x.user.id != me) ? cs.primary : null)),
          Expanded(child: Text('${mine && ev != null && ev.type == EventTypes.Message ? 'You: ' : ''}${previewOf(ev, r, me)}', maxLines: 1, overflow: TextOverflow.ellipsis,
            style: TextStyle(fontWeight: unread ? FontWeight.w600 : null))),
        ],
        if (r.isFavourite) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.push_pin, size: 14)),
        if (r.pushRuleState != PushRuleState.notify) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.notifications_off_outlined, size: 14)),
        if (!r.encrypted) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.lock_open, size: 14, color: Colors.red)),
        if (r.notificationCount > 0) Padding(padding: const EdgeInsets.only(left: 6),
          child: Badge(backgroundColor: r.highlightCount > 0 ? cs.error : cs.primary, label: Text(r.highlightCount > 0 ? '@${r.notificationCount}' : '${r.notificationCount}'))),
      ]));
  }

  // ---- sections, favourites, hidden (account data, so every device agrees) ----
  static const _kSections = 'com.amerteams.chat_sections', _kHidden = 'com.amerteams.hidden_chats';
  List<Map> _sections(MatrixService m) => ((m.client.accountData[_kSections]?.content['sections'] as List?) ?? const []).whereType<Map>().toList();
  Map<String, int> _hidden(MatrixService m) => ((m.client.accountData[_kHidden]?.content['rooms'] as Map?) ?? const {}).map((k, v) => MapEntry('$k', (v as num).toInt()));
  Future<void> _saveSections(MatrixService m, List<Map> s) async { await m.client.setAccountData(m.userId, _kSections, {'sections': s}); if (mounted) setState(() {}); }
  Future<void> _toggleSection(MatrixService m, String name) => _saveSections(m, [for (final x in _sections(m)) x['name'] == name ? {...x, 'collapsed': x['collapsed'] != true} : x]);
  Future<void> _sectionMenu(BuildContext c, MatrixService m, String name) async {
    final a = await showModalBottomSheet<String>(context: c, builder: (s) => SafeArea(child: Wrap(children: [
      ListTile(title: Text(name, style: Theme.of(c).textTheme.titleSmall)),
      ListTile(leading: const Icon(Icons.edit), title: const Text('Rename section'), onTap: () => Navigator.pop(s, 'rename')),
      ListTile(leading: const Icon(Icons.arrow_upward), title: const Text('Move up'), onTap: () => Navigator.pop(s, 'up')),
      ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete section (chats go back to Chats)'), onTap: () => Navigator.pop(s, 'delete')),
    ])));
    final sec = _sections(m); final i = sec.indexWhere((x) => x['name'] == name); if (i < 0) return;
    if (a == 'delete') { sec.removeAt(i); await _saveSections(m, sec); }
    if (a == 'up' && i > 0) { final x = sec.removeAt(i); sec.insert(i - 1, x); await _saveSections(m, sec); }
    if (a == 'rename' && c.mounted) { final n = await _ask(c, 'Rename section', name); if (n != null) { sec[i] = {...sec[i], 'name': n}; await _saveSections(m, sec); } }
  }
  Future<String?> _ask(BuildContext c, String title, [String init = '']) async {
    final t = TextEditingController(text: init);
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text(title), content: TextField(controller: t, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('OK'))]));
    return ok == true && t.text.trim().isNotEmpty ? t.text.trim() : null;
  }
  Future<void> _moveTo(BuildContext c, MatrixService m, Room r) async {
    final sec = _sections(m);
    final v = await showDialog<String>(context: c, builder: (d) => SimpleDialog(title: const Text('Move to'), children: [
      SimpleDialogOption(onPressed: () => Navigator.pop(d, '#fav'), child: const Text('Favourites')),
      for (final x in sec) SimpleDialogOption(onPressed: () => Navigator.pop(d, '${x['name']}'), child: Text('${x['name']}')),
      SimpleDialogOption(onPressed: () => Navigator.pop(d, '#new'), child: const Text('New section…')),
      SimpleDialogOption(onPressed: () => Navigator.pop(d, '#none'), child: const Text('Remove from section')),
    ]));
    if (v == null || !c.mounted) return;
    if (v == '#fav') { await r.setFavourite(true); setState(() {}); return; }
    var name = v;
    if (v == '#new') { final n = await _ask(c, 'New section'); if (n == null) return; name = n; if (sec.length >= 50) return; sec.add({'name': n, 'rooms': []}); }
    final out = [for (final x in sec) {...x, 'rooms': [...((x['rooms'] as List?) ?? const []).where((e) => e != r.id), if (x['name'] == name && v != '#none') r.id]}];
    if (r.isFavourite) await r.setFavourite(false);
    await _saveSections(m, out);
  }
  Future<void> _hide(MatrixService m, Room r, bool on) async {
    final h = _hidden(m);
    if (on) { h[r.id] = r.lastEvent?.originServerTs.millisecondsSinceEpoch ?? DateTime.now().millisecondsSinceEpoch; } else { h.remove(r.id); }
    await m.client.setAccountData(m.userId, _kHidden, {'rooms': h}); if (mounted) setState(() {});
  }
  void _showHidden(BuildContext c, MatrixService m, List<Room> rs) => showModalBottomSheet(context: c, builder: (s) => SafeArea(child: ListView(shrinkWrap: true, children: [
    const ListTile(title: Text('Hidden chats'), subtitle: Text('They come back by themselves when someone sends a new message.')),
    for (final r in rs) ListTile(title: Text(peerName(r), style: const TextStyle(fontStyle: FontStyle.italic)), trailing: TextButton(onPressed: () { Navigator.pop(s); _hide(m, r, false); }, child: const Text('Unhide')),
      onTap: () { Navigator.pop(s); openChat(c, r.id); }),
  ])));

  static String _initials(String n) { final p = n.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList(); return p.isEmpty ? '?' : (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase(); }
  static String _when(DateTime t) {
    final now = DateTime.now(); final d = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
    if (d == today) return DateFormat('HH:mm').format(t);
    if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
    if (now.difference(t).inDays < 7) return DateFormat('EEEE').format(t);
    return DateFormat('d/M/yy').format(t);
  }
  Future<void> _menu(BuildContext c, Room r) async {
    final unread = r.notificationCount > 0 || r.isUnread, muted = r.pushRuleState != PushRuleState.notify, archived = r.tags.containsKey(TagType.lowPriority);   // legacy archive = hidden
    final a = await showModalBottomSheet<String>(context: c, builder: (s) => SafeArea(child: Wrap(children: [
      ListTile(title: Text(peerName(r), style: Theme.of(c).textTheme.titleSmall)),
      ListTile(leading: Icon(r.isFavourite ? Icons.star : Icons.star_border), title: Text(r.isFavourite ? 'Remove from Favourites' : 'Add to Favourites'), onTap: () => Navigator.pop(s, 'pin')),
      ListTile(leading: const Icon(Icons.drive_file_move_outline), title: const Text('Move to a section…'), onTap: () => Navigator.pop(s, 'move')),
      if (!archived && !_hidden(context.read<MatrixService>()).containsKey(r.id)) ListTile(leading: const Icon(Icons.visibility_off_outlined), title: const Text('Hide (comes back with a new message)'), onTap: () => Navigator.pop(s, 'hide'))
      else ListTile(leading: const Icon(Icons.visibility_outlined), title: const Text('Unhide'), onTap: () => Navigator.pop(s, 'unhide')),
      ListTile(leading: Icon(muted ? Icons.notifications_active_outlined : Icons.notifications_off_outlined), title: Text(muted ? 'Unmute' : 'Mute (only @mentions notify)'), onTap: () => Navigator.pop(s, 'mute')),
      ListTile(leading: Icon(unread ? Icons.mark_chat_read_outlined : Icons.mark_chat_unread_outlined), title: Text(unread ? 'Mark as read' : 'Mark as unread'), onTap: () => Navigator.pop(s, 'read')),
    ])));
    switch (a) {
      case 'pin': await r.setFavourite(!r.isFavourite);
      case 'move': if (c.mounted) await _moveTo(c, context.read<MatrixService>(), r);
      case 'hide': await _hide(context.read<MatrixService>(), r, true);
      case 'unhide': await _hide(context.read<MatrixService>(), r, false); if (archived) await r.removeTag(TagType.lowPriority);
      case 'mute': await r.setPushRuleState(muted ? PushRuleState.notify : PushRuleState.mentionsOnly);   // Teams: muted chats still notify @mentions
      case 'read': if (unread) { await r.setReadMarker(r.lastEvent?.eventId, mRead: r.lastEvent?.eventId); } else { await r.markUnread(true); }
    }
    if (mounted) setState(() {});
  }

  Future<void> _new(BuildContext c, MatrixService m) async {
    final people = await pickPeople(c, multiple: true, title: 'New chat');
    if (people == null || people.isEmpty || !c.mounted) return;
    var name = '';
    if (people.length > 1) {
      final ctl = TextEditingController();
      await showDialog(context: c, builder: (d) => AlertDialog(title: const Text('Group name'), content: TextField(controller: ctl, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Create'))]));
      name = ctl.text.trim().isEmpty ? people.map((p) => p.displayName ?? p.userId).join(', ') : ctl.text.trim();
    }
    final id = await m.createRoom(name: name, invite: people.map((p) => p.userId).toList(), direct: people.length == 1);
    if (c.mounted) openChat(c, id);
  }
}
