import 'dart:async';
import 'dart:convert';
import 'package:crypto/crypto.dart';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart';
import 'api_service.dart';
import 'matrix_service.dart';

/// The same hash the server computes (Python json.dumps(sort_keys=True, ensure_ascii=False) then SHA-256), taken over
/// what this app is about to send. The server refuses execution if it differs from what the owner approved.
String payloadHash(Map<String, Object?> p) {
  String enc(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      return '{${keys.map((k) => '${jsonEncode(k)}: ${enc(v[k])}').join(', ')}}';
    }
    if (v is List) return '[${v.map(enc).join(', ')}]';
    return jsonEncode(v);
  }
  return sha256.convert(utf8.encode(enc(p))).toString();
}

/// Approvals for the owner's personal agents (docs/PERSONAL_AGENTS.md). Shows what waits for a decision, and
/// carries out approved actions here, on the owner's device: sends are encrypted and made as the owner.
class GlassBox extends ChangeNotifier {
  GlassBox._();
  static final instance = GlassBox._();
  ApiService? api; MatrixService? m; Timer? _t;
  List<Map<String, dynamic>> awaiting = [];
  final _doing = <String>{};
  String lastError = '';

  void start(MatrixService ms, ApiService a) {
    if (_t != null) return;
    m = ms; api = a;
    poll(); _t = Timer.periodic(const Duration(seconds: 10), (_) => poll());
  }
  void stop() { _t?.cancel(); _t = null; }

  Future<void> poll() async {
    try {
      final all = (await api!.approvals()).cast<Map<String, dynamic>>();
      awaiting = all.where((a) => a['status'] == 'awaiting').toList();
      for (final a in all.where((a) => a['status'] == 'executing')) { unawaited(_execute(a)); }
      notifyListeners();
    } catch (_) {/* signed out or offline: try again next tick */}
  }

  Future<void> decide(String id, String decision, {Map<String, Object?>? edited, String reason = ''}) async {
    await api!.decideApproval(id, decision, edited: edited, reason: reason);
    await poll();
  }

  Future<void> _execute(Map<String, dynamic> a) async {
    final id = a['id'] as String;
    if (!_doing.add(id)) return;
    try {
      final p = Map<String, Object?>.from(a['payload'] as Map);
      final room = m!.client.getRoomById('${p['room_id']}');
      if (room == null || room.membership != Membership.join) {
        await api!.approvalDone(id, payloadHash(p), ok: false, result: 'You are not in that chat any more');
        return;
      }
      String result;
      switch (a['tool']) {
        case 'send_message':
          final ev = await room.sendTextEvent('${p['text']}', txid: 'amer-$id');      // same id on retry: never sent twice
          result = ev == null ? 'not sent' : 'sent';
        case 'schedule_meeting':
          final start = DateTime.tryParse('${p['start']}');
          if (start == null) throw Exception('The start time is not a date');
          await m!.sendMeeting(room, title: '${p['title']}', start: start, minutes: (p['duration_min'] as num).toInt(), txid: 'amer-$id');
          result = 'booked';
        default:
          throw Exception('Unknown action ${a['tool']}');
      }
      await api!.approvalDone(id, payloadHash(p), ok: result != 'not sent', result: result);   // hash of exactly what was sent
    } catch (e) {
      lastError = '$e';
      try { await api!.approvalDone(id, payloadHash(Map<String, Object?>.from(a['payload'] as Map)), ok: false, result: '$e'); } catch (_) {}
    } finally { _doing.remove(id); notifyListeners(); }
  }
}
