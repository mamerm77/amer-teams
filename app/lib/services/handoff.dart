import 'dart:async';
import 'package:matrix/matrix.dart';

/// Multi-device handoff (docs/HANDOFF.md). While you are in a meeting, your account data says which device has
/// it, so your other signed-in devices offer "Move it here". The media server allows one connection per person
/// in a call, so joining from the new device hands the call over: the old device is disconnected and says so.
/// The call key reaches the new device the normal way (it is wrapped to each of your verified devices).
class Handoff {
  static const type = 'com.amerteams.active_call';
  static Future<void> announce(Client c, {required String roomId, String? callId, required bool meeting}) async {
    try { await c.setAccountData(c.userID!, type, {'room_id': roomId, if (callId != null) 'call_id': callId, 'meeting': meeting,
      'device_id': c.deviceID, 'device_name': c.deviceName ?? c.deviceID, 'since': DateTime.now().millisecondsSinceEpoch}); } catch (_) {}
  }
  static Future<void> clear(Client c) async {
    final cur = c.accountData[type]?.content;
    if (cur != null && cur['device_id'] == c.deviceID) { try { await c.setAccountData(c.userID!, type, {}); } catch (_) {} }
  }
  /// The call running on another of my devices, if any (stale after six hours).
  static Map<String, dynamic>? elsewhere(Client c) {
    final cur = c.accountData[type]?.content;
    if (cur == null || cur['room_id'] == null || cur['device_id'] == c.deviceID) return null;
    final since = cur['since'] as int? ?? 0;
    if (DateTime.now().millisecondsSinceEpoch - since > 6 * 3600 * 1000) return null;
    return Map<String, dynamic>.from(cur);
  }
}
