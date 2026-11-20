import 'dart:io';
import 'package:flutter/foundation.dart';  // also provides Uint8List
import 'package:matrix/encryption.dart' show KeyVerificationMethod;
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'push_service.dart';
import 'api_service.dart';

/// Wraps the Matrix client. Encryption is enforced: every room we create is E2EE.
class MatrixService extends ChangeNotifier {
  late final Client client;
  bool get isLoggedIn => client.isLogged();
  String get userId => client.userID ?? '';
  Uri? get homeserver => client.homeserver;
  String? get accessToken => client.accessToken;

  Future<void> init() async {
    await vod.init();
    if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
      sqfliteFfiInit();
    }
    final dir = await getApplicationSupportDirectory();
    final factory = (Platform.isAndroid || Platform.isIOS) ? sqflite.databaseFactory : databaseFactoryFfi;
    final db = await factory.openDatabase('${dir.path}/amer_teams.sqlite');
    client = Client('AmerTeams',
      database: await MatrixSdkDatabase.init('amer_teams', database: db),
      supportedLoginTypes: {AuthenticationTypes.password, AuthenticationTypes.sso},
      // Without this the SDK supports no verification method and silently ignores every verification request
      // (found by the in-use test). Emoji (SAS) and numbers, as in Element.
      verificationMethods: {KeyVerificationMethod.emoji, KeyVerificationMethod.numbers},
    );
    await client.init();
    client.onSync.stream.listen((_) => notifyListeners());
    notifyListeners();
  }

  Future<void> login(String server, String user, String password) async {
    await client.checkHomeserver(Uri.parse(server));
    await client.login(LoginType.mLoginPassword,
        identifier: AuthenticationUserIdentifier(user: user), password: password,
        initialDeviceDisplayName: 'Amer Teams ${Platform.operatingSystem}');
    await PushService.register(client, gateway: Uri.parse(server), registerKey: (k) => ApiService(this).notifyAddDevice(k));
    notifyListeners();
  }

  /// Self-registration with an invite code (Matrix User-Interactive Auth,
  /// stage m.login.registration_token). Server enforces the password policy.
  Future<void> register(String server, String username, String password, String inviteCode, {String? displayName}) async {
    await client.checkHomeserver(Uri.parse(server));
    final avail = await client.checkUsernameAvailability(username);
    if (avail != true) throw Exception('That username is already taken');
    // Matrix User-Interactive Auth: complete each stage the server requires,
    // e.g. m.login.registration_token followed by m.login.dummy.
    AuthenticationData? auth;
    for (var step = 0; step < 4; step++) {
      try {
        await client.register(username: username, password: password,
            initialDeviceDisplayName: 'Amer Teams ${Platform.operatingSystem}', auth: auth);
        break;
      } on MatrixException catch (e) {
        final session = e.session;
        if (session == null || e.authenticationFlows == null) rethrow;   // weak password, bad username…
        final done = e.completedAuthenticationFlows;
        final next = e.authenticationFlows!.first.stages.firstWhere((s) => !done.contains(s), orElse: () => '');
        if (next.isEmpty || (step > 0 && done.isEmpty)) throw Exception('Invite code was not accepted');
        auth = next == 'm.login.registration_token'
            ? AuthenticationData.fromJson({'type': next, 'token': inviteCode.trim(), 'session': session})
            : AuthenticationData(type: next, session: session);
      }
    }
    if (!client.isLogged()) throw Exception('Registration did not complete');
    if (displayName != null && displayName.isNotEmpty) {
      await client.setProfileField(client.userID!, 'displayname', {'displayname': displayName});
    }
    await PushService.register(client, gateway: Uri.parse(server), registerKey: (k) => ApiService(this).notifyAddDevice(k));
    notifyListeners();
  }

  Future<void> logout() async { await client.logout(); notifyListeners(); }

  List<Room> get rooms => client.rooms.where((r) => r.membership == Membership.join).toList()
    ..sort((a, b) => b.latestEventReceivedTime.compareTo(a.latestEventReceivedTime));

  /// Create an encrypted DM or group. Unencrypted creation is not offered.
  Future<String> createRoom({required String name, required List<String> invite, bool direct = false}) async {
    if (direct && invite.length == 1) {
      return client.startDirectChat(invite.first, enableEncryption: true);
    }
    return client.createGroupChat(groupName: name, invite: invite, enableEncryption: true,
        preset: CreateRoomPreset.privateChat);
  }

  // ---------- Teams = Matrix spaces, channels = encrypted child rooms ----------
  List<Room> get teams => client.rooms.where((r) => r.isSpace && r.membership == Membership.join).toList();
  List<Room> channelsOf(Room team) => team.spaceChildren
      .map((c) => c.roomId == null ? null : client.getRoomById(c.roomId!)).whereType<Room>().toList();
  /// The team (space) a channel belongs to, if any.
  Room? teamOf(Room ch) => teams.where((t) => t.spaceChildren.any((c) => c.roomId == ch.id)).firstOrNull;
  List<Room> get chats => rooms.where((r) => !r.isSpace).toList();

  /// A channel shared with partner organisations (docs/PARTNERS.md): marked com.amerteams.shared, which is the only
  /// way a room is created federatable; end-to-end encrypted; private (invite only).
  Future<String> createSharedChannel(String name, List<String> partners, List<String> invite) => client.createRoom(
      name: name, invite: invite, preset: CreateRoomPreset.privateChat,
      initialState: [StateEvent(type: EventTypes.Encryption, stateKey: '', content: {'algorithm': 'm.megolm.v1.aes-sha2'}),
                     StateEvent(type: 'com.amerteams.shared', stateKey: '', content: {'partners': partners})]);

  /// Teams (Matrix spaces), as in Microsoft Teams:
  /// - Private team: invite only. Public team: listed in the directory; anyone on this server can join.
  /// - Channels use the `restricted` join rule, so every team member can open every channel, including people
  ///   added to the team later. Each channel is end-to-end encrypted.
  Future<String> createTeam(String name, List<String> invite, {String description = '', bool public = false}) async {
    final id = await client.createRoom(name: name, topic: description.isEmpty ? null : description, invite: invite,
        preset: public ? CreateRoomPreset.publicChat : CreateRoomPreset.privateChat,
        visibility: public ? Visibility.public : Visibility.private,
        creationContent: {'type': 'm.space'});
    await createChannel(id, 'General');
    return id;
  }

  /// [members]: a private channel (Teams parity) — invite only, visible only to the people chosen.
  Future<String> createChannel(String teamId, String name, {String description = '', List<String>? members}) async {
    final team = client.getRoomById(teamId)!;
    final private = members != null;
    final invite = private ? members.where((u) => u != userId).toList() : team.getParticipants().where((u) => u.membership == Membership.join || u.membership == Membership.invite)
        .map((u) => u.id).where((u) => u != userId).toList();
    final id = await client.createRoom(name: name, topic: description.isEmpty ? null : description, invite: invite,
        preset: CreateRoomPreset.privateChat,
        initialState: [
          StateEvent(type: EventTypes.Encryption, stateKey: '', content: {'algorithm': AlgorithmTypes.megolmV1AesSha2}),
          if (private) StateEvent(type: EventTypes.RoomJoinRules, stateKey: '', content: {'join_rule': 'invite'})
          else StateEvent(type: EventTypes.RoomJoinRules, stateKey: '', content: {'join_rule': 'restricted',
            'allow': [{'type': 'm.room_membership', 'room_id': teamId}]}),
          if (private) StateEvent(type: kChannelSettings, stateKey: '', content: {'private': true}),
        ]);
    await team.setSpaceChild(id);
    return id;
  }

  /// Channel settings (state): private, moderated (only moderators start posts; everyone can reply), tabs.
  static const kChannelSettings = 'com.amerteams.channel';
  Map<String, Object?> channelSettings(Room ch) => ch.getState(kChannelSettings)?.content ?? const {};
  Future<void> setChannelSettings(Room ch, Map<String, Object?> patch) => client.setRoomStateWithKey(ch.id, kChannelSettings, '', {...channelSettings(ch), ...patch});
  bool canStartPost(Room ch) { final s = channelSettings(ch); if (s['moderated'] != true) return true;
    return ch.getPowerLevelByUserId(userId).level >= 50 || ((s['moderators'] as List?)?.contains(userId) ?? false); }
  /// My own favourites and hidden channels (account data, follows me across devices).
  Map<String, Object?> get channelPrefs => client.accountData['com.amerteams.channel_prefs']?.content ?? const {};
  List<String> _pref(String k) => ((channelPrefs[k] as List?) ?? const []).map((x) => '$x').toList();
  bool isFavourite(Room ch) => _pref('favourite').contains(ch.id);
  bool isHidden(Room ch) => _pref('hidden').contains(ch.id);
  Future<void> toggleChannelPref(Room ch, String k) async {
    final l = _pref(k); l.contains(ch.id) ? l.remove(ch.id) : l.add(ch.id);
    await client.setAccountData(userId, 'com.amerteams.channel_prefs', {...channelPrefs, k: l}); notifyListeners();
  }

  /// Adds people to a team and invites them to every channel.
  Future<void> addTeamMembers(Room team, List<String> users) async {
    for (final u in users) {
      try { await team.invite(u); } catch (_) {}
      for (final ch in channelsOf(team).where((ch) => channelSettings(ch)['private'] != true)) { try { await ch.invite(u); } catch (_) {} }
    }
  }

  /// Joins a team and all of its channels (restricted: allowed because we are now a member).
  Future<void> joinTeam(String teamId) async {
    await client.joinRoom(teamId);
    for (var i = 0; i < 20 && client.getRoomById(teamId)?.membership != Membership.join; i++) { await Future.delayed(const Duration(milliseconds: 300)); }
    final team = client.getRoomById(teamId); if (team == null) return;
    for (final c in team.spaceChildren) { if (c.roomId != null) { try { await client.joinRoom(c.roomId!); } catch (_) {} } }
  }

  /// Leaves a team and its channels.
  Future<void> leaveTeam(Room team) async {
    for (final ch in channelsOf(team)) { try { await ch.leave(); } catch (_) {} }
    await team.leave();
  }

  /// Public teams on this server that the user has not joined.
  Future<List<PublishedRoomsChunk>> discoverTeams({String search = ''}) async {
    final r = await client.queryPublicRooms(limit: 50, filter: PublicRoomQueryFilter(roomTypes: ['m.space'], genericSearchTerm: search.isEmpty ? null : search));
    return r.chunk.where((c) => client.getRoomById(c.roomId)?.membership != Membership.join).toList();
  }

  // ---------- Encrypted files: the SDK encrypts with AES-256-CTR before upload ----------
  Future<void> sendFile(Room room, String name, Uint8List bytes) async {
    if (!room.encrypted) throw StateError('Refusing to share files in an unencrypted room');
    await room.sendFileEvent(MatrixFile(bytes: bytes, name: name));
  }

  // ---------- Meetings: encrypted timeline events, aggregated into the calendar ----------
  /// A meeting (docs/CALENDAR.md): an encrypted event in a chat. Changes are separate events
  /// (`com.amerteams.meeting.update`) for the whole series or one occurrence: reschedule, rename, cancel. The newest
  /// change wins. RSVPs (`com.amerteams.meeting.rsvp`) are per person, for one occurrence or the series.
  Future<void> sendMeeting(Room room, {required String title, required DateTime start, required int minutes, String? txid,
      String recurrence = 'none', List<String> optional = const [], String showAs = 'busy', String description = ''}) =>
      room.sendEvent({'meeting_id': txid ?? DateTime.now().microsecondsSinceEpoch.toRadixString(36), 'title': title,
          'start': start.toUtc().toIso8601String(), 'duration_min': minutes, 'recurrence': recurrence, if (optional.isNotEmpty) 'optional': optional,
          'show_as': showAs, if (description.isNotEmpty) 'description': description, 'body': '📅 $title'}, type: kMeeting, txid: txid);

  static const kMeeting = 'com.amerteams.meeting', kMeetingUpdate = 'com.amerteams.meeting.update', kRsvp = 'com.amerteams.meeting.rsvp';

  /// Organiser: change or cancel the series, or one occurrence ([occurrence] = its original start).
  Future<void> updateMeeting(Room room, String meetingId, {DateTime? occurrence, String? title, DateTime? start, int? minutes, bool cancel = false}) =>
      room.sendEvent({'meeting_id': meetingId, 'scope': occurrence == null ? 'series' : 'occurrence', if (occurrence != null) 'occurrence': occurrence.toUtc().toIso8601String(),
        if (title != null) 'title': title, if (start != null) 'start': start.toUtc().toIso8601String(), if (minutes != null) 'duration_min': minutes, if (cancel) 'cancelled': true,
        'body': cancel ? '🚫 Meeting cancelled${occurrence != null ? ' (one occurrence)' : ''}' : '✏️ Meeting updated'}, type: kMeetingUpdate);

  /// Accept / tentative / decline, optionally with a note, for one occurrence or the whole series.
  Future<void> rsvp(Room room, String meetingId, String response, {DateTime? occurrence, String note = ''}) async {
    await room.sendEvent({'meeting_id': meetingId, 'response': response, if (occurrence != null) 'occurrence': occurrence.toUtc().toIso8601String(), if (note.isNotEmpty) 'note': note,
      'body': '${{'yes': '✅ Accepted', 'maybe': '❔ Tentative', 'no': '❌ Declined'}[response]}${note.isEmpty ? '' : ': $note'}'}, type: kRsvp);
  }

  static DateTime _next(DateTime t, String rec) => switch (rec) {
    'daily' => t.add(const Duration(days: 1)),
    'weekdays' => t.add(Duration(days: t.weekday == DateTime.friday ? 3 : t.weekday == DateTime.saturday ? 2 : 1)),
    'weekly' => t.add(const Duration(days: 7)), 'monthly' => DateTime(t.year, t.month + 1, t.day, t.hour, t.minute), _ => DateTime(9999) };

  Future<List<Meeting>> meetings() async {
    final out = <Meeting>[]; final horizon = DateTime.now().add(const Duration(days: 120)); final me = userId;
    for (final r in chats) {
      final tl = await r.getTimeline(limit: 2000);
      final evs = tl.events.toList(); tl.cancelSubscriptions();
      final updates = evs.where((e) => e.type == kMeetingUpdate).toList()..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
      final rsvps = evs.where((e) => e.type == kRsvp).toList()..sort((a, b) => a.originServerTs.compareTo(b.originServerTs));
      for (final e in evs.where((e) => e.type == kMeeting)) {
        final id = '${e.content['meeting_id'] ?? e.eventId}';
        var title = e.content['title'] as String? ?? 'Meeting'; var mins = (e.content['duration_min'] as num?)?.toInt() ?? 30;
        var st = DateTime.tryParse(e.content['start'] as String? ?? ''); if (st == null) continue;
        var cancelled = false;
        final occ = <String, Event>{};                                     // occurrence (original start, UTC ISO) -> newest change
        for (final u in updates.where((u) => u.content['meeting_id'] == id && u.senderId == e.senderId)) {   // only the organiser can change it
          if (u.content['scope'] == 'occurrence') { occ['${u.content['occurrence']}'] = u; continue; }
          if (u.content['cancelled'] == true) cancelled = true;
          title = u.content['title'] as String? ?? title; mins = (u.content['duration_min'] as num?)?.toInt() ?? mins;
          st = DateTime.tryParse(u.content['start'] as String? ?? '') ?? st;
        }
        if (cancelled) continue;
        final rec = e.content['recurrence'] as String? ?? 'none';
        var t = st!.toUtc();
        for (var n = 0; n < (rec == 'none' ? 1 : 200) && t.toLocal().isBefore(horizon); n++, t = _next(t, rec).toUtc()) {
          final key = t.toIso8601String(); final ch = occ[key];
          if (ch?.content['cancelled'] == true) continue;
          final start = DateTime.tryParse(ch?.content['start'] as String? ?? '') ?? t;
          String? my; String note = ''; final responses = <String, String>{};
          for (final x in rsvps.where((x) => x.content['meeting_id'] == id && (x.content['occurrence'] == null || x.content['occurrence'] == key))) {
            responses[x.senderId] = '${x.content['response']}';
            if (x.senderId == me) { my = '${x.content['response']}'; note = '${x.content['note'] ?? ''}'; }
          }
          out.add(Meeting(ch?.content['title'] as String? ?? title, start.toLocal(), (ch?.content['duration_min'] as num?)?.toInt() ?? mins, r,
            id: id, occurrence: rec == 'none' ? null : t, organiser: e.senderId, recurrence: rec, myResponse: my, myNote: note, responses: responses,
            optional: ((e.content['optional'] as List?) ?? const []).map((x) => '$x').toList(), showAs: '${e.content['show_as'] ?? 'busy'}',
            description: '${e.content['description'] ?? ''}', changed: ch != null));
        }
      }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  Future<void> sendText(Room room, String text) async {
    if (!room.encrypted) throw StateError('Refusing to send in an unencrypted room');
    await room.sendTextEvent(text);
  }
}

class Meeting {
  Meeting(this.title, this.start, this.minutes, this.room, {this.id = '', this.occurrence, this.organiser = '', this.recurrence = 'none', this.myResponse, this.myNote = '',
      this.responses = const {}, this.optional = const [], this.showAs = 'busy', this.description = '', this.changed = false});
  final String title; final DateTime start; final int minutes; final Room room;
  final String id, organiser, recurrence, myNote, showAs, description; final DateTime? occurrence; final String? myResponse;
  final Map<String, String> responses; final List<String> optional; final bool changed;
  bool get repeats => recurrence != 'none';
  bool isOrganiser(String me) => organiser == me;
}
