import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Agent Ops: a team of AI agents delivering a project, shown live.
/// Everything on this screen is drawn from events the orchestrator streams from the
/// Claude Agent SDK (hooks, messages, results). A recording is labelled REPLAY, never LIVE.
const _red = Color(0xFFE00800);
const _roles = ['orchestrator', 'analyst', 'architect', 'developer', 'tester', 'reviewer', 'documenter'];

class _Agent {
  String status = 'idle'; // idle | working | done
  int runs = 0, tools = 0, fails = 0, tokens = 0;
  String last = '';
}

class _LogLine {
  _LogLine(this.ts, this.agent, this.text, {this.kind = 0});
  final double ts; final String agent, text; final int kind; // 0 normal, 1 handoff/start, 2 error, 3 muted
}

class _Shot { _Shot(this.from, this.to, this.at); final String from, to; final DateTime at; }

class _Project {
  _Project(this.id);
  final String id;
  String name = '', prompt = '';
  bool replay = false, finished = false, ok = false;
  double? start, end; double? cost; int? turns; String? result;
  int toolCalls = 0, failures = 0;
  final agents = <String, _Agent>{for (final r in _roles) r: _Agent()};
  final roles = List<String>.from(_roles);
  List todos = [];
  final log = <_LogLine>[], messages = <(String, String)>[];
  final files = <String, List<(String, bool)>>{};
  final shots = <_Shot>[];
  _Agent agent(String r) { if (!agents.containsKey(r)) { agents[r] = _Agent(); roles.add(r); } return agents[r]!; }
  int get active => agents.values.where((a) => a.status == 'working').length;
  int get tokens => agents.values.fold(0, (s, a) => s + a.tokens);
  bool get live => !replay && !finished;
}

class AgentOpsScreen extends StatefulWidget { const AgentOpsScreen({super.key}); @override State<AgentOpsScreen> createState() => _S(); }

class _S extends State<AgentOpsScreen> with SingleTickerProviderStateMixin {
  final projects = <String, _Project>{};
  final order = <String>[];
  String? selected; bool follow = true;
  int lastSeq = 0; bool connected = false, disposed = false; String? err;
  StreamSubscription? sub; Timer? clock;
  late final AnimationController anim = AnimationController(vsync: this, duration: const Duration(seconds: 1))..repeat();

  @override void initState() { super.initState(); _connect(); clock = Timer.periodic(const Duration(milliseconds: 250), (_) { if (_cur?.finished == false) setState(() {}); }); }
  @override void dispose() { disposed = true; sub?.cancel(); clock?.cancel(); anim.dispose(); super.dispose(); }

  _Project? get _cur => selected == null ? null : projects[selected];

  void _connect() {
    if (disposed) return;
    final api = context.read<ApiService>();
    sub = api.agentopsStream(after: lastSeq).listen((e) {
      if (!connected) setState(() { connected = true; err = null; });
      _apply(e);
    }, onError: (Object e) {
         if (disposed) return;
         setState(() { connected = false; err = '$e'; });
         Future.delayed(const Duration(seconds: 3), _connect);
       },
       onDone: () { if (disposed) return; setState(() => connected = false); Future.delayed(const Duration(seconds: 2), _connect); },
       cancelOnError: true);
  }

