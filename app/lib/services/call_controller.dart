import 'dart:async';
import 'package:flutter/foundation.dart';
import 'package:matrix/matrix.dart' as mx;
import 'api_service.dart';
import 'call_service.dart';
import 'call_signaling.dart';
import 'tones.dart';

/// One 1:1 call: the signalling state machine (call_signaling.dart) driving the encrypted media (call_service.dart).
/// Media is connected only after the callee answers; the timer starts only when the other side's media arrives.
/// Every signalling step is sent as an encrypted room event and reported (metadata only) to the call trace.
class CallController extends ChangeNotifier {
  CallController._(this.api, this.room, this.sig);
  final ApiService api; final mx.Room room; final CallSignaling sig;
  SecureCall? media; String? error;
  StreamSubscription? _sub; Timer? _tick, _stats;
  bool _connecting = false;
  String? peerName;

  String get callId => sig.callId;
  bool get video => sig.video;
  CallState get state => sig.state;
  String get label => error ?? sig.label;
  bool get ended => sig.state == CallState.ended;

  static String get _newId => 'c${DateTime.now().millisecondsSinceEpoch.toRadixString(36)}${UniqueKey().hashCode.toRadixString(36)}';

  void _trace(String event, String direction, [Map<String, Object?> extra = const {}]) => api.trace({
        'call_id': callId, 'room_id': room.id, 'event': event, 'direction': direction, 'device_id': room.client.deviceID,
        'kind': 'call', 'media': video ? 'video' : 'audio', ...extra});

  static CallController _make(ApiService api, mx.Room room, CallRole role, String id, bool video, {DateTime? inviteTs}) {
    late CallController c;
    final sig = CallSignaling(role: role, callId: id, myUser: room.client.userID!, myDevice: room.client.deviceID!, video: video, inviteTs: inviteTs,
        send: (type, content) {
          room.sendEvent(content, type: type).catchError((e) { c.error = 'Network error: could not send ${type.split('.').last}'; c.notifyListeners(); return null; });
          final ev = type.split('.').last;
          final peer = role == CallRole.caller && ev == 'invite' ? room.directChatMatrixID : null;
          c._trace(ev, 'out', {'peer': peer, 'reason': content['reason'], 'outcome': content['outcome'], 'duration_s': content['duration_s']});
        });
    c = CallController._(api, room, sig);
    sig.onChange = (_) => c._changed();
    c._sub = room.client.onTimelineEvent.stream.listen(c._onEvent);
    c._tick = Timer.periodic(const Duration(seconds: 1), (_) { sig.tick(); c.notifyListeners(); });
    return c;
  }

  /// Caller: prepares this device's quantum-safe key, sends the invite and plays ringback.
  static Future<CallController> outgoing(ApiService api, mx.Room room, {required bool video}) async {
    if (!room.encrypted) throw StateError('Calls require an end-to-end encrypted room');
    final c = _make(api, room, CallRole.caller, _newId, video);
    c.peerName = room.getLocalizedDisplayname();
    c.media = await SecureCall.prepare(api, room, callId: c.callId, video: video, caller: true);
    c.sig.startCall();
    Tones.ringback();
    return c;
  }

  /// Callee: returns null when the invite must not ring (expired, or auto-rejected as busy).
  static CallController? incoming(ApiService api, mx.Room room, mx.Event invite, {required bool busy}) {
    final c = _make(api, room, CallRole.callee, invite.content['call_id'] as String, invite.content['media'] != 'audio', inviteTs: invite.originServerTs);
    c.peerName = invite.senderFromMemoryOrFallback.calcDisplayname();
    c._trace('invite', 'in', {'peer': invite.senderId});
    if (!c.sig.receiveInvite(busy: busy)) { c._trace('state', 'local', {'state': 'ended', 'outcome': c.sig.outcome.name}); c._dispose(); return null; }
    Tones.ringtone();
    return c;
  }

  void _onEvent(mx.Event e) {
    if (e.roomId != room.id || !e.type.startsWith(kCallPrefix) || e.content['call_id'] != callId) return;
    if (e.senderId == room.client.userID && e.content['party_id'] == room.client.deviceID) return;   // our own echo
    _trace(e.type.split('.').last, 'in', {'reason': e.content['reason'], 'outcome': e.content['outcome']});
    sig.onSignal(e.type, e.content, senderUser: e.senderId);
  }

  Future<void> accept() async {
    Tones.stop();
    media = await SecureCall.prepare(api, room, callId: callId, video: video, caller: false);   // publish our key before answering
    sig.accept();
  }
  void decline() { Tones.stop(); sig.decline(); }
  Future<void> hangup() async { sig.hangup(); }

  void _changed() {
    _trace('state', 'local', {'state': sig.state.name, if (sig.state == CallState.ended) 'outcome': sig.outcome.name,
        if (sig.state == CallState.ended && sig.connectedAt != null) 'duration_s': sig.duration.inSeconds});
    switch (sig.state) {
      case CallState.ringing: if (sig.role == CallRole.caller) Tones.ringback();
      case CallState.connecting: Tones.stop(); _connectMedia();
      case CallState.connected: Tones.stop(); _startStats();
      case CallState.ended:
        (sig.outcome == CallOutcome.busy ? Tones.busy() : sig.outcome == CallOutcome.answeredElsewhere ? Tones.stop() : Tones.ended());
        _teardown();
      default: break;
    }
    notifyListeners();
  }

  Future<void> _connectMedia() async {
    if (_connecting || media == null) return; _connecting = true;
    try {
      media!.onRemoteMedia = () { sig.mediaConnected(); };
      if (sig.role == CallRole.caller) { await media!.connectAsCaller(); } else { await media!.connectAsCallee(); }
      if (media!.hasRemoteMedia) sig.mediaConnected();
    } catch (e) {
      error = 'Could not connect: ${'$e'.replaceFirst('Bad state: ', '')}';
      _trace('error', 'local', {'reason': 'media_connect_failed'});
      sig.hangup();
    }
  }

  void _startStats() {
    _stats?.cancel();
    _stats = Timer.periodic(const Duration(seconds: 10), (_) async {
      final s = await media?.qualitySamples() ?? const <Map<String, Object?>>[];
      api.quality(callId, room.client.deviceID ?? '', s);
    });
  }

  Future<void> _teardown() async {
    _stats?.cancel(); _tick?.cancel();
    final s = await media?.qualitySamples() ?? const <Map<String, Object?>>[];   // final sample
    await api.quality(callId, room.client.deviceID ?? '', s);
    await media?.leave(sendEnd: false); media = null;
    await _sub?.cancel();
  }
  void _dispose() { _tick?.cancel(); _sub?.cancel(); }
  @override void dispose() { _teardown(); super.dispose(); }
}
