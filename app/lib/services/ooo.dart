import 'availability.dart';
import 'dart:async';
import 'package:matrix/matrix.dart';

/// Out of office (docs/NOTIFICATIONS.md): dates, an automatic reply and a delegate, kept in account data so all
/// your devices share it. While it is on, your status says so, and a direct message gets the reply once a day
/// per person. The status returns automatically when the period ends.
class OutOfOffice {
  OutOfOffice._();
  static final instance = OutOfOffice._();
  static const type = 'com.amerteams.ooo';
  Client? c; Timer? _t; StreamSubscription? _sub;
  final _replied = <String>{};
  String? _statusSet;

  Map<String, dynamic>? get settings { final s = c?.accountData[type]?.content; return s == null || s.isEmpty ? null : Map<String, dynamic>.from(s); }
  bool get active {
    final s = settings; if (s == null || s['enabled'] != true) return false;
    final a = DateTime.tryParse('${s['start']}'), b = DateTime.tryParse('${s['end']}');
    final now = DateTime.now();
    return a != null && b != null && !now.isBefore(a) && now.isBefore(b.add(const Duration(days: 1)));
  }
  String statusText() {
    final s = settings!; final d = s['delegate'] as String?;
    return 'Out of office until ${'${s['end']}'.substring(0, 10)}${d != null && d.isNotEmpty ? ' · contact ${c!.getRoomById(c!.getDirectChatFromUserId(d) ?? '')?.getLocalizedDisplayname() ?? d}' : ''}';
  }

  void start(Client client) {
    if (c != null) return; c = client;
    _t = Timer.periodic(const Duration(minutes: 1), (_) => _apply()); _apply();
    _sub = client.onTimelineEvent.stream.listen(_onEvent);
  }
  void stop() { _t?.cancel(); _sub?.cancel(); c = null; }

  Future<void> save({required bool enabled, required DateTime start, required DateTime end, String message = '', String? delegate, String source = 'manual'}) async {
    await c!.setAccountData(c!.userID!, type, {'enabled': enabled, 'start': start.toIso8601String(), 'end': end.toIso8601String(), 'message': message, if (delegate != null) 'delegate': delegate, 'source': source});
    await _apply();
  }

  Future<void> _apply() async {
    if (c == null || c!.userID == null) return;
    try {
      if (active) {
        final t = statusText();
        if (_statusSet != t) { Availability.instance.overlay(Avail.ooo, t); _statusSet = t; }   // presence is decided in one place
      } else if (_statusSet != null) {                  // the period ended: back to normal
        Availability.instance.overlay(null); _statusSet = null;
      }
    } catch (_) {}
  }

  void _onEvent(Event e) {
    if (!active || e.type != EventTypes.Message || e.senderId == c!.userID || e.senderId.startsWith('@amer')) return;
    if (DateTime.now().difference(e.originServerTs) > const Duration(minutes: 5)) return;          // not for history loading
    final room = e.room; if (!room.isDirectChat) return;
    final day = DateTime.now().toIso8601String().substring(0, 10), key = '${room.id}|$day';
    if (!_replied.add(key)) return;
    final s = settings!; final d = s['delegate'] as String?;
    final msg = '${(s['message'] as String?)?.trim().isNotEmpty == true ? s['message'] : 'I am out of office until ${'${s['end']}'.substring(0, 10)}.'}'
        '${d != null && d.isNotEmpty ? ' For anything urgent, please contact $d.' : ''}';
    room.sendEvent({'msgtype': 'm.notice', 'body': '🌴 Automatic reply: $msg', 'com.amerteams.ooo': true}, txid: 'ooo-${room.id.hashCode}-$day');
  }
}
