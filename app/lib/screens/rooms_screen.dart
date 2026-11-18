import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';
import 'people_picker.dart';

class RoomsScreen extends StatefulWidget { const RoomsScreen({super.key}); @override State<RoomsScreen> createState() => _RS(); }
class _RS extends State<RoomsScreen> {
  String filter = 'all'; final q = TextEditingController(); bool searching = false;
  @override
  Widget build(BuildContext c) {
    final m = c.watch<MatrixService>();
    bool archived(r) => r.tags.containsKey(TagType.lowPriority);
    var list = m.chats.where((r) => switch (filter) {
      'unread' => r.notificationCount > 0 || r.isUnread, 'people' => r.isDirectChat, 'groups' => !r.isDirectChat,
      'pinned' => r.isFavourite, 'archived' => archived(r), _ => !archived(r) }).toList();
    if (q.text.isNotEmpty) list = list.where((r) => r.getLocalizedDisplayname().toLowerCase().contains(q.text.toLowerCase())).toList();
    list = [...list.where((x) => x.isFavourite), ...list.where((x) => !x.isFavourite)];
    return Scaffold(
      appBar: AppBar(title: searching ? TextField(controller: q, autofocus: true, decoration: const InputDecoration(hintText: 'Search chats', border: InputBorder.none), onChanged: (_) => setState(() {})) : const Text('Chats'),
        bottom: PreferredSize(preferredSize: const Size.fromHeight(48), child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8), child: Row(children: [
          for (final (k, l) in [('all', 'All'), ('unread', 'Unread'), ('people', 'People'), ('groups', 'Groups'), ('pinned', 'Pinned'), ('archived', 'Archived')])
            Padding(padding: const EdgeInsets.only(right: 6, bottom: 8), child: ChoiceChip(label: Text(l), selected: filter == k, onSelected: (_) => setState(() => filter = k)))]))),
        actions: [
        IconButton(icon: Icon(searching ? Icons.close : Icons.search), onPressed: () => setState(() { searching = !searching; q.clear(); })),
        IconButton(tooltip: 'Set your status', icon: const Icon(Icons.emoji_emotions_outlined), onPressed: () async {
          final ctl = TextEditingController();
          final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: const Text('Your status'),
            content: TextField(controller: ctl, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. In a meeting until 3 pm')),
            actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Set'))]));
          if (ok == true) await m.client.setPresence(m.userId, PresenceType.online, statusMsg: ctl.text.trim());
        })]),
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('New encrypted chat'), onPressed: () => _new(c, m)),
      body: ListView(children: [for (final r in list) ListTile(
        onLongPress: () => r.setFavourite(!r.isFavourite),
        leading: CircleAvatar(child: Text(r.getLocalizedDisplayname().characters.first.toUpperCase())),
        title: Text(r.getLocalizedDisplayname()),
        subtitle: Text(r.lastEvent?.body ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Row(mainAxisSize: MainAxisSize.min, children: [
          if (r.notificationCount > 0) Badge(label: Text('${r.notificationCount}')),
          if (r.isFavourite) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.push_pin, size: 16)),
          if (r.pushRuleState != PushRuleState.notify) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.notifications_off_outlined, size: 16)),
          const SizedBox(width: 6), Icon(r.encrypted ? Icons.lock : Icons.lock_open, size: 16, color: r.encrypted ? null : Colors.red)]),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: r.id))),
      )]),
    );
  }
  Future<void> _new(BuildContext c, MatrixService m) async {
    final people = await pickPeople(c, multiple: true, title: 'New encrypted chat');
    if (people == null || people.isEmpty || !c.mounted) return;
    var name = '';
    if (people.length > 1) {
      final ctl = TextEditingController();
      await showDialog(context: c, builder: (d) => AlertDialog(title: const Text('Group name'), content: TextField(controller: ctl, autofocus: true),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Create'))]));
      name = ctl.text.trim().isEmpty ? people.map((p) => p.displayName ?? p.userId).join(', ') : ctl.text.trim();
    }
    final id = await m.createRoom(name: name, invite: people.map((p) => p.userId).toList(), direct: people.length == 1);
    if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: id)));
  }
}
