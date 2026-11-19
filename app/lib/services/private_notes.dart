import 'package:matrix/matrix.dart';

/// Agent messages visible to one user (docs/PRIVATE_AGENT_MESSAGES.md). Room messages are encrypted to every member,
/// so a private answer cannot live in the shared room. It lives in your own end-to-end encrypted room, which has only
/// you as a member (so only your devices hold its keys). Each note says which chat it belongs to; the chat shows it
/// inline as "Only you can see this", on every one of your devices.
class PrivateNotes {
  static const _acct = 'com.amerteams.private_room', type = 'com.amerteams.private_note';

  static Future<Room> _room(Client c) async {
    final id = c.accountData[_acct]?.content['room_id'] as String?;
    final have = id == null ? null : c.getRoomById(id);
    if (have != null && have.membership == Membership.join) return have;
    final rid = await c.createRoom(name: 'Amer · only you', preset: CreateRoomPreset.privateChat, initialState: [
      StateEvent(type: EventTypes.Encryption, stateKey: '', content: {'algorithm': AlgorithmTypes.megolmV1AesSha2})]);
    await c.setAccountData(c.userID!, _acct, {'room_id': rid});
    if (c.getRoomById(rid) == null) await c.waitForRoomInSync(rid, join: true);
    return c.getRoomById(rid)!;
  }

  static Future<void> add(Room forRoom, String agent, String text) async {
    final r = await _room(forRoom.client);
    if (r.getParticipants().where((u) => u.membership == Membership.join).length > 1 || !r.encrypted) throw StateError('Your private Amer room is not private any more');
    await r.sendEvent({'room_id': forRoom.id, 'agent': agent, 'text': text, 'body': '$agent (only you): $text'}, type: type);
  }

  /// Notes for [roomId], newest first.
  static Future<List<Event>> forRoom(Client c, String roomId) async {
    final id = c.accountData[_acct]?.content['room_id'] as String?; final r = id == null ? null : c.getRoomById(id);
    if (r == null) return [];
    final tl = await r.getTimeline(); final out = tl.events.where((e) => e.type == type && e.content['room_id'] == roomId && !e.redacted).toList();
    tl.cancelSubscriptions(); return out;
  }
  static Future<void> dismiss(Event e) => e.redactEvent(reason: 'dismissed');
}
