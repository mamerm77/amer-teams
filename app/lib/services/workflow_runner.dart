import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'api_service.dart';
import 'workflow_engine.dart';
import 'decisions_tasks.dart';

/// Runs the owner's workflows on the owner's device (docs/WORKFLOWS.md). The device holds the keys, so message
/// triggers are read and posts are sent here, encrypted and with the owner's own rights, never more. The server
/// keeps versions and run records (status only). One device per run: the device that started it.
/// Runs that wait (forms, approvals, waits) are kept in a local file, so they survive a restart.
class WorkflowRunner {
  WorkflowRunner._();
  static final instance = WorkflowRunner._();
  Client? c; ApiService? api;
  List<Map<String, dynamic>> workflows = [];
  final runs = <String, Map<String, dynamic>>{};        // run id -> {id, wid, name, def, cur, ctx, wait}
  final _busy = <String>{};
  StreamSubscription? _sub; Timer? _tick;
  DateTime _started = DateTime.now(), _lastRefresh = DateTime(2000);
  String _lastCron = '';
  String lastError = '';

  Future<void> start(Client client, ApiService a) async {
    if (c != null) return;
    c = client; api = a; _started = DateTime.now();
    await _load();
    await refresh();
    _sub = client.onTimelineEvent.stream.listen(_onEvent);
    _tick = Timer.periodic(const Duration(seconds: 20), (_) => _onTick());
    for (final r in runs.values.toList()) { if (r['wait'] == null) unawaited(_execute(r['id'] as String)); }   // resume after a restart
  }
  void stop() { _sub?.cancel(); _tick?.cancel(); c = null; }

  Future<void> refresh() async {
    try { workflows = (await api!.workflows()).cast<Map<String, dynamic>>(); _lastRefresh = DateTime.now(); }
    catch (e) { lastError = 'Could not load workflows: $e'; }
  }

  // ---------- local persistence of active runs ----------
  Future<File> _file() async => File('${(await getApplicationSupportDirectory()).path}/workflow_runs.json');
  Future<void> _load() async {
    try { final f = await _file(); if (await f.exists()) { (jsonDecode(await f.readAsString()) as Map).forEach((k, v) => runs[k as String] = Map<String, dynamic>.from(v as Map)); } } catch (_) {}
  }
  Future<void> _save() async { try { await (await _file()).writeAsString(jsonEncode(runs)); } catch (_) {} }

  // ---------- triggers ----------
  void _onTick() {
    if (DateTime.now().difference(_lastRefresh) > const Duration(minutes: 5)) refresh();
    final now = DateTime.now(), minute = '${now.year}${now.month}${now.day}${now.hour}${now.minute}';
    if (minute != _lastCron) {
      _lastCron = minute;
      for (final w in workflows.where((w) => w['enabled'] == true)) {
        final t = Map<String, Object?>.from(w['definition']['trigger'] as Map);
        if (t['type'] == 'schedule' && wfCronDue('${t['cron']}', now)) {
          _startRun(w, {'type': 'schedule'}, {'type': 'schedule', 'at': now.toIso8601String()}, idem: 'cron-${w['id']}-$minute');
        }
      }
    }
    for (final r in runs.values.toList()) {                       // waits that are due, approvals that timed out
      final w = r['wait'] as Map?; if (w == null) continue;
      final until = DateTime.tryParse('${w['until'] ?? ''}');
      if (until == null || DateTime.now().isBefore(until)) continue;
      if (w['kind'] == 'wait') { r['wait'] = null; _advance(r); }
      else { _fail(r, '${w['step']}', 'No answer before the timeout', status: 'timed_out'); }
    }
  }

  void _onEvent(Event e) {
    if (e.type == kWfResponse) { _onResponse(e); return; }
    if (e.type != EventTypes.Message || e.originServerTs.isBefore(_started) || e.content[kWfContent] != null) return;
    for (final w in workflows.where((w) => w['enabled'] == true)) {
      final t = Map<String, Object?>.from(w['definition']['trigger'] as Map);
      final hasFile = const ['m.file', 'm.image', 'm.video', 'm.audio'].contains(e.messageType);
      if (wfMatches(t, roomId: e.roomId!, body: e.body, hasFile: hasFile, sender: e.senderId)) {
        _startRun(w, {'type': 'message', 'room': e.roomId, 'event_id': e.eventId, 'sender': e.senderId},
            {'type': 'message', 'room': e.roomId, 'event_id': e.eventId, 'sender': e.senderId, 'body': e.body, 'has_file': hasFile},
            idem: e.eventId);
      }
    }
  }

