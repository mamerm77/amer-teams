import 'dart:async';
import 'dart:io';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

/// Search everywhere (docs/SEARCH.md). Messages are end-to-end encrypted, so the server cannot search them and never
/// builds a content index: this device indexes the messages it has decrypted, in a local SQLite full-text index
/// (FTS4) inside the app's own storage. New messages are added as they arrive; on start, recent history of each
/// chat is backfilled. Redactions remove the message from the index.
class SearchIndex {
  SearchIndex._();
  static final instance = SearchIndex._();
  Database? _db; Client? c; StreamSubscription? _sub;
  bool backfilling = false; int indexed = 0;

  Future<void> start(Client client) async {
    if (_db != null) return; c = client;
    final dir = await getApplicationSupportDirectory();
    final factory = (Platform.isAndroid || Platform.isIOS) ? sqflite.databaseFactory : databaseFactoryFfi;
    _db = await factory.openDatabase('${dir.path}/search_${client.userID.hashCode}.sqlite', options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
      await db.execute('CREATE VIRTUAL TABLE msgs USING fts4(body, sender_name, file_name, event_id, room_id, sender, ts, kind, tokenize=unicode61)');
    }));
    _sub = client.onTimelineEvent.stream.listen((e) { _index(e); });
    unawaited(_backfill());
  }
  void stop() { _sub?.cancel(); _db?.close(); _db = null; c = null; }

  Future<void> _index(Event e) async {
    final db = _db; if (db == null || e.roomId == null) return;
    if (e.type == EventTypes.Redaction && e.redacts != null) { await db.delete('msgs', where: 'event_id = ?', whereArgs: [e.redacts]); return; }
    if (e.type != EventTypes.Message || e.redacted) return;
    final kind = switch (e.messageType) { MessageTypes.Image => 'image', MessageTypes.File => 'file', MessageTypes.Video => 'video', MessageTypes.Audio => 'voice', _ => 'text' };
    await db.delete('msgs', where: 'event_id = ?', whereArgs: [e.eventId]);           // edits and re-delivery: keep one row
    await db.insert('msgs', {'body': kind == 'text' ? e.body : '', 'sender_name': e.senderFromMemoryOrFallback.calcDisplayname(),
      'file_name': kind == 'text' ? '' : e.body, 'event_id': e.eventId, 'room_id': e.roomId, 'sender': e.senderId,
      'ts': '${e.originServerTs.millisecondsSinceEpoch}', 'kind': kind});
    indexed++;
  }

  Future<void> _backfill() async {
    backfilling = true;
    for (final r in c?.rooms.where((r) => r.membership == Membership.join).toList() ?? const <Room>[]) {
      try {
        final tl = await r.getTimeline(limit: 300);
        for (final e in tl.events) { await _index(e); }
        tl.cancelSubscriptions();
      } catch (_) {}
      if (_db == null) break;
    }
    backfilling = false;
  }

  /// When I sent messages (times only), for wellbeing signals on this device (docs/WELLBEING.md).
  Future<List<DateTime>> sentTimes(String me, DateTime since) async {
    final db = _db; if (db == null) return [];
    final rows = await db.query('msgs', columns: ['ts'], where: 'sender = ? AND CAST(ts AS INTEGER) >= ?', whereArgs: [me, since.millisecondsSinceEpoch]);
    return [for (final r in rows) DateTime.fromMillisecondsSinceEpoch(int.parse('${r['ts']}'))];
  }

  /// Full-text search with optional filters. Words are matched as prefixes ("vend" finds "vendor").
  Future<List<Map<String, Object?>>> search(String q, {String? roomId, String? sender, String? kind, DateTime? since}) async {
    final db = _db; if (db == null) return [];
    final words = q.trim().split(RegExp(r'\s+')).where((w) => w.isNotEmpty).map((w) => '${w.replaceAll(RegExp(r'["*]'), '')}*').join(' ');
    final where = <String>[], args = <Object?>[];
    if (words.isNotEmpty) { where.add('msgs MATCH ?'); args.add(words); }
    if (roomId != null) { where.add('room_id = ?'); args.add(roomId); }
    if (sender != null) { where.add('sender = ?'); args.add(sender); }
    if (kind != null) { where.add(kind == 'files' ? "kind != 'text'" : 'kind = ?'); if (kind != 'files') args.add(kind); }
    if (since != null) { where.add('CAST(ts AS INTEGER) >= ?'); args.add(since.millisecondsSinceEpoch); }
    if (where.isEmpty) return [];
    return db.query('msgs', where: where.join(' AND '), whereArgs: args, orderBy: 'CAST(ts AS INTEGER) DESC', limit: 200);
  }
}
