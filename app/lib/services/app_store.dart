import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'matrix_service.dart';

/// Storage for the built-in Teams-style apps (Lists, Forms, Praise, Updates, Notes, Planner, Goals, Bookings,
/// Communities…). Like a Teams tab, an app lives in a chat or channel: its items are end-to-end encrypted room
/// events of one type, keyed by item id; the newest event for an id wins and `deleted: true` removes it.
/// Everyone in the chat sees the same data; the server stores only ciphertext (docs/TEAMS_APPS.md).
const kAppItem = 'com.amerteams.app';

class StoreItem {
  StoreItem(this.e);
  final Event e;
  Map<String, Object?> get c => e.content;
  String get id => '${c['item_id']}';
  String get by => e.senderId;
  DateTime get at => e.originServerTs;
  Object? operator [](String k) => c[k];
  String s(String k) => '${c[k] ?? ''}';
}

class AppStore {
  /// Latest version of every live item of [app] (optionally of one [kind]) in [room], newest first.
  static Future<List<StoreItem>> items(Room room, String app, {String? kind, int history = 1500}) async {
    final tl = await room.getTimeline(limit: history);
    final seen = <String>{}, out = <StoreItem>[];
    for (final e in tl.events.where((e) => e.type == kAppItem && e.content['app'] == app && (kind == null || e.content['kind'] == kind))) {
      if (!seen.add('${e.content['item_id']}')) continue;
      if (e.content['deleted'] == true) continue;
      out.add(StoreItem(e));
    }
    tl.cancelSubscriptions();
    return out;
  }

  static String newId(String app) => '$app-${DateTime.now().microsecondsSinceEpoch}';

  static Future<void> save(Room room, String app, Map<String, Object?> item, {String? kind, String? summary}) =>
      room.sendEvent({...item, 'app': app, if (kind != null) 'kind': kind, 'item_id': item['item_id'] ?? newId(app),
        'body': summary ?? '[$app] ${item['title'] ?? item['name'] ?? ''}'}, type: kAppItem);

  static Future<void> delete(Room room, String app, String id) => room.sendEvent({'app': app, 'item_id': id, 'deleted': true, 'body': '[$app] removed'}, type: kAppItem);
}

/// Shell for an app page: picks the chat or channel it lives in (like adding a tab), then shows the app.
class AppHost extends StatefulWidget {
  const AppHost({super.key, required this.title, required this.icon, required this.about, required this.builder, this.room});
  final String title, about; final IconData icon; final Room? room;
  final Widget Function(BuildContext, Room) builder;
  @override State<AppHost> createState() => _AppHostState();
}
class _AppHostState extends State<AppHost> {
  Room? room;
  @override void initState() { super.initState(); room = widget.room; }
  @override Widget build(BuildContext c) {
    return Scaffold(
      appBar: AppBar(title: Row(children: [Icon(widget.icon), const SizedBox(width: 8), Flexible(child: Text(room == null ? widget.title : '${widget.title} · ${room!.getLocalizedDisplayname()}', overflow: TextOverflow.ellipsis))]),
        actions: [if (room != null) TextButton.icon(icon: const Icon(Icons.swap_horiz), label: const Text('Change chat'), onPressed: () => setState(() => room = null))]),
      body: room != null ? widget.builder(c, room!) : _pick(c));
  }
  Widget _pick(BuildContext c) {
    final rooms = c.read<MatrixService>().client.rooms.where((r) => r.membership == Membership.join && !r.isSpace).toList();
    return ListView(padding: const EdgeInsets.all(16), children: [
      Text(widget.about, style: Theme.of(c).textTheme.bodyMedium), const SizedBox(height: 12),
      Text('Open it in which chat or channel? Everyone there shares it, end-to-end encrypted.', style: Theme.of(c).textTheme.titleSmall),
      for (final r in rooms) ListTile(leading: const Icon(Icons.forum_outlined), title: Text(r.getLocalizedDisplayname()), onTap: () => setState(() => room = r)),
      if (rooms.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Join or start a chat first.')),
    ]);
  }
}

String nameIn(Room r, String userId) => r.unsafeGetUserFromMemoryOrFallback(userId).calcDisplayname();

Future<String?> askText(BuildContext c, String title, {String hint = '', String initial = '', int lines = 1}) async {
  final t = TextEditingController(text: initial);
  final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text(title),
    content: SizedBox(width: 420, child: TextField(controller: t, autofocus: true, minLines: lines, maxLines: lines == 1 ? 1 : 12, decoration: InputDecoration(hintText: hint))),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
  return ok == true && t.text.trim().isNotEmpty ? t.text.trim() : null;
}
