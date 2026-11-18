import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

class TeamsScreen extends StatelessWidget {
  const TeamsScreen({super.key});
  @override
  Widget build(BuildContext c) {
    final m = c.watch<MatrixService>();
    return Scaffold(
      appBar: AppBar(title: const Text('Teams')),
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.group_add), label: const Text('New team'),
        onPressed: () async {
          final r = await _ask(c, 'New team', ['Team name', 'Invite (Matrix IDs, comma-separated)']);
          if (r != null) await m.createTeam(r[0], r[1].split(',').map((s) => s.trim()).where((s) => s.isNotEmpty).toList());
        }),
      body: m.teams.isEmpty ? const Center(child: Text('No teams yet. Create one to add encrypted channels.'))
        : ListView(children: [for (final t in m.teams) ExpansionTile(initiallyExpanded: true,
            leading: CircleAvatar(child: Text(t.getLocalizedDisplayname().characters.first)),
            title: Text(t.getLocalizedDisplayname()),
            children: [
              for (final ch in m.channelsOf(t)) ListTile(contentPadding: const EdgeInsets.only(left: 72, right: 16),
                leading: const Icon(Icons.tag), title: Text(ch.getLocalizedDisplayname()),
                trailing: const Icon(Icons.lock, size: 14),
                onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: ch.id)))),
              ListTile(contentPadding: const EdgeInsets.only(left: 72), leading: const Icon(Icons.add), title: const Text('Add channel'),
                onTap: () async { final r = await _ask(c, 'New channel', ['Channel name']); if (r != null) await m.createChannel(t.id, r[0]); }),
            ])]),
    );
  }
}

Future<List<String>?> _ask(BuildContext c, String title, List<String> labels) async {
  final ctl = [for (final _ in labels) TextEditingController()];
  final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text(title),
    content: Column(mainAxisSize: MainAxisSize.min, children: [for (var i = 0; i < labels.length; i++) TextField(controller: ctl[i], decoration: InputDecoration(labelText: labels[i]))]),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create'))]));
  return ok == true && ctl.first.text.trim().isNotEmpty ? ctl.map((e) => e.text.trim()).toList() : null;
}
