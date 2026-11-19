import 'dart:async';
import 'dart:convert';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'canvas_crdt.dart';

const kCanvasCreate = 'com.amerteams.canvas.create', kCanvasUpdate = 'com.amerteams.canvas.update', kCanvasSnapshot = 'com.amerteams.canvas.snapshot';

/// One canvas: a CRDT document whose edits travel as encrypted room events (docs/CANVAS.md). Every member's device
/// merges them; there is no server merge and the server only sees ciphertext. Membership and encryption are the
/// room's own, so a removed member cannot decrypt later updates (Megolm keys rotate on membership change).
class CanvasDoc extends ChangeNotifier {
  CanvasDoc(this.room, this.id);
  final Room room; final String id;
  late CrdtDoc doc;
  bool loaded = false; String? error;
  final history = <Event>[];                  // update events, oldest first: the version history
  int _sinceSnapshot = 0;
  Map? _base; String _createdTitle = 'Untitled canvas';
  final _out = <Map<String, Object?>>[]; Timer? _flush;
  StreamSubscription? _sub;
  static const snapshotEvery = 200, maxSnapshotBytes = 5 * 1024 * 1024;

  String get title => (doc.get('doc', 'title') as String?) ?? _createdTitle;
  List<Map<String, Object?>> get blocks => doc.visible('blocks');
  String bid(Map b) => '${(b['id'] as List)[0]}@${(b['id'] as List)[1]}';
  String kind(Map b) => '${b['val']}';

  Future<void> load() async {
    doc = CrdtDoc(room.client.deviceID ?? 'device');
    try {
      final tl = await room.getTimeline();
      bool found() => tl.events.any((e) => (e.type == kCanvasCreate || e.type == kCanvasSnapshot) && e.content['canvas_id'] == id);
      for (var i = 0; i < 30 && !found() && tl.canRequestHistory; i++) { await tl.requestHistory(historyCount: 100); }
      final mine = tl.events.reversed.where((e) => e.content['canvas_id'] == id).toList();       // oldest first
      final snapAt = mine.lastIndexWhere((e) => e.type == kCanvasSnapshot);
      final created = mine.where((e) => e.type == kCanvasCreate).firstOrNull;
      if (created != null) _createdTitle = '${created.content['title'] ?? _createdTitle}';
      if (snapAt >= 0) { _base = mine[snapAt].content['state'] as Map; doc = CrdtDoc.fromSnapshot(doc.site, _base!); }
      for (final e in mine.skip(snapAt + 1)) { _take(e, notify: false); }
      history..clear()..addAll(mine.where((e) => e.type == kCanvasUpdate));
      tl.cancelSubscriptions();
    } catch (e) { error = 'Could not load the canvas: $e'; }
    _sub = room.client.onTimelineEvent.stream.where((e) => e.roomId == room.id && e.content['canvas_id'] == id && e.type == kCanvasUpdate).listen((e) {
      if (e.senderId == room.client.userID && e.content['device'] == room.client.deviceID) return;   // our own echo
      history.add(e); _take(e);
    });
    loaded = true; notifyListeners();
  }

  void _take(Event e, {bool notify = true}) {
    if (e.type != kCanvasUpdate) return;
    for (final op in (e.content['ops'] as List? ?? const [])) { doc.apply(Map<String, Object?>.from(jsonDecode(jsonEncode(op)) as Map)); }
    _sinceSnapshot++;
    if (notify) notifyListeners();
  }

