import 'dart:io';
import 'package:flutter/foundation.dart';  // also provides Uint8List
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:sqflite/sqflite.dart' as sqflite;
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:flutter_vodozemac/flutter_vodozemac.dart' as vod;
import 'push_service.dart';

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
    await PushService.register(client, gateway: Uri.parse(server));
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
    await PushService.register(client, gateway: Uri.parse(server));
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
  List<Room> get chats => rooms.where((r) => !r.isSpace).toList();

  Future<String> createTeam(String name, List<String> invite) async {
    final id = await client.createRoom(name: name, invite: invite, preset: CreateRoomPreset.privateChat,
        creationContent: {'type': 'm.space'});
    await createChannel(id, 'General');
    return id;
  }

  Future<String> createChannel(String teamId, String name) async {
    final team = client.getRoomById(teamId)!;
    final invite = team.getParticipants().map((u) => u.id).where((u) => u != userId).toList();
    final id = await client.createGroupChat(groupName: name, invite: invite, enableEncryption: true, preset: CreateRoomPreset.privateChat);
    await team.setSpaceChild(id);
    return id;
  }

  // ---------- Encrypted files: the SDK encrypts with AES-256-CTR before upload ----------
  Future<void> sendFile(Room room, String name, Uint8List bytes) async {
    if (!room.encrypted) throw StateError('Refusing to share files in an unencrypted room');
    await room.sendFileEvent(MatrixFile(bytes: bytes, name: name));
  }

  // ---------- Meetings: encrypted timeline events, aggregated into the calendar ----------
  Future<void> sendMeeting(Room room, {required String title, required DateTime start, required int minutes}) =>
      room.sendEvent({'meeting_id': DateTime.now().microsecondsSinceEpoch.toRadixString(36), 'title': title,
          'start': start.toUtc().toIso8601String(), 'duration_min': minutes, 'body': '📅 $title'}, type: 'com.amerteams.meeting');

  Future<List<Meeting>> meetings() async {
    final out = <Meeting>[];
    for (final r in chats) {
      final tl = await r.getTimeline();
      for (final e in tl.events.where((e) => e.type == 'com.amerteams.meeting')) {
        final st = DateTime.tryParse(e.content['start'] as String? ?? '');
        if (st != null) out.add(Meeting(e.content['title'] as String? ?? 'Meeting', st.toLocal(), (e.content['duration_min'] as num?)?.toInt() ?? 30, r));
      }
      tl.cancelSubscriptions();
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
  Meeting(this.title, this.start, this.minutes, this.room);
  final String title; final DateTime start; final int minutes; final Room room;
}