  /// Manual run from the Workflows screen.
  Future<String?> runNow(Map<String, dynamic> w) => _startRun(w, {'type': 'manual'}, {'type': 'manual'}, idem: 'manual-${DateTime.now().microsecondsSinceEpoch}');

  Future<String?> _startRun(Map<String, dynamic> w, Map<String, Object?> meta, Map<String, Object?> trigger, {required String idem}) async {
    try {
      final r = await api!.workflowStart(w['id'] as String, {...meta, 'device': c!.deviceID}, idempotencyKey: idem);
      if ((r['trigger'] as Map?)?['device'] != c!.deviceID || runs.containsKey(r['id'])) return null;   // another of my devices runs it
      final d = Map<String, dynamic>.from(r['definition'] as Map);                                   // pinned version
      runs[r['id'] as String] = {'id': r['id'], 'wid': w['id'], 'name': w['name'], 'def': d, 'cur': (d['steps'] as List).first['id'],
          'ctx': {'trigger': trigger}, 'wait': null, 'started': DateTime.now().toIso8601String()};
      await _save();
      unawaited(_execute(r['id'] as String));
      return r['id'] as String;
    } catch (e) { lastError = 'Could not start ${w['name']}: $e'; return null; }
  }

  // ---------- execution ----------
  List<Map<String, Object?>> _steps(Map r) => ((r['def'] as Map)['steps'] as List).map((s) => Map<String, Object?>.from(s as Map)).toList();
  Map<String, Object?> _ctx(Map r) => Map<String, Object?>.from(r['ctx'] as Map);

  Future<T> _retry<T>(Future<T> Function() f, void Function(int) onAttempt) async {
    const delays = [1, 4, 16];
    for (var a = 1; ; a++) {
      onAttempt(a);
      try { return await f(); }
      catch (e) {
        if (a > delays.length || '$e'.contains('(4') && !'$e'.contains('(429')) rethrow;     // 4xx: never retried
        await Future.delayed(Duration(milliseconds: delays[a - 1] * 1000 + Random().nextInt(400)));
      }
    }
  }

  Future<void> _execute(String id) async {
    if (!_busy.add(id)) return;
    try {
      while (true) {
        final r = runs[id]; if (r == null || r['wait'] != null) return;
        final cur = r['cur'] as String?;
        if (cur == null) { runs.remove(id); await _save(); await api!.workflowFinish(id, 'succeeded'); return; }
        if (DateTime.now().difference(DateTime.parse(r['started'] as String)) > const Duration(days: 30)) { await _fail(r, cur, 'Ran longer than 30 days', status: 'timed_out'); return; }
        final s = _steps(r).firstWhere((x) => x['id'] == cur);
        final ctx = _ctx(r);
        var attempt = 1;
        try {
          final out = await _retry(() => _run(r, s, ctx), (a) => attempt = a);
          if (out == null) { await api!.workflowStep(id, cur, 'waiting', attempt: attempt); await _save(); return; }   // paused for a person or a timer
          ctx[cur] = out; r['ctx'] = ctx;
          await api!.workflowStep(id, cur, 'succeeded', attempt: attempt, fields: out.keys.toList());
          r['cur'] = wfNext(_steps(r), cur, ctx);
          await _save();
        } catch (e) { await _fail(r, cur, '$e'.replaceFirst('Exception: ', ''), attempt: attempt); return; }
      }
    } finally { _busy.remove(id); }
  }

  Room _room(String? id) {
    final room = id == null ? null : c!.getRoomById(id);
    if (room == null || room.membership != Membership.join) throw Exception('You are not in that chat any more');
    return room;
  }

