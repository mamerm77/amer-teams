import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:matrix/matrix.dart' as mx;
import '../config.dart';
import 'api_service.dart';
import 'call_manager.dart';
import 'pq_service.dart';

const kPqDeviceEvent = 'com.amerteams.pq.device';

/// End-to-end encrypted, post-quantum hybrid call.
/// - Every device publishes an ML-KEM-768 public key inside the Megolm-encrypted room.
/// - The media key K = HKDF(K_c || K_pq): K_c rides in Megolm (classical), K_pq is wrapped
///   per device with ML-KEM-768. Both must be broken to recover K (see pq_service.dart).
/// - Frames are AES-GCM encrypted (LiveKit E2EE). The SFU and orchestrator never see K.
/// - Re-key when someone joins or leaves and every [kCallKeyRotation]; every member switches index.
class SecureCall {
  SecureCall(this.api, this.room, {required this.callId, this.video = true});
  final bool video;
  bool _caller = false;
  String role = 'presenter';   // 'attendee' in webinar mode: watch, chat, react, raise hand
  String? livekitRoom;
  DateTime? _joinedAt;
  final ApiService api;
  final mx.Room room;
  final String callId;
  late final Room lk;
  late final BaseKeyProvider _keys;
  late final PqDeviceKey _pq;
  Uint8List? _key;
  int keyIndex = -1;
  Timer? _rotate;
  bool _joined = false;
  StreamSubscription? _sub;

  String get _me => room.client.userID!;
  String get _dev => room.client.deviceID!;

  /// 6-character code participants read aloud to confirm they hold the same key.
  String get safetyCode => _key == null ? '------'
      : sha256.convert([..._key!, ...utf8.encode(callId)]).toString().substring(0, 6).toUpperCase();
  bool get quantumSafe => _key != null;

  static Future<SecureCall> start(ApiService api, mx.Room room, {bool video = true, String? callId}) async {
    if (!room.encrypted) throw StateError('Calls require an end-to-end encrypted room');
    final id = callId ?? base64Url.encode(PqHybrid.random(9));
    final c = SecureCall(api, room, callId: id, video: video).._caller = true;
    await c._setup();
    await c._shareNewKey();
    await room.sendEvent({'call_id': id, 'media': video ? 'video' : 'audio',
        'body': video ? '📹 Video call (end-to-end encrypted)' : '📞 Voice call (end-to-end encrypted)'}, type: kCallInviteEvent);
    await c._join();
    return c;
  }

  static Future<SecureCall> join(ApiService api, mx.Room room, String callId, {bool video = true}) async {
    final c = SecureCall(api, room, callId: callId, video: video);
    await c._setup();              // publishes this device's key; members in the call re-key to include it
    Map<String, dynamic>? latest;
    for (var i = 0; i < 30 && latest == null; i++) {      // wait up to 30 s for a key that includes this device
      latest = await c._latestKeyEventForMe();
      if (latest == null) await Future.delayed(const Duration(seconds: 1));
    }
    if (latest == null) throw StateError('Nobody in the call has added this device yet. Ask someone in the call to keep it open, then try again.');
    await c._applyKey(latest);
    await c._join();
    await room.sendEvent({'call_id': callId, 'body': 'joined the call'}, type: kCallJoinedEvent);
    return c;
  }

  /// Join a meeting's call, or start it if nobody is in it yet.
  static Future<SecureCall> joinOrStart(ApiService api, mx.Room room, String callId, {bool video = true}) async {
    final c = SecureCall(api, room, callId: callId, video: video);
    final existing = await c._anyKeyEvent();
    if (existing == null) return start(api, room, video: video, callId: callId);
    return join(api, room, callId, video: video);
  }

  Future<bool?> _anyKeyEvent() async {
    final tl = await room.getTimeline();
    try {
      for (final e in tl.events) {
        if (e.type == kCallKeyEvent && e.content['call_id'] == callId &&
            DateTime.now().difference(e.originServerTs).inHours < 12) return true;
      }
      return null;
    } finally { tl.cancelSubscriptions(); }
  }

  /// Publish this device's ML-KEM-768 public key to the room (encrypted, authenticated by Megolm).
  static Future<void> publishDeviceKey(mx.Room room) async {
    final k = await PqDeviceKey.load();
    await room.sendEvent({'user_id': room.client.userID, 'device_id': room.client.deviceID,
        'alg': 'ML-KEM-768', 'pk': base64.encode(k.pk), 'body': '🔐 Quantum-safe device key'}, type: kPqDeviceEvent);
  }

