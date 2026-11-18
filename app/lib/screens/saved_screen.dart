import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/chat_extras.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

/// Saved (starred) messages from every chat.
class SavedScreen extends StatefulWidget { const SavedScreen({super.key}); @override State<SavedScreen> createState() => _S(); }
class _S extends State<SavedScreen> {
  Future<List<Event>>? f;
  @override void initState() { super.initState(); f = StarService(context.read<MatrixService>()).load(); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Saved messages')),
    body: FutureBuilder<List<Event>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      if (s.data!.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Long-press any message and choose Save to keep it here.', textAlign: TextAlign.center)));
      return ListView(children: [for (final e in s.data!) ListTile(leading: const Icon(Icons.bookmark),
        title: Text(plainMentions(e.body), maxLines: 3, overflow: TextOverflow.ellipsis),
        subtitle: Text('${e.senderFromMemoryOrFallback.calcDisplayname()} · ${e.room.getLocalizedDisplayname()} · ${DateFormat('d MMM').format(e.originServerTs)}'),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: e.room.id))))]);
    }));
}
