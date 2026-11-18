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
  Future<List<dynamic>> adminCalls({String? outcome, String? user}) =>
      _get('/v1/admin/calls?limit=200${outcome != null ? '&outcome=$outcome' : ''}${user != null ? '&user=${Uri.encodeComponent(user)}' : ''}');
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
}
