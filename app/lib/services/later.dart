import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';

/// Scheduled send and message reminders (docs/CHAT_EXTRAS.md). Both live on this device only: the server never holds
/// a scheduled message's text. They are kept in a file, so they survive restarts, and run while the app is open.
/// A message whose time passed while the app was closed is sent on the next start and marked "sent late".
class ScheduledSender extends ChangeNotifier {
  ScheduledSender._();
  static final instance = ScheduledSender._();
  Client? client;
  List<Map<String, dynamic>> items = [];          // {id, room, text, at, created}
  Timer? _t;

  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/scheduled.json');
  Future<void> start(Client c) async {
    client = c;
    try { final f = await _f(); if (await f.exists()) items = (jsonDecode(await f.readAsString()) as List).cast<Map<String, dynamic>>(); } catch (_) {}
    _t ??= Timer.periodic(const Duration(seconds: 15), (_) => _flush());
    _flush(); notifyListeners();
  }
  Future<void> _save() async { try { await (await _f()).writeAsString(jsonEncode(items)); } catch (_) {} notifyListeners(); }

  List<Map<String, dynamic>> forRoom(String roomId) => items.where((i) => i['room'] == roomId).toList()..sort((a, b) => '${a['at']}'.compareTo('${b['at']}'));
  void add(Room r, String text, DateTime at) {
    items.add({'id': 's${DateTime.now().microsecondsSinceEpoch}', 'room': r.id, 'text': text, 'at': at.toIso8601String(), 'created': DateTime.now().toIso8601String()});
    _save();
  }
  void edit(String id, {String? text, DateTime? at}) {
    final i = items.firstWhere((x) => x['id'] == id);
    if (text != null) i['text'] = text;
    if (at != null) i['at'] = at.toIso8601String();
    _save();
  }
  void cancel(String id) { items.removeWhere((x) => x['id'] == id); _save(); }

  bool _busy = false;
  Future<void> _flush() async {
    if (_busy || client == null) return; _busy = true;
    try {
      final now = DateTime.now();
      for (final i in items.where((x) => !DateTime.parse('${x['at']}').isAfter(now)).toList()) {
        final room = client!.getRoomById('${i['room']}');
        if (room == null || room.membership != Membership.join) { items.remove(i); continue; }
        final late = now.difference(DateTime.parse('${i['at']}')) > const Duration(minutes: 2);
        try {
          await room.sendEvent({'msgtype': 'm.text', 'body': '${i['text']}',
              'com.amerteams.scheduled': {'at': i['at'], if (late) 'late': true}}, txid: 'amer-${i['id']}');   // retry never duplicates
          items.remove(i);
        } catch (_) {/* offline: stays queued, tried again in 15 s */}
      }
      await _save();
    } finally { _busy = false; }
  }
}

/// "Remind me about this message": a reminder at the chosen time, shown as a banner with a link to the message.
class Reminders extends ChangeNotifier {
  Reminders._();
  static final instance = Reminders._();
  List<Map<String, dynamic>> items = [];          // {id, room, event, preview, at}
  final due = ValueNotifier<Map<String, dynamic>?>(null);
  Timer? _t;

  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/reminders.json');
  Future<void> start() async {
    try { final f = await _f(); if (await f.exists()) items = (jsonDecode(await f.readAsString()) as List).cast<Map<String, dynamic>>(); } catch (_) {}
    _t ??= Timer.periodic(const Duration(seconds: 20), (_) => _check());
    _check();
  }
  Future<void> _save() async { try { await (await _f()).writeAsString(jsonEncode(items)); } catch (_) {} notifyListeners(); }
  void add(String room, String event, String preview, DateTime at, {String? key}) {
    if (key != null && items.any((x) => x['key'] == key)) return;
    items.add({'id': 'r${DateTime.now().microsecondsSinceEpoch}', if (key != null) 'key': key, 'room': room, 'event': event, 'preview': preview.length > 140 ? '${preview.substring(0, 140)}…' : preview, 'at': at.toIso8601String()});
    _save();
  }
  void dismiss(String id) { items.removeWhere((x) => x['id'] == id); if (due.value?['id'] == id) due.value = null; _save(); _check(); }
  void snooze(String id, Duration d) { final i = items.firstWhere((x) => x['id'] == id); i['at'] = DateTime.now().add(d).toIso8601String(); due.value = null; _save(); }
  void _check() {
    if (due.value != null) return;
    final now = DateTime.now();
    final next = items.where((x) => !DateTime.parse('${x['at']}').isAfter(now)).firstOrNull;
    if (next != null) due.value = next;
  }
}
