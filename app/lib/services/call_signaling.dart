/// 1:1 call signalling state machine (docs/CALL_PROTOCOL.md). Pure Dart: no UI, no network.
/// The app feeds it incoming events and timer ticks; it emits events to send and state changes.
library;

const kCallPrefix = 'com.amerteams.call.';
const kInvite = '${kCallPrefix}invite', kRinging = '${kCallPrefix}ringing', kAnswer = '${kCallPrefix}answer',
    kReject = '${kCallPrefix}reject', kHangup = '${kCallPrefix}hangup', kEnd = '${kCallPrefix}end';
const kInviteLifetime = Duration(seconds: 45);
const kMediaTimeout = Duration(seconds: 20);
const kUnreachableHint = Duration(seconds: 6);

enum CallRole { caller, callee }
enum CallState { idle, calling, ringing, connecting, connected, ended }
enum CallOutcome { none, completed, cancelled, declined, busy, noAnswer, missed, answeredElsewhere, failed, remoteHangup }

typedef Send = void Function(String type, Map<String, Object?> content);

class CallSignaling {
  CallSignaling({required this.role, required this.callId, required this.myUser, required this.myDevice, required this.send,
      this.video = true, DateTime Function()? clock, DateTime? inviteTs, Duration lifetime = kInviteLifetime})
      : _now = clock ?? DateTime.now, lifetime = lifetime {
    _startedAt = inviteTs ?? _now();
  }

  final CallRole role; final String callId, myUser, myDevice; final bool video; final Send send;
  final Duration lifetime;
  final DateTime Function() _now;
  late DateTime _startedAt;
  DateTime? _stateAt, connectedAt;
  CallState state = CallState.idle;
  CallOutcome outcome = CallOutcome.none;
  String? remoteParty;                 // device that answered (caller side) / caller device (callee side)
  final ringingDevices = <String>{};
  void Function(CallSignaling)? onChange;

  bool get active => state != CallState.idle && state != CallState.ended;
  Duration get duration => connectedAt == null ? Duration.zero : _now().difference(connectedAt!);
  bool get unreachable => role == CallRole.caller && state == CallState.calling && _now().difference(_startedAt) >= kUnreachableHint;

  void _go(CallState s, [CallOutcome o = CallOutcome.none]) {
    if (state == CallState.ended) return;
    state = s; _stateAt = _now();
    if (s == CallState.connected) connectedAt ??= _now();
    if (s == CallState.ended) outcome = o;
    onChange?.call(this);
  }
  Map<String, Object?> _base() => {'call_id': callId, 'party_id': myDevice, 'version': 2};

  // ---------------- caller ----------------
  void startCall({Map<String, Object?> extra = const {}}) {
    assert(role == CallRole.caller);
    send(kInvite, {..._base(), ...extra, 'media': video ? 'video' : 'audio', 'lifetime_ms': lifetime.inMilliseconds,
        'body': video ? '📹 Video call' : '📞 Voice call'});
    _startedAt = _now(); _go(CallState.calling);
  }

  // ---------------- callee ----------------
  /// Returns false if the invite must be ignored (expired / already over).
  bool receiveInvite({required bool busy}) {
    assert(role == CallRole.callee);
    if (_now().difference(_startedAt) >= lifetime) { _go(CallState.ended, CallOutcome.missed); return false; }
    if (busy) { send(kReject, {..._base(), 'reason': 'busy', 'body': '📵 Busy'}); _go(CallState.ended, CallOutcome.busy); return false; }
    send(kRinging, _base());
    _go(CallState.ringing);
    return true;
  }
  void accept({Map<String, Object?> extra = const {}}) {
    if (role != CallRole.callee || state != CallState.ringing) return;
    send(kAnswer, {..._base(), ...extra, 'body': 'answered'});
    _go(CallState.connecting);
  }
  void decline() {
    if (role != CallRole.callee || state != CallState.ringing) return;
    send(kReject, {..._base(), 'reason': 'declined', 'body': '📵 Declined'});
    _go(CallState.ended, CallOutcome.declined);
  }

  // ---------------- both ----------------
  void mediaConnected() { if (state == CallState.connecting) _go(CallState.connected); }

  void hangup() {
    switch (state) {
      case CallState.calling:
      case CallState.ringing when role == CallRole.caller:
        send(kHangup, {..._base(), 'reason': 'cancelled'});
        send(kEnd, {..._base(), 'duration_s': 0, 'outcome': 'cancelled', 'media': video ? 'video' : 'audio', 'body': '${video ? '📹' : '📞'} Call cancelled'});
        _go(CallState.ended, CallOutcome.cancelled);
      case CallState.ringing:                       // callee pressing end while ringing = decline
        decline();
      case CallState.connecting:
      case CallState.connected:
        final d = duration.inSeconds;
        send(kHangup, {..._base(), 'reason': 'user_hangup'});
        send(kEnd, {..._base(), 'duration_s': d, 'outcome': d > 0 ? 'completed' : 'failed', 'media': video ? 'video' : 'audio',
            'body': '${video ? '📹' : '📞'} Call ended · ${d ~/ 60}:${(d % 60).toString().padLeft(2, '0')}'});
        _go(CallState.ended, d > 0 ? CallOutcome.completed : CallOutcome.failed);
      default:
        break;
    }
  }

