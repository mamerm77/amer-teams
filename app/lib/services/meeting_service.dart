import 'dart:async';
import 'dart:math';
import 'package:matrix/matrix.dart';
import 'matrix_service.dart';

/// Meetings: an end-to-end encrypted room with a 9-digit meeting ID (room alias #m-<id>) and a
/// waiting room (join rule "knock"): people who join by ID wait until the host admits them.
class MeetingService {
  MeetingService(this.m);
  final MatrixService m;
  Client get c => m.client;
  String get server => c.userID!.split(':').sublist(1).join(':');

  static String format(String id) => id.length == 9 ? '${id.substring(0, 3)} ${id.substring(3, 6)} ${id.substring(6)}' : id;
  static String clean(String id) => id.replaceAll(RegExp(r'[^0-9]'), '');

  /// Create a meeting room. Returns (roomId, meetingId).
  Future<(String, String)> create(String title, {List<String> invite = const [], DateTime? start, int minutes = 30}) async {
    final r = Random.secure();
    for (var attempt = 0; attempt < 5; attempt++) {
      final id = (100000000 + r.nextInt(900000000)).toString();
      try {
        final roomId = await c.createRoom(
          name: title.isEmpty ? 'Meeting ${format(id)}' : title,
          roomAliasName: 'm-$id', invite: invite, preset: CreateRoomPreset.privateChat,
          initialState: [
            StateEvent(type: EventTypes.RoomJoinRules, stateKey: '', content: {'join_rule': 'knock'}),
            StateEvent(type: EventTypes.Encryption, stateKey: '', content: {'algorithm': 'm.megolm.v1.aes-sha2'}),
            StateEvent(type: EventTypes.HistoryVisibility, stateKey: '', content: {'history_visibility': 'joined'}),
          ]);
        await c.waitForRoomInSync(roomId, join: true);
        final room = c.getRoomById(roomId)!;
        await room.sendEvent({
          'meeting_id': id, 'title': title.isEmpty ? 'Meeting ${format(id)}' : title,
          'start': (start ?? DateTime.now()).toUtc().toIso8601String(), 'duration_min': minutes,
          'body': '📅 ${title.isEmpty ? 'Meeting' : title} · ID ${format(id)}',
        }, type: 'com.amerteams.meeting');
        return (roomId, id);
      } on MatrixException catch (e) {
        if (e.errcode != 'M_ROOM_IN_USE') rethrow;      // ID clash: try another
      }
    }
    throw Exception('Could not reserve a meeting ID, try again');
  }

  /// Join by meeting ID. Returns the room ID once admitted (already a member: immediately).
  Future<String> joinById(String rawId, {Duration wait = const Duration(minutes: 5)}) async {
    final id = clean(rawId);
    if (id.length != 9) throw Exception('A meeting ID has 9 digits');
    final alias = '#m-$id:$server';
    final roomId = (await c.getRoomIdByAlias(alias)).roomId;
    if (roomId == null) throw Exception('No meeting with ID ${format(id)}');
    final existing = c.getRoomById(roomId);
    if (existing != null && existing.membership == Membership.join) return roomId;
    await c.knockRoom(alias, reason: 'Asking to join');
    // wait in the lobby until the host invites us, then accept
    final done = Completer<String>();
    late StreamSubscription sub;
    Future<void> check() async {
      final r = c.getRoomById(roomId);
      if (r == null || done.isCompleted) return;
      if (r.membership == Membership.invite) { await r.join(); done.complete(roomId); }
      if (r.membership == Membership.leave || r.membership == Membership.ban) done.completeError(Exception('The host declined your request'));
    }
    sub = c.onSync.stream.listen((_) => check());
    await check();
    try { return await done.future.timeout(wait, onTimeout: () => throw Exception('The host has not admitted you yet')); }
    finally { await sub.cancel(); }
  }

  String? meetingIdOf(Room room) {
    final a = room.canonicalAlias;
    final m = RegExp(r'^#m-(\d{9}):').firstMatch(a);
    return m?.group(1);
  }

  List<User> waiting(Room room) => room.getParticipants([Membership.knock]);
  Future<void> admit(Room room, String userId) => room.invite(userId);
  Future<void> decline(Room room, String userId) => room.kick(userId);
}