  /// Local edit: applied at once, sent within 400 ms as one encrypted event.
  void push(Iterable<Map<String, Object?>> ops) {
    _out.addAll(ops); notifyListeners();
    _flush ??= Timer(const Duration(milliseconds: 400), send);
  }
  Future<void> send() async {
    _flush?.cancel(); _flush = null;
    if (_out.isEmpty) return;
    final ops = List.of(_out); _out.clear();
    try {
      await room.sendEvent({'canvas_id': id, 'device': room.client.deviceID, 'ops': ops, 'body': 'Canvas edit'}, type: kCanvasUpdate);
      if (++_sinceSnapshot >= snapshotEvery) await _snapshot();
    } catch (e) { _out.insertAll(0, ops); error = 'Not sent yet, will retry: $e'; notifyListeners(); _flush ??= Timer(const Duration(seconds: 5), send); }
  }
  Future<void> _snapshot() async {
    final state = doc.snapshot();
    if (utf8.encode(jsonEncode(state)).length > maxSnapshotBytes) { error = 'This canvas is over 5 MB; split it into two'; notifyListeners(); return; }
    await room.sendEvent({'canvas_id': id, 'state': state, 'body': 'Canvas snapshot'}, type: kCanvasSnapshot);
    _sinceSnapshot = 0;
  }

  // ---------- edits ----------
  void setTitle(String t) => push([doc.set('doc', 'title', t)]);
  void addBlock(String kind, {int? at, String text = '', Map<String, Object?> props = const {}}) {
    final ops = <Map<String, Object?>>[doc.insert('blocks', at ?? blocks.length, [kind])];
    final b = '${(ops.first['id'] as List)[0]}@${(ops.first['id'] as List)[1]}';
    if (text.isNotEmpty) ops.add(doc.insertText('$b:text', 0, text));
    for (final p in props.entries) { ops.add(doc.set(b, p.key, p.value)); }
    if (kind == 'table') {
      ops.add(doc.insert('$b:rows', 0, ['', ''])); ops.add(doc.insert('$b:cols', 0, ['', '']));
    }
    push(ops);
  }
  void removeBlock(int index) => push([doc.delete('blocks', index, 1)]);
  void editText(String b, String oldT, String newT) => push(doc.editText('$b:text', oldT, newT));
  void setProp(String b, String key, Object? v) => push([doc.set(b, key, v)]);
  String text(String b) => doc.text('$b:text');
  Object? prop(String b, String key) => doc.get(b, key);
  List<String> rows(String b) => [for (final e in doc.visible('$b:rows')) '${(e['id'] as List)[0]}@${(e['id'] as List)[1]}'];
  List<String> cols(String b) => [for (final e in doc.visible('$b:cols')) '${(e['id'] as List)[0]}@${(e['id'] as List)[1]}'];
  void addRow(String b) => push([doc.insert('$b:rows', rows(b).length, [''])]);
  void addCol(String b) => push([doc.insert('$b:cols', cols(b).length, [''])]);
  void removeRow(String b, int i) => push([doc.delete('$b:rows', i, 1)]);
  void setCell(String b, String r, String c, String v) => push([doc.set(b, 'cell:$r|$c', v)]);
  String cell(String b, String r, String c) => (doc.get(b, 'cell:$r|$c') as String?) ?? '';

  /// The canvas as it was after the update at [index] in [history] (read-only).
  CrdtDoc versionAt(int index) {
    final d = _base != null ? CrdtDoc.fromSnapshot('view', jsonDecode(jsonEncode(_base)) as Map) : CrdtDoc('view');
    for (final e in history.take(index + 1)) {
      for (final op in (e.content['ops'] as List? ?? const [])) { d.apply(Map<String, Object?>.from(jsonDecode(jsonEncode(op)) as Map)); }
    }
    return d;
  }

  @override void dispose() { send(); _sub?.cancel(); super.dispose(); }

  /// Canvases attached to a chat, newest first.
  static Future<List<Event>> list(Room room) async {
    final tl = await room.getTimeline();
    for (var i = 0; i < 5 && tl.canRequestHistory; i++) { await tl.requestHistory(historyCount: 100); }
    final out = tl.events.where((e) => e.type == kCanvasCreate).toList();
    tl.cancelSubscriptions();
    return out;
  }
  static Future<String> create(Room room, String title) async {
    final id = 'cv${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}';
    await room.sendEvent({'canvas_id': id, 'title': title, 'body': '📄 Canvas: $title'}, type: kCanvasCreate);
    return id;
  }
}
