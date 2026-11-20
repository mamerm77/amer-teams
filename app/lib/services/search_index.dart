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

  Client? _owner; Future<void>? _opening;
  Future<void> start(Client client) { _owner = client; if (_db != null && c == client) return Future.value(); return _opening ??= _open(client).whenComplete(() => _opening = null); }
  Future<void> _open(Client client) async {
    if (_db != null) stop(); c = client;
    final dir = await getApplicationSupportDirectory();
    final factory = (Platform.isAndroid || Platform.isIOS) ? sqflite.databaseFactory : databaseFactoryFfi;
    _db = await factory.openDatabase('${dir.path}/search_${client.userID.hashCode}.sqlite', options: OpenDatabaseOptions(version: 1, onCreate: (db, _) async {
      await db.execute('CREATE VIRTUAL TABLE msgs USING fts4(body, sender_name, file_name, event_id, room_id, sender, ts, kind, tokenize=unicode61)');
    }));
    _sub = client.onTimelineEvent.stream.listen((e) { _index(e); });
    unawaited(_backfill());
  }
  /// Closes the index. A screen being disposed passes its client: if another screen has already (re)started the
  /// index for the same signed-in client, it stays open (the old screen's dispose runs after the new one's start).
  void stop([Client? client]) { if (client != null && identical(client, _owner) && client.isLogged()) return; _sub?.cancel(); _db?.close(); _db = null; c = null; }

  Future<void> _index(Event e) async { final db = _db; if (db != null) await _indexIn(db, e); }
  Future<void> _indexIn(DatabaseExecutor db, Event e) async {
    if (e.roomId == null) return;
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
    if (backfilling) return; backfilling = true;
    try {
      final rooms = c?.rooms.where((r) => r.membership == Membership.join && !r.isSpace).toList() ?? const <Room>[];
      // all chats at once; each chat's messages written in one batch (was: one chat and one row at a time)
      await Future.wait(rooms.map((r) async {
        try {
          final tl = await r.getTimeline(limit: 300);
          final evs = tl.events.where((e) => e.type == EventTypes.Message || e.type == EventTypes.Redaction).toList();
          tl.cancelSubscriptions();
          final db = _db; if (db == null) return;
          await db.transaction((txn) async { for (final e in evs) { await _indexIn(txn, e); } });
        } catch (_) {}
      }));
    } finally { backfilling = false; }
  }

  /// When I sent messages (times only), for wellbeing signals on this device (docs/WELLBEING.md).
  Future<List<DateTime>> sentTimes(String me, DateTime since) async {
    final db = _db; if (db == null) return [];
    final rows = await db.query('msgs', columns: ['ts'], where: 'sender = ? AND CAST(ts AS INTEGER) >= ?', whereArgs: [me, since.millisecondsSinceEpoch]);
    return [for (final r in rows) DateTime.fromMillisecondsSinceEpoch(int.parse('${r['ts']}'))];
  }

  /// Words I use most in what I wrote (last 90 days), for expertise suggestions on this device (docs/EXPERTISE.md).
  Future<List<String>> myTopTerms(String me, {int n = 15}) async {
    final db = _db; if (db == null) return [];
    final rows = await db.query('msgs', columns: ['body'], where: 'sender = ? AND kind = ? AND CAST(ts AS INTEGER) >= ?', whereArgs: [me, 'text', DateTime.now().subtract(const Duration(days: 90)).millisecondsSinceEpoch], limit: 3000);
    final count = <String, int>{};
    for (final r in rows) {
      for (final w in '${r['body']}'.toLowerCase().split(RegExp(r'[^\p{L}\p{N}+#/-]+', unicode: true))) {
        if (w.length < 4 || _stop.contains(w) || RegExp(r'^\d+$').hasMatch(w)) continue;
        count[w] = (count[w] ?? 0) + 1;
      }
    }
    final top = count.entries.where((e) => e.value >= 3).toList()..sort((a, b) => b.value.compareTo(a.value));
    return top.take(n).map((e) => e.key).toList();
  }
  static const _stop = {'that', 'this', 'with', 'have', 'will', 'from', 'they', 'what', 'when', 'your', 'there', 'about', 'would', 'could', 'should', 'thanks', 'thank',
    'please', 'just', 'like', 'also', 'been', 'were', 'their', 'them', 'then', 'than', 'which', 'into', 'some', 'more', 'only', 'very', 'here', 'okay', 'sure', 'today',
    'tomorrow', 'meeting', 'call', 'need', 'know', 'think', 'good', 'great', 'send', 'sent', 'done', 'let\'s', 'yes', 'noted', 'regards', 'hello', 'dear',
    'هذا', 'هذه', 'على', 'إلى', 'التي', 'الذي', 'شكرا', 'شكراً', 'ممكن', 'لكن', 'بعد', 'قبل', 'كان', 'يكون', 'اليوم'};

  /// Full-text search with optional filters. Words are matched as prefixes ("vend" finds "vendor").
  Future<List<Map<String, Object?>>> search(String q, {String? roomId, String? sender, String? kind, DateTime? since}) async {
    if (_db == null && _owner != null && _owner!.isLogged()) await start(_owner!);
    var r = await _query(q, roomId: roomId, sender: sender, kind: kind, since: since);
    // Messages that arrived still encrypted are indexed once decrypted: on a miss, catch up from the decrypted
    // timelines and ask again (bounded: the recent history of each chat).
    if (r.isEmpty && q.trim().isNotEmpty) {
      await _backfill().timeout(const Duration(seconds: 12), onTimeout: () {});
      r = await _query(q, roomId: roomId, sender: sender, kind: kind, since: since);
    }
    return r;
  }

  Future<List<Map<String, Object?>>> _query(String q, {String? roomId, String? sender, String? kind, DateTime? since}) async {
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