  void _apply(Map<String, dynamic> e) {
    lastSeq = math.max(lastSeq, (e['seq'] as num?)?.toInt() ?? lastSeq);
    final pid = e['project_id'] as String; final d = Map<String, dynamic>.from(e['data'] ?? {});
    final ts = (e['ts'] as num).toDouble(); final r = (e['agent'] as String?) ?? 'orchestrator';
    final p = projects.putIfAbsent(pid, () { order.insert(0, pid); return _Project(pid); });
    final a = p.agent(r);
    switch (e['type']) {
      case 'project.started':
        p..name = '${d['name'] ?? pid}'..prompt = '${d['prompt'] ?? ''}'..replay = d['replay'] == true..start = ts;
        p.log.add(_LogLine(ts, 'amer', 'project started · ${p.prompt}', kind: 1));
        if (follow) selected = pid;
      case 'agent.started': a..status = 'working'..runs += 1; p.log.add(_LogLine(ts, r, '▶ started', kind: 1));
      case 'agent.stopped': a..status = 'done'..last = ''; p.log.add(_LogLine(ts, r, '■ stopped', kind: 3));
      case 'handoff':
        final to = '${d['to']}'; p.agent(to); p.shots.add(_Shot(r, to, DateTime.now()));
        p.log.add(_LogLine(ts, r, '→ $to  ${d['brief'] ?? ''}', kind: 1));
      case 'tool.started':
        p.toolCalls++; a.tools++; final s = '${d['summary'] ?? d['tool']}'; a.last = s; p.log.add(_LogLine(ts, r, s));
        if (d['tool'] == 'Write' || d['tool'] == 'Edit') {
          final f = s.split(' ').skip(1).join(' ').split('/').last;
          final list = p.files.putIfAbsent(r, () => []);
          if (f.isNotEmpty && !list.any((x) => x.$1 == f)) list.add((f, false));
        }
      case 'tool.failed':
        p.failures++; a.fails++;
        p.log.add(_LogLine(ts, r, '✗ ${d['tool']} ${d['error'] ?? ''}', kind: 2));
        p.messages.add((r, 'Tool failure: ${d['error'] ?? d['tool']}'));
      case 'tasks.updated': p.todos = List.from(d['todos'] ?? []);
      case 'agent.usage':
        if (d['delta'] == true) { a.tokens += (d['tokens'] as num? ?? 0).toInt(); } else { a.tokens = (d['total_tokens'] as num? ?? a.tokens).toInt(); }
      case 'agent.message': p.messages.add((r, '${d['text']}'));
      case 'project.finished':
        p..finished = true..ok = d['ok'] == true..end = ts..cost = (d['cost_usd'] as num?)?.toDouble()..turns = (d['turns'] as num?)?.toInt();
        p.result = d['ok'] == true ? 'delivered' : 'failed${d['error'] != null ? ' · ${d['error']}' : ''}';
        for (final x in p.agents.values) { if (x.status == 'working') x.status = 'done'; }
        if (d['summary'] != null && '${d['summary']}'.isNotEmpty) p.messages.add(('orchestrator', '${d['summary']}'));
        p.log.add(_LogLine(ts, 'amer', p.ok ? 'project finished ✓' : 'project failed ${d['error'] ?? d['subtype'] ?? ''}', kind: p.ok ? 1 : 2));
    }
    if (p.log.length > 500) p.log.removeRange(0, p.log.length - 500);
    if (!disposed) setState(() {});
  }

