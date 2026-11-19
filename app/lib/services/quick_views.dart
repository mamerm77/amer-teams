import 'dart:convert';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';

/// Drafts: unsent composer text per chat, kept on this device only.
class Drafts {
  Drafts._();
  static final instance = Drafts._();
  Map<String, String> items = {};
  bool _loaded = false;
  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/drafts.json');
  Future<void> load() async {
    if (_loaded) return; _loaded = true;
    try { final f = await _f(); if (await f.exists()) items = Map<String, String>.from(jsonDecode(await f.readAsString()) as Map); } catch (_) {}
  }
  Future<void> set(String room, String text) async {
    if (text.trim().isEmpty) { items.remove(room); } else { items[room] = text; }
    try { await (await _f()).writeAsString(jsonEncode(items)); } catch (_) {}
  }
  String? of(String room) => items[room];
}

/// Followed and muted threads, in the user's account data (ids and times only, no content).
class Threads {
  static const type = 'com.amerteams.threads';
  static Map<String, dynamic> _all(Client c) => Map<String, dynamic>.from(c.accountData[type]?.content ?? const {});
  static String? mode(Client c, String room, String thread) => ((_all(c)[room] as Map?)?[thread] as Map?)?['mode'] as String?;
  static Future<void> setMode(Client c, String room, String thread, String? mode) async {
    final all = _all(c); final r = Map<String, dynamic>.from((all[room] as Map?) ?? {});
    if (mode == null) { r.remove(thread); } else { r[thread] = {...Map<String, dynamic>.from((r[thread] as Map?) ?? {}), 'mode': mode, 'seen': DateTime.now().millisecondsSinceEpoch}; }
    all[room] = r;
    await c.setAccountData(c.userID!, type, all);
  }
  static Future<void> markSeen(Client c, String room, String thread) async {
    if (mode(c, room, thread) != 'follow') return;
    await setMode(c, room, thread, 'follow');
  }
  /// Followed threads with replies newer than when I last opened them.
  static Future<List<(Room, Event, int)>> followedWithNew(Client c) async {
    final out = <(Room, Event, int)>[];
    for (final re in _all(c).entries) {
      final room = c.getRoomById(re.key); if (room == null) continue;
      final follows = (re.value as Map).entries.where((t) => (t.value as Map)['mode'] == 'follow').toList();
      if (follows.isEmpty) continue;
      try {
        final tl = await room.getTimeline(limit: 300);
        for (final t in follows) {
          final seen = ((t.value as Map)['seen'] as num?)?.toInt() ?? 0;
          final root = tl.events.where((e) => e.eventId == t.key).firstOrNull ?? await room.getEventById('${t.key}');
          final n = tl.events.where((e) => e.relationshipType == RelationshipTypes.thread && e.relationshipEventId == t.key && e.originServerTs.millisecondsSinceEpoch > seen && e.senderId != c.userID).length;
          if (root != null) out.add((room, root, n));
        }
        tl.cancelSubscriptions();
      } catch (_) {}
    }
    out.sort((a, b) => b.$3.compareTo(a.$3));
    return out;
  }
}
