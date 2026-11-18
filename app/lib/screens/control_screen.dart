import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Live control plane: agent states, latency, enable/disable, audit log. Refreshes every 3 s.
class ControlScreen extends StatefulWidget { const ControlScreen({super.key}); @override State<ControlScreen> createState() => _S(); }
class _S extends State<ControlScreen> {
  List agents = [], audit = []; Timer? t; String? err;
  @override void initState() { super.initState(); _load(); t = Timer.periodic(const Duration(seconds: 3), (_) => _load()); }
  @override void dispose() { t?.cancel(); super.dispose(); }
  Future<void> _load() async { try { final a = context.read<ApiService>(); final r = await Future.wait([a.agents(), a.audit()]); setState(() { agents = r[0]; audit = r[1]; err = null; }); } catch (e) { setState(() => err = '$e'); } }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Control centre')), body: ListView(padding: const EdgeInsets.all(12), children: [
    if (err != null) Text('Cannot reach the AI engine: $err', style: TextStyle(color: Theme.of(c).colorScheme.error)),
    Text('Agents', style: Theme.of(c).textTheme.titleMedium),
    for (final a in agents) Card(child: SwitchListTile(value: a['enabled'], title: Text(a['name']),
      subtitle: Text('${a['calls']} calls · ${a['errors']} errors · ${a['latency_ms']} ms avg'),
      onChanged: (v) async { await context.read<ApiService>().toggleAgent(a['id'], v); _load(); })),
    const SizedBox(height: 16), Text('Audit log', style: Theme.of(c).textTheme.titleMedium),
    for (final e in audit) ListTile(dense: true, title: Text('${e['action']}  ${e['detail']}'), subtitle: Text('${e['user']} · ${DateTime.fromMillisecondsSinceEpoch(e['ts'] * 1000)}')),
  ]));
}