  Future<void> _setup() async {
    _pq = await PqDeviceKey.load();
    _keys = await BaseKeyProvider.create();
    await publishDeviceKey(room);
    _sub = room.client.onTimelineEvent.stream.listen((e) {
      if (e.roomId != room.id) return;
      if (e.type == kCallKeyEvent && e.content['call_id'] == callId) {
        _applyKey(e.content).catchError((_) {});   // not for this device: ignore
      }
      // a new device joined the room during the call: re-key so it is included
      if (e.type == kPqDeviceEvent && _joined && e.senderId != _me) _shareNewKey();
    });
  }

  /// Latest ML-KEM public key per (user, device) among current members.
  Future<List<(String, String, Uint8List)>> _memberDevices() async {
    final members = (await room.requestParticipants()).map((u) => u.id).toSet();
    final tl = await room.getTimeline();
    final found = <String, (String, String, Uint8List)>{};
    try {
      for (final e in tl.events) {                       // newest first
        if (e.type != kPqDeviceEvent) continue;
        final u = e.content['user_id'] as String?, d = e.content['device_id'] as String?;
        if (u == null || d == null || u != e.senderId || !members.contains(u)) continue;   // sender must own the key
        found.putIfAbsent('$u|$d', () => (u, d, base64.decode(e.content['pk'] as String)));
      }
    } finally { tl.cancelSubscriptions(); }
    found.putIfAbsent('$_me|$_dev', () => (_me, _dev, _pq.pk));
    return found.values.toList();
  }

  Future<Map<String, dynamic>?> _latestKeyEventForMe() async {
    final tl = await room.getTimeline();
    try {
      for (final e in tl.events) {
        if (e.type == kCallKeyEvent && e.content['call_id'] == callId &&
            (e.content['wraps'] as Map?)?.containsKey('$_me|$_dev') == true) return e.content;
      }
      return null;
    } finally { tl.cancelSubscriptions(); }
  }

  Future<void> _applyKey(Map<String, dynamic> c) async {
    final idx = (c['key_index'] as num).toInt();
    if (idx <= keyIndex) return;
    final k = PqHybrid.openKeyEvent(c, _me, _dev, _pq.sk);   // throws if not for this device / tampered
    keyIndex = idx; _key = k;
    await _keys.setSharedKey(base64.encode(k), keyIndex: idx);
    // switch outgoing encryption to the new index, otherwise old-key holders can still decrypt
    if (_joined) await lk.e2eeManager?.setKeyIndex(idx);
  }

  Future<void> _shareNewKey() async {
    final next = keyIndex + 1;
    final (content, k) = PqHybrid.newKeyEvent(callId, next, await _memberDevices());
    await room.sendEvent(content, type: kCallKeyEvent);   // Megolm-encrypted
    keyIndex = next; _key = k;
    await _keys.setSharedKey(base64.encode(k), keyIndex: next);
    if (_joined) await lk.e2eeManager?.setKeyIndex(next);
  }

  Future<void> _join() async {
    final t = await api.callToken(room.id, callId, _me);
    if (t['e2ee'] != 'required') throw StateError('Server did not confirm the encryption policy');
    role = (t['role'] as String?) ?? 'presenter'; livekitRoom = t['livekit_room'] as String?;
    lk = Room(roomOptions: RoomOptions(adaptiveStream: true, dynacast: true, e2eeOptions: E2EEOptions(keyProvider: _keys),
        defaultAudioCaptureOptions: const AudioCaptureOptions(noiseSuppression: true, echoCancellation: true, autoGainControl: true, highPassFilter: true)));
    await lk.connect(t['url'], t['token']);
    await lk.e2eeManager?.setKeyIndex(keyIndex);
    if (role != 'attendee') {
      await lk.localParticipant?.setCameraEnabled(video);
      await lk.localParticipant?.setMicrophoneEnabled(true);
    }
    _joinedAt = DateTime.now();
    lk.createListener().on<ParticipantDisconnectedEvent>((_) => _shareNewKey());
    _joined = true;
    _rotate = Timer.periodic(kCallKeyRotation, (_) => _shareNewKey());
  }

  bool get encrypted => _joined && lk.e2eeManager != null && _key != null;

  Duration get elapsed => _joinedAt == null ? Duration.zero : DateTime.now().difference(_joinedAt!);

  Future<void> leave() async {
    _rotate?.cancel(); await _sub?.cancel();
    if (_joined) {
      final alone = lk.remoteParticipants.isEmpty;
      await lk.disconnect();
      if (_caller || alone) {        // record the call for everyone's history
        await room.sendEvent({'call_id': callId, 'duration_s': elapsed.inSeconds, 'reason': 'hangup',
            'body': '${video ? '📹' : '📞'} Call ended · ${elapsed.inMinutes}:${(elapsed.inSeconds % 60).toString().padLeft(2, '0')}'}, type: kCallEndEvent);
      }
    }
  }
}
