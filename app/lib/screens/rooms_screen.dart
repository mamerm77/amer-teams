import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';
import 'people_picker.dart';

class RoomsScreen extends StatelessWidget {
  const RoomsScreen({super.key});
  @override
  Widget build(BuildContext c) {
    final m = c.watch<MatrixService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Chats')),
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('New encrypted chat'), onPressed: () => _new(c, m)),
      body: ListView(children: [for (final r in m.chats) ListTile(
        leading: CircleAvatar(child: Text(r.getLocalizedDisplayname().characters.first.toUpperCase())),
        title: Text(r.getLocalizedDisplayname()),
        subtitle: Text(r.lastEvent?.body ?? '', maxLines: 1, overflow: TextOverflow.ellipsis),
        trailing: Icon(r.encrypted ? Icons.lock : Icons.lock_open, size: 16, color: r.encrypted ? null : Colors.red),
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