  // ---------- actions (administrators) ----------
  Future<void> _guard(Future<void> Function() f) async {
    try { await f(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); }
  }
  Future<void> _newProject() async {
    final t = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (c) => AlertDialog(
      title: const Text('New project for the agent team'),
      content: SizedBox(width: 520, child: TextField(controller: t, maxLines: 6, autofocus: true, decoration: const InputDecoration(
        hintText: 'e.g. Build a CLI that converts a DWDM inventory CSV into a GNPy topology JSON, with tests', border: OutlineInputBorder()))),
      actions: [TextButton(onPressed: () => Navigator.pop(c, false), child: const Text('Cancel')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: _red), onPressed: () => Navigator.pop(c, true), child: const Text('Run team'))]));
    if (ok == true && t.text.trim().length >= 10) { follow = true; await _guard(() => context.read<ApiService>().agentopsStart(t.text.trim())); }
  }

  // ---------- UI ----------
  @override
  Widget build(BuildContext c) {
    final p = _cur; final wide = MediaQuery.sizeOf(c).width > 900;
    return Scaffold(
      appBar: AppBar(title: const Text('Agent Ops'), actions: [
        if (order.isNotEmpty) SizedBox(width: wide ? 260 : 130, child: DropdownButton<String>(isExpanded: true, value: selected, underline: const SizedBox(), hint: const Text('Project'),
          items: [for (final id in order) DropdownMenuItem(value: id, child: Text(projects[id]!.name.isEmpty ? id : projects[id]!.name, overflow: TextOverflow.ellipsis))],
          onChanged: (v) => setState(() { selected = v; follow = false; }))),
        if (p != null && p.live) IconButton(tooltip: 'Stop project', icon: const Icon(Icons.stop_circle_outlined), onPressed: () => _guard(() => context.read<ApiService>().agentopsStop(p.id))),
        IconButton(tooltip: 'Replay sample run', icon: const Icon(Icons.replay), onPressed: () { follow = true; _guard(() => context.read<ApiService>().agentopsReplay()); }),
        if (wide) Padding(padding: const EdgeInsets.symmetric(horizontal: 8), child: FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: _red),
          onPressed: _newProject, icon: const Icon(Icons.play_arrow), label: const Text('Run team')))
        else IconButton(tooltip: 'Run team', color: _red, icon: const Icon(Icons.play_circle_fill), onPressed: _newProject),
      ]),
      body: p == null ? _empty(c) : wide ? _wide(c, p) : _narrow(c, p),
    );
  }

  Widget _empty(BuildContext c) => Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
    const Icon(Icons.hub_outlined, size: 48, color: _red), const SizedBox(height: 12),
    Text(connected ? 'No agent projects yet' : (err == null ? 'Connecting to the AI engine…' : 'Cannot reach the AI engine: $err'), textAlign: TextAlign.center),
    const SizedBox(height: 8), const Text('Run team starts a project; the replay button previews the screen with a sample recording.', textAlign: TextAlign.center, style: TextStyle(color: Colors.grey)),
  ])));

  Widget _wide(BuildContext c, _Project p) => Column(children: [
    _header(c, p), _rolesStrip(p), const Divider(height: 1),
    Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      SizedBox(width: 380, child: Column(children: [_plan(c, p, maxH: 230), Expanded(child: _terminal(p))])),
      const VerticalDivider(width: 1),
      Expanded(child: Column(children: [Expanded(child: _graph(p)), const Divider(height: 1), SizedBox(height: 150, child: _messages(c, p))])),
    ])),
  ]);

  Widget _narrow(BuildContext c, _Project p) => ListView(children: [
    _header(c, p), _rolesStrip(p), SizedBox(height: 360, child: _graph(p)), _plan(c, p),
    SizedBox(height: 320, child: _terminal(p)), SizedBox(height: 260, child: _messages(c, p)),
  ]);

  Widget _header(BuildContext c, _Project p) {
    final t = ((p.end ?? (p.replay && p.log.isNotEmpty ? p.log.last.ts : DateTime.now().millisecondsSinceEpoch / 1000)) - (p.start ?? 0)).clamp(0, 1e9);
    final clock = '${(t ~/ 60).toString().padLeft(2, '0')}:${(t % 60).toStringAsFixed(1).padLeft(4, '0')}';
    final badge = p.replay ? 'REPLAY · SAMPLE' : p.live ? 'LIVE' : p.ok ? 'FINISHED' : 'FAILED';
    return Padding(padding: const EdgeInsets.fromLTRB(16, 10, 16, 10), child: Wrap(spacing: 20, runSpacing: 10, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Row(mainAxisSize: MainAxisSize.min, children: [
          AnimatedBuilder(animation: anim, builder: (_, __) => Container(width: 8, height: 8, decoration: BoxDecoration(shape: BoxShape.circle,
            color: p.live ? _red.withValues(alpha: anim.value < .5 ? 1.0 : .25) : Colors.grey.shade700))),
          const SizedBox(width: 6),
          Text(badge, style: TextStyle(fontFamily: 'monospace', fontWeight: FontWeight.w700, letterSpacing: 1, fontSize: 12, color: p.live ? _red : null)),
          const SizedBox(width: 10), Text(clock, style: const TextStyle(fontFamily: 'monospace', fontSize: 12, color: Colors.grey)),
        ]),
        ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420), child: Text(p.name, overflow: TextOverflow.ellipsis, style: Theme.of(c).textTheme.titleMedium)),
      ]),
      _kpi('AGENTS ACTIVE', '${p.active}', sub: '/${p.roles.length}', red: true),
      _kpi('TOOL CALLS', '${p.toolCalls}'),
      _kpi('FAILURES', '${p.failures}', red: p.failures > 0),
      _kpi('TOKENS', _fmt(p.tokens)),
      _kpi('PLAN', '${p.todos.where((x) => x['status'] == 'completed').length}/${p.todos.length}', red: true),
      _kpi('COST (EXACT)', p.cost == null ? '—' : '\$${p.cost!.toStringAsFixed(2)}', sub: p.cost == null ? (p.replay ? ' n/a in replay' : p.finished ? '' : ' at finish') : ''),
    ]));
  }

  Widget _kpi(String l, String v, {String sub = '', bool red = false}) => Container(
    padding: const EdgeInsets.only(left: 12), decoration: BoxDecoration(border: Border(left: BorderSide(color: Colors.grey.shade300))),
    child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      Text(l, style: TextStyle(fontFamily: 'monospace', fontSize: 10, letterSpacing: 1, color: Colors.grey.shade600)),
      Text.rich(TextSpan(children: [TextSpan(text: v, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w600, color: red ? _red : null)),
        TextSpan(text: sub, style: const TextStyle(fontSize: 11, color: Colors.grey))])),
    ]));

  Widget _rolesStrip(_Project p) => SizedBox(height: 64, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), children: [
    for (final r in p.roles) _roleCard(r, p.agents[r]!)]));

  Widget _roleCard(String r, _Agent a) {
    final pct = a.status == 'done' ? 1.0 : a.status == 'working' ? math.min(.9, .1 + a.tools * .12) : 0.0;
    return Container(width: 170, margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.fromLTRB(8, 5, 8, 4),
      decoration: BoxDecoration(border: Border.all(color: a.status == 'working' ? _red : Colors.grey.shade300)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(r == 'orchestrator' ? 'AMER' : r.toUpperCase(), style: const TextStyle(fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1))),
          Text(a.status == 'working' ? '●' : a.status == 'done' ? '✓' : '·', style: TextStyle(fontSize: 10, color: a.status == 'idle' ? Colors.grey : _red))]),
        const SizedBox(height: 4),
        ClipRect(child: SizedBox(height: 5, child: LinearProgressIndicator(value: pct, color: _red, backgroundColor: Colors.grey.shade300))),
        const SizedBox(height: 3),
        Text('${a.runs} run · ${a.tools} tools · ${_fmt(a.tokens)} tok${a.fails > 0 ? ' · ${a.fails} fail' : ''}', maxLines: 1, overflow: TextOverflow.ellipsis,
          style: TextStyle(fontFamily: 'monospace', fontSize: 10, color: a.fails > 0 ? _red : Colors.grey.shade700)),
      ]));
  }

  Widget _section(String t, String s) => Padding(padding: const EdgeInsets.fromLTRB(14, 10, 14, 4), child: Row(children: [
    Text(t, style: TextStyle(fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700, letterSpacing: 1.5, color: Colors.grey.shade700)),
    const Spacer(), Text(s, style: const TextStyle(fontFamily: 'monospace', fontSize: 10, color: Colors.grey))]));

  Widget _plan(BuildContext c, _Project p, {double? maxH}) {
    final items = p.todos.isEmpty ? <Widget>[const ListTile(dense: true, title: Text("Waiting for the orchestrator's plan"))] : [
      for (final t in p.todos) ListTile(dense: true, visualDensity: VisualDensity.compact, minLeadingWidth: 14,
        leading: Text(t['status'] == 'completed' ? '✓' : t['status'] == 'in_progress' ? '▶' : '○', style: TextStyle(color: t['status'] == 'pending' ? Colors.grey : _red)),
        title: Text('${t['status'] == 'in_progress' && t['activeForm'] != null ? t['activeForm'] : t['content']}',
          style: TextStyle(fontWeight: t['status'] == 'in_progress' ? FontWeight.w600 : FontWeight.normal, color: t['status'] == 'pending' ? Colors.grey : null)))];
    final list = Column(mainAxisSize: MainAxisSize.min, children: items);
    return Column(mainAxisSize: MainAxisSize.min, children: [_section('PLAN', 'orchestrator · TodoWrite'),
      maxH == null ? list : ConstrainedBox(constraints: BoxConstraints(maxHeight: maxH), child: SingleChildScrollView(child: list))]);
  }

  Widget _terminal(_Project p) => Container(margin: const EdgeInsets.all(10), decoration: BoxDecoration(border: Border.all(color: Colors.grey.shade300)),
    child: Column(children: [
      Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 5), decoration: BoxDecoration(border: Border(bottom: BorderSide(color: Colors.grey.shade300))),
        child: Row(children: [Container(width: 10, height: 10, color: _red), const SizedBox(width: 8),
          const Text('agent-ops — live tool log', style: TextStyle(fontFamily: 'monospace', fontSize: 11)), const Spacer(),
          Text('${p.log.length}', style: const TextStyle(fontFamily: 'monospace', fontSize: 11, color: Colors.grey))])),
      Expanded(child: ListView.builder(reverse: true, padding: const EdgeInsets.all(6), itemCount: p.log.length, itemBuilder: (_, i) {
        final l = p.log[p.log.length - 1 - i];
        final ts = DateTime.fromMillisecondsSinceEpoch((l.ts * 1000).toInt()).toIso8601String().substring(11, 19);
        return Text.rich(TextSpan(style: const TextStyle(fontFamily: 'monospace', fontSize: 11, height: 1.5), children: [
          TextSpan(text: '[$ts] ', style: const TextStyle(color: Colors.grey)),
          TextSpan(text: '${(l.agent.length > 5 ? l.agent.substring(0, 5) : l.agent).padRight(5)} ', style: const TextStyle(fontWeight: FontWeight.w700)),
          TextSpan(text: l.text, style: TextStyle(color: l.kind == 1 ? _red : l.kind == 2 ? _red : l.kind == 3 ? Colors.grey : null, fontWeight: l.kind == 2 ? FontWeight.w700 : null)),
        ]), maxLines: 1, overflow: TextOverflow.ellipsis);
      })),
    ]));

  Widget _messages(BuildContext c, _Project p) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
    _section('AGENT MESSAGES', p.result == null ? '' : '${p.ok ? '✓' : '✗'} ${p.result}${p.turns != null ? ' · ${p.turns} turns' : ''}'),
    Expanded(child: ListView.builder(reverse: true, padding: const EdgeInsets.symmetric(horizontal: 14), itemCount: p.messages.length, itemBuilder: (_, i) {
      final m = p.messages[p.messages.length - 1 - i];
      return Padding(padding: const EdgeInsets.symmetric(vertical: 3), child: Text.rich(TextSpan(children: [
        TextSpan(text: '${m.$1 == 'orchestrator' ? 'AMER' : m.$1.toUpperCase()}  ', style: const TextStyle(color: _red, fontFamily: 'monospace', fontSize: 10, fontWeight: FontWeight.w700)),
        TextSpan(text: m.$2)])));
    })),
  ]);

  Widget _graph(_Project p) => Column(children: [
    _section('AGENT GRAPH', 'handoffs · tool calls · files'),
    Expanded(child: AnimatedBuilder(animation: anim, builder: (ctx, _) => CustomPaint(size: Size.infinite,
      painter: _GraphPainter(p, Theme.of(ctx).colorScheme.onSurface)))),
  ]);

  static String _fmt(int n) => n >= 1000000 ? '${(n / 1e6).toStringAsFixed(2)}M' : n >= 1000 ? '${(n / 1e3).toStringAsFixed(1)}k' : '$n';
}

