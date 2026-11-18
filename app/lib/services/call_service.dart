import 'dart:async';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';
import 'package:crypto/crypto.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:matrix/matrix.dart' as mx;
import '../config.dart';
import 'api_service.dart';

/// End-to-end encrypted call.
/// - Media key K is generated on the caller's device and distributed ONLY inside the
///   Megolm-encrypted Matrix room. The SFU and orchestrator never see it.
/// - Frames are encrypted with AES-GCM (LiveKit E2EE / insertable streams).
/// - Key rotates when someone leaves and every [kCallKeyRotation].
class SecureCall {
  SecureCall(this.api, this.room, {required this.callId});
  final ApiService api;
  final mx.Room room;
  final String callId;
  final lk = Room();
  late final BaseKeyProvider _keys;
  Uint8List? _key;
  int keyIndex = 0;
  Timer? _rotate;
  StreamSubscription? _sub;

  /// 6-character code participants can read aloud to verify they share the same key.
  String get safetyCode => _key == null ? '------'
      : sha256.convert([..._key!, ...utf8.encode(callId)]).toString().substring(0, 6).toUpperCase();

  static Uint8List _random32() { final r = Random.secure(); return Uint8List.fromList(List.generate(32, (_) => r.nextInt(256))); }

  /// Caller: create key, share it, join.
  static Future<SecureCall> start(ApiService api, mx.Room room) async {
    if (!room.encrypted) throw StateError('Calls require an end-to-end encrypted room');
    final id = base64Url.encode(_random32()).substring(0, 12);
    final c = SecureCall(api, room, callId: id);
    await c._setup();
    await c._shareNewKey();
    await room.sendEvent({'call_id': id, 'body': '📞 Encrypted call started'}, type: kCallInviteEvent);
    await c._join();
    return c;
  }

  /// Callee: key arrives via the encrypted room event; join with it.
  static Future<SecureCall> join(ApiService api, mx.Room room, String callId) async {
    final c = SecureCall(api, room, callId: callId);
    await c._setup();
    final latest = c._latestKeyEvent();
    if (latest == null) throw StateError('Call key not received yet — wait for sync and retry');
    await c._applyKey(latest);
    await c._join();
    return c;
  }

  Future<void> _setup() async {
    _keys = await BaseKeyProvider.create();
    _sub = room.client.onTimelineEvent.stream.listen((e) {
      if (e.roomId == room.id && e.type == kCallKeyEvent && e.content['call_id'] == callId) {
        _applyKey(e.content);
      }
    });
  }

  Map<String, dynamic>? _latestKeyEvent() {
    final evs = room.timeline?.events ?? [];
    for (final e in evs) {
      if (e.type == kCallKeyEvent && e.content['call_id'] == callId) return e.content;
    }
    return null;
  }

  Future<void> _applyKey(Map<String, dynamic> c) async {
    final k = base64.decode(c['key'] as String);
    keyIndex = (c['key_index'] as num).toInt();
    _key = Uint8List.fromList(k);
    await _keys.setSharedKey(base64.encode(k), keyIndex: keyIndex);
    // Installing a key is not enough: switch outgoing encryption to the new index,
    // otherwise frames keep using the old key and a departed member can still decrypt.
    await lk.e2eeManager?.setKeyIndex(keyIndex);
  }

  Future<void> _shareNewKey() async {
    final k = _random32();
    keyIndex = _key == null ? 0 : keyIndex + 1;
    // Sent through Megolm: only member devices can decrypt it.
    await room.sendEvent({'call_id': callId, 'key': base64.encode(k), 'key_index': keyIndex, 'alg': 'AES-GCM-256'},
        type: kCallKeyEvent);
    await _applyKey({'key': base64.encode(k), 'key_index': keyIndex});
  }

  Future<void> _join() async {
    final t = await api.callToken(room.id, callId, room.client.userID ?? '');
    if (t['e2ee'] != 'required') throw StateError('Server did not confirm E2EE policy');
    await lk.connect(t['url'], t['token'],
        roomOptions: RoomOptions(adaptiveStream: true, dynacast: true,
            e2eeOptions: E2EEOptions(keyProvider: _keys)));
    await lk.localParticipant?.setCameraEnabled(true);
    await lk.localParticipant?.setMicrophoneEnabled(true);
    lk.createListener().on<ParticipantDisconnectedEvent>((_) => _shareNewKey());
    _rotate = Timer.periodic(kCallKeyRotation, (_) => _shareNewKey());
  }

  bool get encrypted => lk.isE2EEEnabled;

  Future<void> leave() async { _rotate?.cancel(); await _sub?.cancel(); await lk.disconnect(); }
}