  /// Feed every signalling event for this call (including our own, echoed back by sync).
  void onSignal(String type, Map<String, Object?> c, {required String senderUser}) {
    if (c['call_id'] != callId || state == CallState.ended) return;
    final party = c['party_id'] as String?;
    final fromMe = senderUser == myUser;
    final fromThisDevice = fromMe && party == myDevice;
    if (fromThisDevice) return;
    switch (type) {
      case kRinging when role == CallRole.caller && !fromMe:
        if (party != null) ringingDevices.add(party);
        if (state == CallState.calling) _go(CallState.ringing);
      case kAnswer when role == CallRole.caller && !fromMe:
        if (state == CallState.calling || state == CallState.ringing) { remoteParty = party; _go(CallState.connecting); }
      case kAnswer when role == CallRole.callee && fromMe:            // another of my devices answered
        if (state == CallState.ringing) _go(CallState.ended, CallOutcome.answeredElsewhere);
      case kReject when role == CallRole.caller && !fromMe:
        if (state == CallState.calling || state == CallState.ringing) {
          final busy = c['reason'] == 'busy';
          send(kEnd, {..._base(), 'duration_s': 0, 'outcome': busy ? 'busy' : 'declined', 'media': video ? 'video' : 'audio', 'body': busy ? '📵 Busy' : '📵 Call declined'});
          _go(CallState.ended, busy ? CallOutcome.busy : CallOutcome.declined);
        }
      case kReject when role == CallRole.callee && fromMe:             // declined on another of my devices
        if (state == CallState.ringing) _go(CallState.ended, CallOutcome.declined);
      case kHangup:
        if (fromMe && role == CallRole.callee && state == CallState.ringing) { _go(CallState.ended, CallOutcome.answeredElsewhere); break; }
        if (!fromMe) {
          final r = c['reason'];
          _go(CallState.ended, state == CallState.ringing && role == CallRole.callee
              ? CallOutcome.missed : (r == 'cancelled' || r == 'invite_timeout') && state != CallState.connected ? CallOutcome.missed : CallOutcome.remoteHangup);
        }
      default:
        break;
    }
  }

  /// Call about once a second: enforces invite lifetime and media-connect timeout.
  void tick() {
    final now = _now();
    if (role == CallRole.caller && (state == CallState.calling || state == CallState.ringing) && now.difference(_startedAt) >= lifetime) {
      send(kHangup, {..._base(), 'reason': 'invite_timeout'});
      send(kEnd, {..._base(), 'duration_s': 0, 'outcome': 'missed', 'media': video ? 'video' : 'audio', 'body': '${video ? '📹' : '📞'} Missed call'});
      _go(CallState.ended, CallOutcome.noAnswer);
    } else if (role == CallRole.callee && state == CallState.ringing && now.difference(_startedAt) >= lifetime) {
      _go(CallState.ended, CallOutcome.missed);
    } else if (state == CallState.connecting && _stateAt != null && now.difference(_stateAt!) >= kMediaTimeout) {
      send(kHangup, {..._base(), 'reason': 'failed'});
      _go(CallState.ended, CallOutcome.failed);
    } else if (unreachable) {
      onChange?.call(this);       // let the UI show "not reachable yet"
    }
  }

  /// Glare: both sides invited each other; the smaller call_id wins.
  static bool winsGlare(String mine, String theirs) => mine.compareTo(theirs) < 0;

  String get label => switch (state) {
    CallState.idle => '',
    CallState.calling => unreachable ? 'Calling… (not reachable yet)' : 'Calling…',
    CallState.ringing => role == CallRole.caller ? 'Ringing…' : 'Incoming call',
    CallState.connecting => 'Connecting securely…',
    CallState.connected => '${duration.inMinutes.toString().padLeft(2, '0')}:${(duration.inSeconds % 60).toString().padLeft(2, '0')}',
    CallState.ended => switch (outcome) {
      CallOutcome.completed => 'Call ended', CallOutcome.cancelled => 'Call cancelled', CallOutcome.declined => 'Declined',
      CallOutcome.busy => 'Busy', CallOutcome.noAnswer => 'No answer', CallOutcome.missed => 'Missed call',
      CallOutcome.answeredElsewhere => 'Answered on another device', CallOutcome.failed => 'Could not connect',
      CallOutcome.remoteHangup => 'Call ended', CallOutcome.none => 'Call ended' },
  };
}
