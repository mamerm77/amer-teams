import 'package:matrix/matrix.dart';
import 'dart:io';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';

/// Catch-up digest (docs/CATCH_UP.md). Messages are read and decrypted here on the device; only the unread text
/// of rooms the user is in goes to the AI engine, and only when the user asks. Rooms labelled Confidential or
/// Restricted are sent with name and count only, never their text.
class CatchUp {
  CatchUp(this.client, this.api);
  final Client client; final ApiService api;
  static const awayAfter = Duration(hours: 4);
  static const _withheld = {'confidential', 'restricted'};

  static Future<File> _stamp() async => File('${(await getApplicationSupportDirectory()).path}/last_active_ms');
  /// True when the user has been away for 4 hours or more since the app was last in use. Records now as active.
  static Future<bool> cameBackAfterAway() async {
    int? last;
    try { final f = await _stamp(); if (await f.exists()) last = int.tryParse((await f.readAsString()).trim()); } catch (_) {}
    await markActive();
    return last != null && DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch(last)) >= awayAfter;
  }
  static Future<void> markActive() async {
    try { await (await _stamp()).writeAsString('${DateTime.now().millisecondsSinceEpoch}'); } catch (_) {}
  }

  static String kindOf(Room r) => r.isDirectChat ? 'direct' : r.spaceParents.isNotEmpty ? 'channel'
      : (r.getState('com.amerteams.meeting') != null ? 'meeting' : 'group');

  bool _mentionsMe(Event e) {
    final ids = (e.content['m.mentions'] as Map?)?['user_ids'];
    if (ids is List && ids.contains(client.userID)) return true;
    final me = client.userID!, local = me.substring(1).split(':').first.toLowerCase();
    final body = e.body.toLowerCase();
    return body.contains(me.toLowerCase()) || body.contains('@$local');
  }

  /// Unread messages per room since the read marker (newest 60), decrypted on this device.
  Future<List<Map<String, Object?>>> collect() async {
    final out = <Map<String, Object?>>[];
    for (final r in client.rooms.where((r) => r.membership == Membership.join && (r.notificationCount > 0 || r.markedUnread))) {
      final label = r.getState('com.amerteams.sensitivity')?.content['label'] as String?;
      final withheld = label != null && _withheld.contains(label.toLowerCase());
      final msgs = <Map<String, Object?>>[];
      if (!withheld) {
        try {
          final t = await r.getTimeline(limit: 60);
          for (final e in t.events) {                                   // newest first
            if (e.eventId == r.fullyRead || e.eventId == r.receiptState.global.ownPublic?.eventId) break;
            if (e.type != EventTypes.Message || e.senderId == client.userID || e.redacted) continue;
            msgs.add({'sender': e.senderFromMemoryOrFallback.calcDisplayname(), 'body': e.body, 'ts': e.originServerTs.millisecondsSinceEpoch,
                'mentions_me': _mentionsMe(e), 'event_id': e.eventId});
            if (msgs.length >= 60) break;
          }
          t.cancelSubscriptions();
        } catch (_) {/* a room that cannot be read is listed by count only */}
      }
      out.add({'room_id': r.id, 'name': r.getLocalizedDisplayname(), 'kind': kindOf(r), 'labels': [if (label != null) label],
          'unread': r.notificationCount, 'messages': msgs.reversed.toList()});
    }
    return out;
  }

  Future<Map<String, dynamic>> run({bool refresh = false}) async =>
      api.digest({'rooms': await collect(), 'window_h': 24, 'refresh': refresh});
}
