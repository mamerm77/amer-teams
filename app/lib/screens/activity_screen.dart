import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/chat_extras.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';
import 'saved_screen.dart';
import 'catch_up_screen.dart';
import 'tasks_screen.dart';
import '../services/feature_flags.dart';
import '../services/locale.dart';

/// Activity feed (as in Teams): mentions, replies to you, reactions to your messages, missed calls.
class ActivityScreen extends StatefulWidget { const ActivityScreen({super.key}); @override State<ActivityScreen> createState() => _S(); }
class _S extends State<ActivityScreen> {
  Future<List<Activity>>? f; String filter = 'all';
  @override void initState() { super.initState(); _load(); }
  void _load() => setState(() { f = ActivityService(context.read<MatrixService>()).load(); });
  static const icons = {'mention': Icons.alternate_email, 'reply': Icons.reply, 'reaction': Icons.emoji_emotions_outlined, 'missed_call': Icons.call_missed};
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(t(c, 'Activity')), actions: [
      if (Flags.instance.on('catch_up')) TextButton.icon(icon: const Icon(Icons.auto_awesome), label: Text(t(c, 'Catch me up')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const CatchUpScreen()))),
      if (Flags.instance.on('decisions')) IconButton(tooltip: 'My tasks', icon: const Icon(Icons.task_alt), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const TasksScreen()))),
      if (Flags.instance.on('decisions')) IconButton(tooltip: 'My decisions', icon: const Icon(Icons.gavel), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const MyDecisionsScreen()))),
      IconButton(tooltip: 'Saved messages', icon: const Icon(Icons.bookmark_outline), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SavedScreen()))),
      IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
    body: Column(children: [
      SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), child: Row(children: [
        for (final (k, l) in [('all', 'All'), ('mention', '@Mentions'), ('reply', 'Replies'), ('reaction', 'Reactions'), ('missed_call', 'Missed calls')])
          Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(l), selected: filter == k, onSelected: (_) => setState(() => filter = k)))])),
      Expanded(child: FutureBuilder<List<Activity>>(future: f, builder: (_, s) {
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final items = s.data!.where((a) => filter == 'all' || a.kind == filter).toList();
        if (items.isEmpty) return const Center(child: Text('Nothing new'));
        return RefreshIndicator(onRefresh: () async => _load(), child: ListView(children: [for (final a in items) ListTile(
          leading: CircleAvatar(child: Icon(icons[a.kind])),
          title: Text(a.text, maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text('${a.room.getLocalizedDisplayname()} · ${DateFormat('d MMM, HH:mm').format(a.event.originServerTs)}'),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: a.room.id))))]));
      })),
    ]));
}
