import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/matrix.dart' hide CallState;
import '../config.dart';
import '../screens/call_screen.dart';
import 'api_service.dart';
import 'call_controller.dart';
import 'call_signaling.dart';
import 'matrix_service.dart';

const kCallJoinedEvent = 'com.amerteams.call.joined';
const kCallEndEvent = 'com.amerteams.call.end';

/// Outcome of one call, derived only from its signalling events (same answer on every device).
class CallSummary {
  CallSummary(this.outcome, this.durationS, this.answered);
  final String outcome;     // live, completed, missed, declined, busy, cancelled, failed
  final int? durationS; final bool answered;
  static CallSummary of(Iterable<Event> evs, String callId, DateTime invitedAt) {
    String? out; int? dur; var answered = false, hung = false;
    for (final e in evs) {
      if (e.content['call_id'] != callId) continue;
      switch (e.type) {
        case kAnswer: answered = true;
        case kReject: out ??= e.content['reason'] == 'busy' ? 'busy' : 'declined';
        case kHangup: hung = true;
        case kEnd:
          out = (e.content['outcome'] as String?) ?? (e.content['reason'] == 'declined' ? 'declined' : 'completed');
          dur = (e.content['duration_s'] as num?)?.toInt();
      }
    }
    if (out == null && !answered && !hung && DateTime.now().difference(invitedAt) >= kInviteLifetime) out = 'missed';
    if (out == null && hung) out = answered ? 'completed' : 'missed';
    return CallSummary(out ?? 'live', dur, answered);
  }
  String label(bool outgoing, bool video) {
    final kind = video ? 'video call' : 'voice call';
    String dur() => '${durationS! ~/ 60}:${(durationS! % 60).toString().padLeft(2, '0')}';
    return switch (outcome) {
      'live' => answered ? 'On a $kind' : outgoing ? 'Calling…' : 'Incoming $kind',
      'completed' => '${outgoing ? 'Outgoing' : 'Incoming'} $kind${durationS != null && durationS! > 0 ? ' · ${dur()}' : ''}',
      'missed' || 'cancelled' => outgoing ? (outcome == 'cancelled' ? 'Cancelled $kind' : 'No answer') : 'Missed $kind',
      'declined' => outgoing ? 'Declined' : 'You declined',
      'busy' => outgoing ? 'Busy' : 'Missed $kind (you were busy)',
      _ => 'Call failed',
    };
  }
}

/// One entry in the call history.
class CallRecord {
  CallRecord({required this.room, required this.callId, required this.video, required this.outgoing, required this.at,
      required this.peer, this.durationS, this.answered = false, this.outcome});
  final Room room; final String callId, peer; final bool video, outgoing, answered; final DateTime at; final int? durationS;
  final String? outcome;
  bool get missed => !outgoing && !answered && outcome != 'live';
}

/// Global calling: rings for incoming calls anywhere in the app (protocol v2, docs/CALL_PROTOCOL.md) and builds the call history.
class CallManager {
  CallManager(this.m, this.navigator, this.api);
  final MatrixService m;
  final ApiService api;
  final GlobalKey<NavigatorState> navigator;
  StreamSubscription? _sub;
  final _seen = <String>{};
  CallController? current;            // the one active 1:1 call on this device
  bool inCall = false;                // also true during meetings
  bool get busy => inCall || (current != null && !current!.ended);

  void start() {
    _sub = m.client.onTimelineEvent.stream.listen((e) {
      if (e.type != kInvite || e.senderId == m.client.userID) return;
      if (e.content['version'] != 2) return;                                  // meetings and pre-v2 invites never ring
      final id = e.content['call_id'] as String?; if (id == null || !_seen.add(id)) return;
      if (DateTime.now().difference(e.originServerTs) >= kInviteLifetime) return;   // history replay: shown as missed in Calls
      final room = m.client.getRoomById(e.roomId!); if (room == null) return;
      if (m.client.ignoredUsers.contains(e.senderId)) return;
      // glare: I am calling the same room at the same moment
      final mine = current;
      if (mine != null && mine.room.id == room.id && mine.sig.role == CallRole.caller &&
          (mine.state == CallState.calling || mine.state == CallState.ringing)) {
        if (CallSignaling.winsGlare(mine.callId, id)) return;                 // they will cancel theirs and answer mine
        mine.hangup(); current = null;
        final c = CallController.incoming(api, room, e, busy: false);
        if (c != null) { current = c; c.accept(); _open(c); }
        return;
      }
      final c = CallController.incoming(api, room, e, busy: busy);
      if (c == null) return;                                                  // auto-rejected as busy, or expired
      current = c;
      c.addListener(() { if (c.ended && current == c) current = null; });
      _ring(c);
    });
  }
  void dispose() => _sub?.cancel();

  Future<CallController> startCall(Room room, {required bool video}) async {
    if (busy) throw StateError('You are already in a call');
    final c = await CallController.outgoing(api, room, video: video);
    current = c; c.addListener(() { if (c.ended && current == c) current = null; });
    return c;
  }

  void _open(CallController c) =>
      navigator.currentState?.push(MaterialPageRoute(builder: (_) => CallScreen(roomId: c.room.id, controller: c, video: c.video)));

  Future<void> _ring(CallController c) async {
    final ctx = navigator.currentContext; if (ctx == null) return;
    final vib = Timer.periodic(const Duration(seconds: 2), (_) => HapticFeedback.heavyImpact());
    VoidCallback? listener;
    final accept = await showDialog<bool>(context: ctx, barrierDismissible: false, builder: (d) {
      // closes itself when the call ends without us (caller cancelled, timeout, answered on another device)
      void l() { if (d.mounted && c.ended && Navigator.of(d).canPop()) Navigator.pop(d, false); }
      c.addListener(l);
      listener = l;
      return PopScope(canPop: false, child: AlertDialog(
        icon: Icon(c.video ? Icons.videocam : Icons.call, size: 40),
        title: Text(c.peerName ?? 'Incoming call'),
        content: Text('Incoming ${c.video ? 'video' : 'voice'} call · end-to-end encrypted\n${c.room.getLocalizedDisplayname()}'),
        actionsAlignment: MainAxisAlignment.spaceEvenly,
        actions: [
          FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(d, false), icon: const Icon(Icons.call_end), label: const Text('Decline')),
          FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.green), onPressed: () => Navigator.pop(d, true), icon: Icon(c.video ? Icons.videocam : Icons.call), label: const Text('Accept')),
        ]));
    });
    vib.cancel();
    if (listener != null) c.removeListener(listener);   // the dialog is gone; never touch its context again
    if (c.ended) {
      final msg = switch (c.sig.outcome) { CallOutcome.answeredElsewhere => 'Answered on another device', CallOutcome.missed => 'Missed call from ${c.peerName}', _ => null };
      if (msg != null && navigator.currentContext != null) ScaffoldMessenger.of(navigator.currentContext!).showSnackBar(SnackBar(content: Text(msg)));
      return;
    }
    if (accept == true) {
      try { await c.accept(); _open(c); } catch (e) { c.decline(); }
    } else {
      c.decline();
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
          if (e.content['version'] == 2) {
            final sm = CallSummary.of(evs, id, e.originServerTs);
            out.add(CallRecord(room: r, callId: id, video: e.content['media'] != 'audio', outgoing: mine, at: e.originServerTs,
                peer: mine ? r.getLocalizedDisplayname() : e.senderFromMemoryOrFallback.calcDisplayname(),
                durationS: sm.durationS, answered: sm.answered, outcome: sm.outcome));
            continue;
          }
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
