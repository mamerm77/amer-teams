import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart';
import '../config.dart';
import '../screens/call_screen.dart';
import 'matrix_service.dart';

const kCallJoinedEvent = 'com.amerteams.call.joined';
const kCallEndEvent = 'com.amerteams.call.end';

/// One entry in the call history.
class CallRecord {
  CallRecord({required this.room, required this.callId, required this.video, required this.outgoing, required this.at,
      required this.peer, this.durationS, this.answered = false});
  final Room room; final String callId, peer; final bool video, outgoing, answered; final DateTime at; final int? durationS;
  bool get missed => !outgoing && !answered;
}

/// Global calling: rings for incoming calls anywhere in the app and builds the call history.
class CallManager {
  CallManager(this.m, this.navigator);
  final MatrixService m;
  final GlobalKey<NavigatorState> navigator;
  StreamSubscription? _sub;
  final _ringing = <String>{};
  bool inCall = false;

  void start() {
    _sub = m.client.onTimelineEvent.stream.listen((e) {
      if (e.type != kCallInviteEvent || e.senderId == m.client.userID) return;
      if (DateTime.now().difference(e.originServerTs).inSeconds > 45) return;   // old invite from history
      final id = e.content['call_id'] as String?; if (id == null || _ringing.contains(id) || inCall) return;
      final room = m.client.getRoomById(e.roomId!); if (room == null) return;
      _ringing.add(id);
      _ring(room, id, e.content['media'] != 'audio', e.senderFromMemoryOrFallback.calcDisplayname());
    });
  }
  void dispose() => _sub?.cancel();

  Future<void> _ring(Room room, String callId, bool video, String from) async {
    final ctx = navigator.currentContext; if (ctx == null) return;
    var open = true;
    Timer.periodic(const Duration(seconds: 2), (t) { if (!open) { t.cancel(); } else { HapticFeedback.heavyImpact(); SystemSound.play(SystemSoundType.alert); } });
    final accept = await showDialog<bool>(context: ctx, barrierDismissible: false, builder: (d) {
      Future.delayed(const Duration(seconds: 45), () { if (open && Navigator.of(d).canPop()) Navigator.pop(d, false); });
      return AlertDialog(
        icon: Icon(video ? Icons.videocam : Icons.call, size: 40),
        title: Text(from), content: Text('Incoming ${video ? 'video' : 'voice'} call · end-to-end encrypted\n${room.getLocalizedDisplayname()}'),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(d, false), icon: const Icon(Icons.call_end), label: const Text('Decline')),
          FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.green), onPressed: () => Navigator.pop(d, true), icon: Icon(video ? Icons.videocam : Icons.call), label: const Text('Accept')),
        ]);
    });
    open = false; _ringing.remove(callId);
    if (accept == true) {
      navigator.currentState?.push(MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, callId: callId, video: video)));
    } else {
      await room.sendEvent({'call_id': callId, 'reason': 'declined', 'body': '📵 Call declined'}, type: kCallEndEvent);
    }
  }

  /// Call history across all chats, newest first.
  Future<List<CallRecord>> history({int perRoom = 60}) async {
    final out = <CallRecord>[];
    for (final r in m.chats) {
      final tl = await r.getTimeline();
      try {
        final evs = tl.events.take(perRoom).toList();
        final ends = {for (final e in evs.where((e) => e.type == kCallEndEvent && e.content['duration_s'] != null)) e.content['call_id']: (e.content['duration_s'] as num).toInt()};
        final joinedByMe = evs.where((e) => e.type == kCallJoinedEvent && e.senderId == m.client.userID).map((e) => e.content['call_id']).toSet();
        for (final e in evs.where((e) => e.type == kCallInviteEvent)) {
          final id = e.content['call_id'] as String;
          final mine = e.senderId == m.client.userID;
          out.add(CallRecord(room: r, callId: id, video: e.content['media'] != 'audio', outgoing: mine, at: e.originServerTs,
              peer: mine ? r.getLocalizedDisplayname() : e.senderFromMemoryOrFallback.calcDisplayname(),
              durationS: ends[id], answered: mine || joinedByMe.contains(id)));
        }
      } finally { tl.cancelSubscriptions(); }
    }
    out.sort((a, b) => b.at.compareTo(a.at));
    return out;
  }
}
