import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import '../services/meeting_service.dart';
import 'chat_screen.dart';
import 'people_picker.dart';

/// Chat / group info: name, description, members and roles, notifications, disappearing messages,
/// announcement mode, shared files, invite, archive, block, leave.
class ChatInfoScreen extends StatefulWidget { const ChatInfoScreen({super.key, required this.roomId}); final String roomId; @override State<ChatInfoScreen> createState() => _S(); }
class _S extends State<ChatInfoScreen> {
  Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  String get me => room.client.userID!;
  void _msg(Object t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$t'.replaceFirst('Exception: ', ''))));
  Future<String?> _ask(String title, String initial) async {
    final c = TextEditingController(text: initial);
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text(title), content: TextField(controller: c, autofocus: true, maxLines: null),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
    return ok == true ? c.text.trim() : null;
  }
  int? get lifetimeMs => (room.getState('m.room.retention')?.content['max_lifetime'] as num?)?.toInt();
  bool get announce => (room.getState(EventTypes.RoomPowerLevels)?.content['events_default'] as num? ?? 0) >= 50;

  Future<void> _setRetention(int? ms) async {
    await room.client.setRoomStateWithKey(room.id, 'm.room.retention', '', ms == null ? {} : {'max_lifetime': ms});
    await room.sendTextEvent(ms == null ? '⏱ Disappearing messages turned off' : '⏱ New messages now disappear after ${_dur(ms)}');
    setState(() {});
  }
  static String _dur(int ms) => ms >= 86400000 * 7 ? '${ms ~/ (86400000 * 7)} week(s)' : ms >= 86400000 ? '${ms ~/ 86400000} day(s)' : '${ms ~/ 3600000} hour(s)';

  Future<void> _setAnnounce(bool on) async {
    final pl = Map<String, Object?>.from(room.getState(EventTypes.RoomPowerLevels)?.content ?? {});
    pl['events_default'] = on ? 50 : 0;
    await room.client.setRoomStateWithKey(room.id, EventTypes.RoomPowerLevels, '', pl);
    setState(() {});
  }

  @override Widget build(BuildContext c) {
    final members = room.getParticipants();
    final admin = room.canChangePowerLevel;
    final dm = room.directChatMatrixID;
    final mid = MeetingService(context.read<MatrixService>()).meetingIdOf(room);
    return Scaffold(appBar: AppBar(title: Text(dm != null ? 'Contact info' : 'Group info')), body: ListView(children: [
      const SizedBox(height: 16),
      Center(child: CircleAvatar(radius: 40, child: Text(room.getLocalizedDisplayname().characters.first.toUpperCase(), style: const TextStyle(fontSize: 32)))),
      const SizedBox(height: 8),
      Center(child: Text(room.getLocalizedDisplayname(), style: Theme.of(c).textTheme.titleLarge)),
      if (room.topic.isNotEmpty) Padding(padding: const EdgeInsets.all(12), child: Text(room.topic, textAlign: TextAlign.center)),
      const Center(child: Chip(avatar: Icon(Icons.lock, size: 16), label: Text('End-to-end encrypted'))),
      if (mid != null) ListTile(leading: const Icon(Icons.tag), title: Text('Meeting ID ${MeetingService.format(mid)}'), trailing: const Icon(Icons.copy),
        onTap: () { Clipboard.setData(ClipboardData(text: MeetingService.format(mid))); _msg('Meeting ID copied'); }),
      const Divider(),
      if (dm == null && room.canChangeStateEvent(EventTypes.RoomName)) ...[
        ListTile(leading: const Icon(Icons.edit), title: const Text('Rename'), onTap: () async { final n = await _ask('Group name', room.getLocalizedDisplayname()); if (n != null && n.isNotEmpty) { await room.setName(n); setState(() {}); } }),
        ListTile(leading: const Icon(Icons.description_outlined), title: const Text('Description'), subtitle: Text(room.topic.isEmpty ? 'Add a description' : room.topic, maxLines: 1),
          onTap: () async { final n = await _ask('Description', room.topic); if (n != null) { await room.setDescription(n); setState(() {}); } }),
      ],
      ListTile(leading: const Icon(Icons.notifications_outlined), title: const Text('Notifications'),
        trailing: DropdownButton<PushRuleState>(value: room.pushRuleState, underline: const SizedBox(), onChanged: (v) async { if (v != null) { await room.setPushRuleState(v); setState(() {}); } },
          items: const [DropdownMenuItem(value: PushRuleState.notify, child: Text('All')), DropdownMenuItem(value: PushRuleState.mentionsOnly, child: Text('Mentions only')), DropdownMenuItem(value: PushRuleState.dontNotify, child: Text('Muted'))])),
      ListTile(leading: const Icon(Icons.timer_outlined), title: const Text('Disappearing messages'), subtitle: Text(lifetimeMs == null ? 'Off' : 'After ${_dur(lifetimeMs!)}'),
        enabled: room.canChangeStateEvent('m.room.retention'),
        onTap: () async {
          final v = await showDialog<int>(context: c, builder: (d) => SimpleDialog(title: const Text('Messages disappear after'), children: [
            for (final (l, ms) in [('Off', 0), ('24 hours', 86400000), ('7 days', 604800000), ('90 days', 7776000000)])
              SimpleDialogOption(onPressed: () => Navigator.pop(d, ms), child: Text(l))]));
          if (v != null) await _setRetention(v == 0 ? null : v);
        }),
      if (dm == null && admin) SwitchListTile(secondary: const Icon(Icons.campaign_outlined), title: const Text('Announcements only'), subtitle: const Text('Only admins can send messages'), value: announce, onChanged: _setAnnounce),
      ListTile(leading: const Icon(Icons.folder_outlined), title: const Text('Files, photos and voice'), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, filesOnly: true)))),
      const Divider(),
      if (dm == null) ...[
        ListTile(title: Text('${members.length} members', style: Theme.of(c).textTheme.titleSmall),
          trailing: room.canInvite ? TextButton.icon(icon: const Icon(Icons.person_add), label: const Text('Add'), onPressed: () async {
            final p = await pickPeople(c, multiple: true, title: 'Add members');
            for (final x in p ?? []) { await room.invite(x.userId); }
            setState(() {});
          }) : null),
        for (final u in members) ListTile(
          leading: CircleAvatar(child: Text(u.calcDisplayname().characters.first.toUpperCase())),
          title: Text(u.id == me ? '${u.calcDisplayname()} (you)' : u.calcDisplayname()),
          subtitle: Text('${u.id}${u.membership == Membership.invite ? ' · invited' : ''}'),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (u.powerLevel.level >= 100) const Chip(label: Text('Admin')) else if (u.powerLevel.level >= 50) const Chip(label: Text('Moderator')),
            if (u.id != me && (admin || room.canKick)) PopupMenuButton<String>(onSelected: (a) async {
              try {
                if (a == 'admin') await room.setPower(u.id, 100);
                if (a == 'user') await room.setPower(u.id, 0);
                if (a == 'remove') await room.kick(u.id);
                setState(() {});
              } catch (e) { _msg(e); }
            }, itemBuilder: (_) => [
              if (admin && u.powerLevel.level < 100) const PopupMenuItem(value: 'admin', child: Text('Make admin')),
              if (admin && u.powerLevel.level >= 50) const PopupMenuItem(value: 'user', child: Text('Remove admin')),
              if (room.canKick) const PopupMenuItem(value: 'remove', child: Text('Remove from group'))]),
          ])),
        const Divider(),
      ],
      ListTile(leading: Icon(room.tags.containsKey(TagType.lowPriority) ? Icons.unarchive_outlined : Icons.archive_outlined),
        title: Text(room.tags.containsKey(TagType.lowPriority) ? 'Unarchive chat' : 'Archive chat'),
        onTap: () async { room.tags.containsKey(TagType.lowPriority) ? await room.removeTag(TagType.lowPriority) : await room.addTag(TagType.lowPriority); if (c.mounted) Navigator.pop(c); }),
      if (dm != null && room.client.ignoredUsers.contains(dm)) ListTile(leading: const Icon(Icons.lock_open), title: const Text('Unblock contact'),
        subtitle: const Text('Their new messages and calls will reach you again'),
        onTap: () async { await room.client.unignoreUser(dm); _msg('Unblocked'); if (mounted) setState(() {}); }),
      if (dm != null && !room.client.ignoredUsers.contains(dm)) ListTile(leading: Icon(Icons.block, color: Theme.of(c).colorScheme.error), title: const Text('Block contact'),
        subtitle: const Text('You will no longer see their messages or calls. The server stops delivering them to you.'),
        onTap: () async { await room.client.ignoreUser(dm); _msg('Blocked'); if (mounted) setState(() {}); }),
      ListTile(leading: Icon(Icons.logout, color: Theme.of(c).colorScheme.error), title: Text(dm != null ? 'Delete chat' : 'Leave group'),
        onTap: () async { await room.leave(); if (c.mounted) Navigator.popUntil(c, (r) => r.isFirst); }),
      const SizedBox(height: 24),
    ]));
  }
}
