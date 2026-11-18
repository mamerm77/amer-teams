import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

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
    final name = TextEditingController(), ids = TextEditingController();
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: const Text('New encrypted chat'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Name (groups only)')),
      TextField(controller: ids, decoration: const InputDecoration(labelText: 'Matrix IDs, comma-separated', hintText: '@sara:example.com'))]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create'))]));
    if (ok != true) return;
    final list = ids.text.split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
    await m.createRoom(name: name.text, invite: list, direct: name.text.isEmpty);
  }
}
