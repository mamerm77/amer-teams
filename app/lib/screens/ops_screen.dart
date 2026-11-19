import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Performance and high availability from live probes of every service (orchestrator /v1/ops/status).
class OpsScreen extends StatefulWidget { const OpsScreen({super.key}); @override State<OpsScreen> createState() => _S(); }
class _S extends State<OpsScreen> {
  Map<String, dynamic>? d; List alerts = []; String? err; Timer? t;
  @override void initState() { super.initState(); _load(); t = Timer.periodic(const Duration(seconds: 5), (_) => _load()); }
  @override void dispose() { t?.cancel(); super.dispose(); }
  Future<void> _load() async { if (!mounted) return; final api = context.read<ApiService>(); try { final r = await api.ops(); final a = await api.alerts(); if (mounted) setState(() { d = r; alerts = a; err = null; }); } catch (e) { if (mounted) setState(() => err = '$e'); } }

  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    if (d == null) return Scaffold(appBar: AppBar(title: const Text('Performance & availability')), body: Center(child: Text(err ?? 'Loading live telemetry…')));
    final now = d!['now'], avail = Map<String, dynamic>.from(d!['availability_pct']), hist = List.from(d!['history']);
    return Scaffold(appBar: AppBar(title: const Text('Performance & availability')), body: ListView(padding: const EdgeInsets.all(12), children: [
      Wrap(spacing: 12, runSpacing: 12, children: [
        _kpi(c, 'Active calls', '${now['media']['active_calls'] ?? '–'}'),
        _kpi(c, 'In calls now', '${now['media']['participants'] ?? '–'}'),
        for (final a in avail.entries) _kpi(c, '${a.key} availability', '${a.value}%'),
      ]),
      const SizedBox(height: 16), Text('Alerts', style: Theme.of(c).textTheme.titleMedium),
      if (alerts.isEmpty) const ListTile(leading: Icon(Icons.verified, color: Colors.green), title: Text('No active alerts')),
      for (final a in alerts) Card(color: a['severity'] == 'critical' ? cs.errorContainer : cs.tertiaryContainer, child: ListTile(
        leading: Icon(a['severity'] == 'critical' ? Icons.report : Icons.warning_amber),
        title: Text(a['name'] ?? 'Alert'), subtitle: Text(a['summary'] ?? ''), trailing: Text((a['severity'] ?? '').toString().toUpperCase()))),
      const SizedBox(height: 16), Text('Services', style: Theme.of(c).textTheme.titleMedium),
      for (final s in now['services']) Card(child: ListTile(
        leading: Icon(s['up'] ? Icons.check_circle : Icons.error, color: s['up'] ? Colors.green : cs.error),
        title: Text(s['service']), subtitle: Text(s['up'] ? 'Up' : 'DOWN — ${s['error'] ?? 'unreachable'}'),
        trailing: Text(s['latency_ms'] == null ? '–' : '${s['latency_ms']} ms'))),
      const SizedBox(height: 16), Text('Chat server latency, last ${hist.length * 5 ~/ 60} min', style: Theme.of(c).textTheme.titleMedium),
      SizedBox(height: 140, child: CustomPaint(painter: _Spark([for (final h in hist) (h['latency']['chat (Synapse)'] as num?)?.toDouble()], cs.primary, cs.outlineVariant), size: Size.infinite)),
      const SizedBox(height: 16), Text('AI agents', style: Theme.of(c).textTheme.titleMedium),
      for (final a in now['agents']) ListTile(dense: true, title: Text(a['name']), subtitle: Text('${a['calls']} calls · ${a['errors']} errors'), trailing: Text('${a['latency_ms']} ms')),
    ]));
  }
  Widget _kpi(BuildContext c, String l, String v) => SizedBox(width: 170, child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(l, style: Theme.of(c).textTheme.labelSmall), Text(v, style: Theme.of(c).textTheme.headlineSmall)]))));
}

class _Spark extends CustomPainter {
  _Spark(this.v, this.col, this.grid); final List<double?> v; final Color col, grid;
  @override void paint(Canvas c, Size s) {
    final g = Paint()..color = grid; for (var i = 1; i < 4; i++) c.drawLine(Offset(0, s.height * i / 4), Offset(s.width, s.height * i / 4), g);
    final pts = v.whereType<double>().toList(); if (pts.length < 2) return;
    final mx = pts.reduce((a, b) => a > b ? a : b) * 1.2; final p = Path();
    for (var i = 0; i < v.length; i++) { final y = v[i]; if (y == null) continue;
      final o = Offset(s.width * i / (v.length - 1), s.height - s.height * y / mx); i == 0 ? p.moveTo(o.dx, o.dy) : p.lineTo(o.dx, o.dy); }
    c.drawPath(p, Paint()..color = col..style = PaintingStyle.stroke..strokeWidth = 2);
  }
  @override bool shouldRepaint(_) => true;
}
