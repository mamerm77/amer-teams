import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';

/// Messages that could not be handed to the server (no connection, server down, encryption keys unreachable).
/// Like WhatsApp: the message is never lost. It stays visible as "Not sent", is retried automatically every
/// 10 s, and the user can retry or delete it. Kept on the device, so it survives an app restart.
class OutboxItem {
  OutboxItem(this.id, this.text, this.at, {this.replyTo, this.error});
  // `id` is also the Matrix transaction ID: the server de-duplicates repeats of the same ID, so a retry can
  // never create a second copy even if an earlier attempt reached the server after all.
  final String id, text; final DateTime at; final String? replyTo; String? error;
  Map<String, Object?> toJson() => {'id': id, 'text': text, 'at': at.millisecondsSinceEpoch, 'replyTo': replyTo};
  static OutboxItem fromJson(Map<String, dynamic> j) =>
      OutboxItem(j['id'] as String, j['text'] as String, DateTime.fromMillisecondsSinceEpoch(j['at'] as int), replyTo: j['replyTo'] as String?);
}

class Outbox extends ChangeNotifier {
  Outbox(this.room);
  final Room room;
  final items = <OutboxItem>[];
  Timer? _retry; bool _busy = false;

  Future<File> _file() async {
    final safe = room.id.replaceAll(RegExp(r'[^A-Za-z0-9]'), '_');
    return File('${(await getApplicationSupportDirectory()).path}/outbox_$safe.json');
  }
  Future<void> load() async {
    try { final f = await _file(); if (await f.exists()) items.addAll((jsonDecode(await f.readAsString()) as List).map((j) => OutboxItem.fromJson(j as Map<String, dynamic>))); } catch (_) {}
    if (items.isNotEmpty) { notifyListeners(); _schedule(); }
  }
  Future<void> _save() async { try { await (await _file()).writeAsString(jsonEncode(items.map((i) => i.toJson()).toList())); } catch (_) {} }

  /// Sends now; on failure keeps the message and schedules retries. Returns true if the server accepted it.
  Future<bool> send(String text, {Event? replyTo}) async {
    final txid = 'amer${DateTime.now().microsecondsSinceEpoch}';
    try {
      await room.sendTextEvent(text, inReplyTo: replyTo, txid: txid).timeout(const Duration(seconds: 20));
      return true;
    } catch (e) {
      items.add(OutboxItem(txid, text, DateTime.now(), replyTo: replyTo?.eventId, error: '$e'));
      await _save(); notifyListeners(); _schedule();
      return false;
    }
  }

  Future<void> retry(OutboxItem i) async {
    if (_busy) return; _busy = true;
    try {
      Event? reply; if (i.replyTo != null) { try { reply = await room.getEventById(i.replyTo!); } catch (_) {} }
      await room.sendTextEvent(i.text, inReplyTo: reply, txid: i.id).timeout(const Duration(seconds: 20));
      items.remove(i); await _save();
    } catch (e) { i.error = '$e'; }
    finally { _busy = false; notifyListeners(); if (items.isEmpty) { _retry?.cancel(); _retry = null; } }
  }
  Future<void> delete(OutboxItem i) async { items.remove(i); await _save(); notifyListeners(); }

  void _schedule() {
    _retry ??= Timer.periodic(const Duration(seconds: 10), (_) async { for (final i in List.of(items)) { await retry(i); } });
  }
  @override void dispose() { _retry?.cancel(); super.dispose(); }
}
