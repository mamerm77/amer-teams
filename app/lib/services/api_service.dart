import 'dart:convert';
import 'package:http/http.dart' as http;
import 'matrix_service.dart';
import '../config.dart';

/// Talks to the Amer orchestrator (AI engine + call token service).
class ApiService {
  ApiService(this.m);
  final MatrixService m;
  Uri _u(String p) => m.homeserver!.replace(path: '$kApiPath$p');
  Map<String, String> get _h => {'Authorization': 'Bearer ${m.accessToken}', 'Content-Type': 'application/json'};

  Future<Map<String, dynamic>> _post(String p, Map body) async {
    final r = await http.post(_u(p), headers: _h, body: jsonEncode(body));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 300) throw Exception(j['detail'] ?? 'Request failed (${r.statusCode})');
    return j;
  }

  Future<Map<String, dynamic>> callToken(String roomId, String callId, String name) =>
      _post('/v1/calls/token', {'room_id': roomId, 'call_id': callId, 'display_name': name});

  Future<Map<String, dynamic>> ask(String prompt, {String context = '', String? agent, List<String> labels = const []}) =>
      _post('/v1/ai/ask', {'prompt': prompt, 'context': context, 'agent': agent, 'labels': labels});

  Future<List<dynamic>> agents() async {
    final r = await http.get(_u('/v1/agents'), headers: _h);
    return jsonDecode(r.body);
  }

  Future<void> toggleAgent(String id, bool on) => _post('/v1/agents/$id', {'enabled': on});

  Future<Map<String, dynamic>> ops() async => jsonDecode((await http.get(_u('/v1/ops/status'), headers: _h)).body);

  Future<List<dynamic>> alerts() async => jsonDecode((await http.get(_u('/v1/ops/alerts'), headers: _h)).body);

  /// Ask-the-meeting agent: question plus the last 20 minutes of the meeting's on-device transcript (docs/MEETING_AGENT.md).
  Future<Map<String, dynamic>> askMeeting(String callId, String roomId, String question, List<Map<String, Object?>> transcript) =>
      _post('/v1/meetings/${Uri.encodeComponent(callId)}/ask', {'room_id': roomId, 'question': question, 'transcript': transcript});
  // ---------- Workflows (docs/WORKFLOWS.md) ----------
  Future<List<dynamic>> workflows() => _get('/v1/workflows');
  Future<Map<String, dynamic>> workflowDraft(String text, List<Map<String, String>> rooms) => _post('/v1/workflows/draft', {'text': text, 'rooms': rooms});
  Future<Map<String, dynamic>> workflowSave(Map<String, Object?> d, {String? id, bool enabled = false}) => _post('/v1/workflows', {'definition': d, 'id': id, 'enabled': enabled});
  Future<void> workflowEnable(String id, bool on) => _post('/v1/workflows/${Uri.encodeComponent(id)}/enable', {'enabled': on});
  Future<Map<String, dynamic>> workflowDryRun(Map<String, Object?> d, Map<String, Object?> sample) => _post('/v1/workflows/dry-run', {'definition': d, 'sample': sample});
  Future<List<dynamic>> workflowRuns(String id) => _get('/v1/workflows/${Uri.encodeComponent(id)}/runs');
  Future<Map<String, dynamic>> workflowStart(String id, Map<String, Object?> trigger, {String? idempotencyKey}) async {
    final r = await http.post(_u('/v1/workflows/${Uri.encodeComponent(id)}/runs'), headers: {..._h, if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey}, body: jsonEncode({'trigger': trigger}));
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 300) throw Exception(j['detail'] ?? 'Request failed (${r.statusCode})');
    return j;
  }
  Future<void> workflowStep(String run, String step, String status, {int attempt = 1, List<String> fields = const [], String error = ''}) =>
      _post('/v1/workflows/runs/${Uri.encodeComponent(run)}/steps', {'step_id': step, 'status': status, 'attempt': attempt, 'fields': fields, 'error': error});
  Future<void> workflowFinish(String run, String status, {String error = ''}) => _post('/v1/workflows/runs/${Uri.encodeComponent(run)}/finish', {'status': status, 'error': error});
  Future<Map<String, dynamic>> workflowHttp(String run, String step, Map<String, Object?> body) => _post('/v1/workflows/runs/${Uri.encodeComponent(run)}/http', {'step_id': step, 'body': body});

  /// Catch-up digest of unread chats (docs/CATCH_UP.md).
  Future<Map<String, dynamic>> digest(Map<String, Object?> body) => _post('/v1/ai/digest', body);
  Future<Map<String, dynamic>> schedule(String request) => _post('/v1/ai/schedule', {'request': request});

  // ---------- Meeting host controls ----------
  Future<Map<String, dynamic>> meetingControl(String roomId, String callId, String action, {String? identity}) =>
      _post('/v1/meetings/control', {'room_id': roomId, 'call_id': callId, 'action': action, 'identity': identity});

  // ---------- Phone network ----------
  Future<Map<String, dynamic>> phonePolicy() async => jsonDecode((await http.get(_u('/v1/phone/policy'), headers: _h)).body);
  Future<Map<String, dynamic>> dial(String number) => _post('/v1/phone/dial', {'number': number});

  // ---------- Administration (server admins only) ----------
  Future<List<dynamic>> _get(String p) async {
    final r = await http.get(_u(p), headers: _h);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 300) throw Exception(j['detail'] ?? 'Request failed (${r.statusCode})');
    return j as List;
  }
  Future<List<dynamic>> users() => _get('/v1/admin/users');
  Future<List<dynamic>> invites() => _get('/v1/admin/invites');
  Future<Map<String, dynamic>> createInvite({int uses = 1, int days = 7}) => _post('/v1/admin/invites', {'uses_allowed': uses, 'expiry_days': days});
  Future<Map<String, dynamic>> createUser(String username, String password, {String name = '', bool admin = false}) =>
      _post('/v1/admin/users', {'username': username, 'password': password, 'display_name': name, 'admin': admin});
  Future<void> deactivate(String uid) => _post('/v1/admin/users/${Uri.encodeComponent(uid)}/deactivate', {});
  Future<void> resetPassword(String uid, String pw) => _post('/v1/admin/users/${Uri.encodeComponent(uid)}/password', {'password': pw});

  Future<List<dynamic>> audit() async => jsonDecode((await http.get(_u('/v1/audit'), headers: _h)).body);

  // ---------- Call trace (metadata only) ----------
  /// Fire-and-forget: a trace failure must never affect the call itself.
  Future<void> trace(Map<String, Object?> ev) async {
    try { await http.post(_u('/v1/calls/trace'), headers: _h, body: jsonEncode(ev)).timeout(const Duration(seconds: 5)); } catch (_) {}
  }
  Future<void> quality(String callId, String device, List<Map<String, Object?>> samples) async {
    if (samples.isEmpty) return;
    try { await http.post(_u('/v1/calls/quality'), headers: _h, body: jsonEncode({'call_id': callId, 'device_id': device, 'samples': samples})).timeout(const Duration(seconds: 5)); } catch (_) {}
  }
  Future<List<dynamic>> adminCalls({String? outcome, String? user}) async {
    final r = await http.get(_u('/v1/admin/calls').replace(queryParameters: {'limit': '200', if (outcome != null) 'outcome': outcome, if (user != null) 'user': user}), headers: _h);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 300) throw Exception(j['detail'] ?? 'Request failed (${r.statusCode})');
    return j as List;
  }
  Future<Map<String, dynamic>> callTrace(String callId) async {
    final r = await http.get(_u('/v1/admin/calls/${Uri.encodeComponent(callId)}/trace'), headers: _h);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 300) throw Exception(j['detail'] ?? 'Request failed (${r.statusCode})');
    return j;
  }
  Future<List<dynamic>> tenants() => _get('/v1/admin/tenants');
  Future<void> saveTenant(Map<String, Object?> t) => _post('/v1/admin/tenants', t);
  Future<void> setTenantMember(String uid, String tenant) => _post('/v1/admin/tenants/members', {'user_id': uid, 'tenant': tenant});
  Future<Map<String, dynamic>> myCompliance() async => jsonDecode((await http.get(_u('/v1/compliance/me'), headers: _h)).body);
  /// Live participant count of a meeting, from the media server.
  Future<int> presence(String roomId, String callId) async {
    try {
      final r = await http.get(_u('/v1/meetings/presence').replace(queryParameters: {'room_id': roomId, 'call_id': callId}), headers: _h).timeout(const Duration(seconds: 5));
      return r.statusCode == 200 ? (jsonDecode(r.body)['count'] as num).toInt() : 0;
    } catch (_) { return 0; }
  }
  /// The Amer assistant account on this server (a chat participant).
  Future<Map<String, dynamic>> assistant() async => jsonDecode((await http.get(_u('/v1/ai/assistant'), headers: _h)).body);

  // ---------- Agent Ops (AI agent teams delivering projects) ----------
  Future<List<dynamic>> agentopsProjects() => _get('/v1/agentops/projects');
  Future<List<dynamic>> agentopsTeam() => _get('/v1/agentops/team');
  Future<List<dynamic>> agentopsEvents({int after = 0, String? projectId}) async {
    final r = await http.get(_u('/v1/agentops/events').replace(queryParameters: {'after': '$after', if (projectId != null) 'project_id': projectId}), headers: _h);
    final j = jsonDecode(utf8.decode(r.bodyBytes));
    if (r.statusCode >= 300) throw Exception(j['detail'] ?? 'Request failed (${r.statusCode})');
    return j as List;
  }
  Future<Map<String, dynamic>> agentopsStart(String prompt, {String? name}) => _post('/v1/agentops/projects', {'prompt': prompt, if (name != null) 'name': name});
  Future<void> agentopsStop(String projectId) => _post('/v1/agentops/projects/${Uri.encodeComponent(projectId)}/stop', {});
  Future<Map<String, dynamic>> agentopsReplay({double speed = 3}) => _post('/v1/agentops/replay', {'speed': speed});

  /// Live Server-Sent Events from /v1/agentops/stream. Ends when the connection drops;
  /// the caller reconnects with the last seq it saw, so no event is lost or repeated.
  Stream<Map<String, dynamic>> agentopsStream({int after = 0}) async* {
    final client = http.Client();
    try {
      final req = http.Request('GET', _u('/v1/agentops/stream').replace(queryParameters: {'after': '$after'}))
        ..headers.addAll({'Authorization': 'Bearer ${m.accessToken}', 'Accept': 'text/event-stream'});
      final res = await client.send(req);
      if (res.statusCode != 200) throw Exception('Agent Ops stream refused (${res.statusCode})');
      final data = StringBuffer();
      await for (final line in res.stream.transform(utf8.decoder).transform(const LineSplitter())) {
        if (line.startsWith('data:')) {
          data.write(line.substring(5).trimLeft());
        } else if (line.isEmpty && data.isNotEmpty) {
          yield jsonDecode(data.toString()) as Map<String, dynamic>;
          data.clear();
        }
      }
    } finally {
      client.close();
    }
  }
}