class _GraphPainter extends CustomPainter {
  _GraphPainter(this.p, this.ink);
  final _Project p; final Color ink;

  Map<String, Offset> _layout(Size s) {
    final c = Offset(s.width / 2, s.height / 2);
    final others = p.roles.where((r) => r != 'orchestrator').toList();
    final rx = s.width * .36, ry = s.height * .36;
    return {'orchestrator': c, for (var i = 0; i < others.length; i++)
      others[i]: c + Offset(math.cos(-math.pi / 2 + i * 2 * math.pi / others.length) * rx, math.sin(-math.pi / 2 + i * 2 * math.pi / others.length) * ry)};
  }

  void _text(Canvas c, String t, Offset at, {double size = 11, Color? color, bool bold = false, bool center = true}) {
    final tp = TextPainter(text: TextSpan(text: t, style: TextStyle(fontFamily: 'monospace', fontSize: size, color: color ?? ink, fontWeight: bold ? FontWeight.w700 : null)),
      textDirection: TextDirection.ltr, maxLines: 1, ellipsis: '…')..layout(maxWidth: 200);
    tp.paint(c, center ? at - Offset(tp.width / 2, 0) : at);
  }

  @override
  void paint(Canvas c, Size s) {
    if (s.width < 50 || s.height < 50) return;
    final pos = _layout(s); final now = DateTime.now(); final phase = (now.millisecondsSinceEpoch % 1200) / 1200;
    final grey = Paint()..color = Colors.grey.shade400..strokeWidth = 1;
    final red = Paint()..color = _red..strokeWidth = 1.6;
    // team edges and files
    for (final r in p.roles) {
      if (r == 'orchestrator') continue;
      final a = p.agents[r]!, o = pos['orchestrator']!, q = pos[r]!;
      c.drawLine(o, q, a.status == 'working' ? red : grey);
      final out = (q - o) / ((q - o).distance == 0 ? 1 : (q - o).distance);
      final files = p.files[r] ?? const [];
      for (var i = 0; i < files.length; i++) {
        final ang = math.atan2(out.dy, out.dx) + (i - (files.length - 1) / 2) * .5;
        final f = q + Offset(math.cos(ang), math.sin(ang)) * 58;
        c.drawLine(q, f, Paint()..color = Colors.grey.shade300);
        c.drawRect(Rect.fromCenter(center: f, width: 8, height: 8), Paint()..color = Colors.white);
        c.drawRect(Rect.fromCenter(center: f, width: 8, height: 8), Paint()..color = Colors.grey.shade600..style = PaintingStyle.stroke);
        _text(c, files[i].$1, f + const Offset(7, -6), size: 9, color: Colors.grey, center: false);
      }
    }
    // handoff pulses travelling along edges (0.8 s each)
    p.shots.removeWhere((x) => now.difference(x.at).inMilliseconds > 800);
    for (final sh in p.shots) {
      final a = pos[sh.from], b = pos[sh.to]; if (a == null || b == null) continue;
      final t = now.difference(sh.at).inMilliseconds / 800;
      c.drawCircle(Offset.lerp(a, b, t)!, 5, Paint()..color = _red);
    }
    // agent nodes
    for (final r in p.roles) {
      final a = p.agents[r]!, q = pos[r]!, rad = r == 'orchestrator' ? 26.0 : 18.0;
      final work = a.status == 'working', done = a.status == 'done';
      if (work) c.drawCircle(q, rad + phase * 22, Paint()..color = _red.withValues(alpha: 1 - phase)..style = PaintingStyle.stroke);
      c.drawCircle(q, rad, Paint()..color = (work ? _red : Colors.white));
      c.drawCircle(q, rad, Paint()..color = (work || done ? _red : Colors.grey.shade700)..style = PaintingStyle.stroke..strokeWidth = r == 'orchestrator' ? 2.5 : 1.5);
      if (a.fails > 0) c.drawRect(Rect.fromLTWH(q.dx + rad - 5, q.dy - rad - 3, 8, 8), Paint()..color = _red);
      _text(c, r == 'orchestrator' ? 'AMER · orchestrator' : r, q + Offset(0, rad + 4), bold: r == 'orchestrator');
      _text(c, a.last.isNotEmpty ? a.last : a.status, q + Offset(0, rad + 18), size: 9, color: Colors.grey);
    }
  }

  @override bool shouldRepaint(covariant _GraphPainter old) => true;
}