  /// One step. Returns its result, or null when the run now waits.
  Future<Map<String, Object?>?> _run(Map r, Map<String, Object?> s, Map<String, Object?> ctx) async {
    final trig = (ctx['trigger'] as Map?) ?? const {};
    switch (s['type']) {
      case 'condition': return {'result': wfEvaluate('${s['if']}', ctx)};
      case 'post':
        final ev = await _room(s['room'] as String?).sendEvent({'msgtype': 'm.text', 'body': wfRender('${s['text']}', ctx), kWfContent: {'run': r['id'], 'step': s['id'], 'kind': 'post', 'workflow': r['name']}});
        if (ev == null) throw Exception('The message could not be sent');
        return {'event_id': ev};
      case 'ask_form' || 'approval':
        final form = s['type'] == 'ask_form';
        final people = wfPeople(form ? s['to'] : s['approvers'], ctx);
        if (people.isEmpty) throw Exception('No one to ask: check the ${form ? 'form' : 'approval'} recipients');
        final room = _room((s['room'] ?? trig['room']) as String?);
        final names = people.map((p) => room.unsafeGetUserFromMemoryOrFallback(p).calcDisplayname()).join(', ');
        final body = form ? '📝 ${r['name']}: $names, please fill in ${(s['fields'] as List).join(', ')}.'
                          : '✅ ${r['name']}: $names, please approve or reject.${s['text'] != null ? ' ${wfRender('${s['text']}', ctx)}' : ''}';
        await room.sendEvent({'msgtype': 'm.text', 'body': body, kWfContent: {'run': r['id'], 'step': s['id'], 'kind': form ? 'form' : 'approval',
            'people': people, if (form) 'fields': s['fields'], 'workflow': r['name']}});
        final h = (s['timeout_h'] as num?)?.toDouble();
        r['wait'] = {'kind': s['type'], 'step': s['id'], 'people': people, 'room': room.id,
            if (h != null) 'until': DateTime.now().add(Duration(minutes: (h * 60).round())).toIso8601String()};
        return null;
      case 'wait':
        r['wait'] = {'kind': 'wait', 'step': s['id'], 'until': DateTime.now().add(Duration(minutes: (s['minutes'] as num).round())).toIso8601String()};
        r['cur'] = wfNext(_steps(r), s['id'] as String, ctx);       // continue after the wait
        return null;
      case 'run_agent':
        final a = await api!.ask(wfRender('${s['prompt'] ?? ''}', ctx), agent: 'assist');
        if (a['error'] == true) throw Exception('Amer could not answer: ${a['answer']}');
        return {'answer': a['answer']};
      case 'create_task':
        final room = _room((s['room'] ?? trig['room']) as String?);
        final who = wfPeople(s['assignee'] ?? c!.userID, ctx);
        final id = 'task-${r['id']}-${s['id']}';
        await saveTask(room, {'task_id': id, 'title': wfRender('${s['title']}', ctx), 'owner': who.isEmpty ? c!.userID : who.first, 'status': 'open',
            if (s['due_days'] is num) 'due': DateTime.now().add(Duration(days: (s['due_days'] as num).toInt())).toIso8601String().substring(0, 10),
            if (trig['event_id'] != null) 'source_event': trig['event_id']});
        return {'task_id': id};
      case 'http':
        final body = {for (final e in ((s['body'] as Map?) ?? const {}).entries) '${e.key}': wfRender('${e.value}', ctx)};
        final res = await api!.workflowHttp(r['id'] as String, s['id'] as String, body);
        if ((res['status'] as int? ?? 0) >= 400) throw Exception('The web hook answered ${res['status']}');
        return {'status': res['status']};
    }
    throw Exception('Step type ${s['type']} is not available yet');
  }

  void _onResponse(Event e) {
    final j = e.content; final id = j['run'] as String?;
    final r = id == null ? null : runs[id]; final w = r?['wait'] as Map?;
    if (r == null || w == null || w['step'] != j['step'] || w['room'] != e.roomId) return;
    if (!((w['people'] as List?) ?? const []).contains(e.senderId)) return;            // only the people asked
    final ctx = _ctx(r);
    ctx[w['step'] as String] = w['kind'] == 'approval'
        ? {'decision': j['decision'] == 'approved' ? 'approved' : 'rejected', 'by': e.senderId}
        : {...Map<String, Object?>.from((j['values'] as Map?) ?? const {}), 'by': e.senderId};
    r['ctx'] = ctx; r['wait'] = null;
    _advance(r, done: w['step'] as String, fields: (ctx[w['step']] as Map).keys.cast<String>().toList());
  }

  Future<void> _advance(Map r, {String? done, List<String> fields = const []}) async {
    if (done != null) {
      await api!.workflowStep(r['id'] as String, done, 'succeeded', fields: fields).catchError((_) {});
      r['cur'] = wfNext(_steps(r), done, _ctx(r));
    }
    await _save();
    unawaited(_execute(r['id'] as String));
  }

  Future<void> _fail(Map r, String step, String why, {String status = 'failed', int attempt = 1}) async {
    lastError = '${r['name']}: step $step failed: $why';
    runs.remove(r['id']); await _save();
    try { await api!.workflowStep(r['id'] as String, step, 'failed', attempt: attempt, error: why); } catch (_) {}
    try { await api!.workflowFinish(r['id'] as String, status, error: why); } catch (_) {}
  }
}
