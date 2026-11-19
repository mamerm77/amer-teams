import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import '../services/quick_views.dart';
import 'chat_screen.dart';

/// Threads I follow, with how many replies came since I last opened each (docs/CHAT_EXTRAS.md).
class FollowedThreadsScreen extends StatefulWidget {
  const FollowedThreadsScreen({super.key});
  @override State<FollowedThreadsScreen> createState() => _S();
}
class _S extends State<FollowedThreadsScreen> {
  Future<List<(Room, Event, int)>>? f;
  @override void initState() { super.initState(); f = Threads.followedWithNew(context.read<MatrixService>().client); }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Followed threads')),
    body: FutureBuilder<List<(Room, Event, int)>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      if (s.data!.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('No followed threads. Open a thread and choose Follow this thread.', textAlign: TextAlign.center)));
      return ListView(children: [for (final (room, root, n) in s.data!) ListTile(
        leading: Badge(isLabelVisible: n > 0, label: Text('$n'), child: const Icon(Icons.forum_outlined)),
        title: Text(root.body, maxLines: 2, overflow: TextOverflow.ellipsis, style: n > 0 ? const TextStyle(fontWeight: FontWeight.w600) : null),
        subtitle: Text('${room.getLocalizedDisplayname()} · ${n == 0 ? 'no new replies' : '$n new repl${n == 1 ? 'y' : 'ies'}'}'),
        onTap: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, threadRootId: root.eventId)));
          setState(() => f = Threads.followedWithNew(context.read<MatrixService>().client)); })]);
    }));
}
