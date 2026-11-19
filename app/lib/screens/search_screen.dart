import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import '../services/search_index.dart';
import 'chat_screen.dart';

/// Search everywhere: messages and files (on this device's encrypted-chat index), and people (directory).
class SearchScreen extends StatefulWidget {
  const SearchScreen({super.key});
  @override State<SearchScreen> createState() => _S();
}
class _S extends State<SearchScreen> {
  final q = TextEditingController(); String kind = 'all', when = 'any'; String? room, person;
  List<Map<String, Object?>> hits = []; List<Profile> people = []; bool busy = false;
  Client get cl => context.read<MatrixService>().client;

  Future<void> _run() async {
    setState(() => busy = true);
    final since = switch (when) { '7' => DateTime.now().subtract(const Duration(days: 7)), '30' => DateTime.now().subtract(const Duration(days: 30)), _ => null };
    final h = await SearchIndex.instance.search(q.text, roomId: room, sender: person, kind: kind == 'all' ? null : kind, since: since);
    List<Profile> p = [];
    if (q.text.trim().length >= 2 && kind == 'all') { try { p = (await cl.searchUserDirectory(q.text.trim(), limit: 8)).results; } catch (_) {} }
    if (mounted) setState(() { hits = h; people = p; busy = false; });
  }

  @override Widget build(BuildContext c) {
    final rooms = cl.rooms.where((r) => r.membership == Membership.join && !r.isSpace).toList();
    final senders = {for (final r in rooms.where((r) => r.isDirectChat && r.directChatMatrixID != null)) r.directChatMatrixID!: r.getLocalizedDisplayname()};
    Widget chip(String k, String l) => Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(l), selected: kind == k, onSelected: (_) { setState(() => kind = k); _run(); }));
    return Scaffold(
      appBar: AppBar(title: TextField(controller: q, autofocus: true, textInputAction: TextInputAction.search, onSubmitted: (_) => _run(), onChanged: (v) { if (v.length >= 2) _run(); },
        decoration: const InputDecoration(hintText: 'Search messages, files and people', border: InputBorder.none))),
      body: Column(children: [
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), child: Row(children: [
          chip('all', 'All'), chip('files', 'Files'), chip('image', 'Photos'), chip('voice', 'Voice'),
          DropdownButton<String?>(value: room, hint: const Text('Any chat'), underline: const SizedBox(), items: [const DropdownMenuItem(value: null, child: Text('Any chat')),
            for (final r in rooms) DropdownMenuItem(value: r.id, child: Text(r.getLocalizedDisplayname(), overflow: TextOverflow.ellipsis))], onChanged: (v) { setState(() => room = v); _run(); }),
          const SizedBox(width: 8),
          DropdownButton<String?>(value: person, hint: const Text('From anyone'), underline: const SizedBox(), items: [const DropdownMenuItem(value: null, child: Text('From anyone')),
            DropdownMenuItem(value: cl.userID, child: Text(L.t(context, 'From me'))), for (final e in senders.entries) DropdownMenuItem(value: e.key, child: Text(e.value))], onChanged: (v) { setState(() => person = v); _run(); }),
          const SizedBox(width: 8),
          DropdownButton<String>(value: when, underline: const SizedBox(), items: const [DropdownMenuItem(value: 'any', child: Text('Any time')), DropdownMenuItem(value: '7', child: Text('Last 7 days')),
            DropdownMenuItem(value: '30', child: Text('Last 30 days'))], onChanged: (v) { setState(() => when = v!); _run(); }),
        ])),
        if (busy) const LinearProgressIndicator(),
        Expanded(child: ListView(children: [
          if (people.isNotEmpty) ...[const ListTile(dense: true, title: Text('People')),
            for (final p in people) ListTile(leading: CircleAvatar(child: Text((p.displayName ?? p.userId).substring(0, 1).toUpperCase())), title: Text(p.displayName ?? p.userId), subtitle: Text(p.userId),
              onTap: () async { final id = await cl.startDirectChat(p.userId, enableEncryption: true); if (c.mounted) Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: id))); })],
          if (hits.isNotEmpty) ListTile(dense: true, title: Text('Messages and files (${hits.length})')),
          for (final h in hits) () {
            final r = cl.getRoomById('${h['room_id']}'); final ts = DateTime.fromMillisecondsSinceEpoch(int.parse('${h['ts']}'));
            final isFile = h['kind'] != 'text';
            return ListTile(leading: Icon(isFile ? Icons.insert_drive_file_outlined : Icons.chat_bubble_outline),
              title: Text(isFile ? '${h['file_name']}' : '${h['body']}', maxLines: 2, overflow: TextOverflow.ellipsis),
              subtitle: Text('${h['sender_name']} · ${r?.getLocalizedDisplayname() ?? ''} · ${DateFormat('d MMM yyyy HH:mm').format(ts)}'),
              onTap: r == null ? null : () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: r.id))));
          }(),
          if (!busy && hits.isEmpty && people.isEmpty && q.text.length >= 2) const Padding(padding: EdgeInsets.all(24), child: Center(child: Text('Nothing found'))),
          Padding(padding: const EdgeInsets.all(16), child: Text(
            'Messages are searched on this device: the server cannot read them, so it never builds an index.${SearchIndex.instance.backfilling ? ' Still indexing older messages…' : ''}',
            style: TextStyle(fontSize: 12, color: Theme.of(c).colorScheme.outline))),
        ])),
      ]));
  }
}
