import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Feature flags (administrators): switch each Phase 3 feature on or off, or roll it out to a percentage,
/// for every tenant ("*") or one tenant. The server enforces them; the app hides what is off.
class FlagsScreen extends StatefulWidget {
  const FlagsScreen({super.key});
  @override State<FlagsScreen> createState() => _S();
}
class _S extends State<FlagsScreen> {
  Map<String, dynamic>? d; String tenant = '*'; String? err;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { try { final x = await api.adminFlags(); if (mounted) setState(() => d = x); } catch (e) { if (mounted) setState(() => err = '$e'); } }
  Map<String, dynamic>? row(String f) => ((d?['rows'] as List?) ?? const []).cast<Map<String, dynamic>>().where((r) => r['tenant'] == tenant && r['feature'] == f).firstOrNull;
  @override Widget build(BuildContext c) {
    if (d == null) return Scaffold(appBar: AppBar(title: const Text('Feature flags')), body: Center(child: err != null ? Text(err!) : const CircularProgressIndicator()));
    final feats = (d!['features'] as Map).cast<String, String>(), defs = (d!['defaults'] as Map).cast<String, bool>();
    final tenants = {'*', ...((d!['rows'] as List).map((r) => '${r['tenant']}'))};
    return Scaffold(appBar: AppBar(title: const Text('Feature flags')), body: ListView(children: [
      Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        const Text('Applies to '), const SizedBox(width: 8),
        DropdownButton<String>(value: tenant, items: [for (final t in tenants) DropdownMenuItem(value: t, child: Text(t == '*' ? 'every tenant' : t))], onChanged: (v) => setState(() => tenant = v!)),
        const Spacer(),
        TextButton(onPressed: () async { final t = TextEditingController();
          final v = await showDialog<String>(context: c, builder: (x) => AlertDialog(title: const Text('Tenant id'), content: TextField(controller: t, autofocus: true),
            actions: [FilledButton(onPressed: () => Navigator.pop(x, t.text.trim()), child: const Text('Use'))]));
          if (v != null && v.isNotEmpty) setState(() => tenant = v); }, child: const Text('Other tenant')),
      ])),
      for (final f in feats.entries) () {
        final r = row(f.key); final on = r?['enabled'] as bool? ?? defs[f.key] ?? false; final pct = (r?['rollout_pct'] as num?)?.toInt() ?? 100;
        Future<void> save(bool e, int p) async { try { await api.setFlag(tenant, f.key, e, p); await _load(); } catch (x) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$x'))); } }
        return Card(margin: const EdgeInsets.fromLTRB(12, 4, 12, 4), child: Column(children: [
          SwitchListTile(title: Text(f.value), subtitle: Text(r == null ? 'Default (${defs[f.key] == true ? 'on' : 'off'})' : 'Set for ${tenant == '*' ? 'every tenant' : tenant}'), value: on, onChanged: (v) => save(v, pct)),
          if (on) Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Row(children: [const Text('Rollout'),
            const Spacer(), DropdownButton<int>(value: const [0, 5, 10, 25, 50, 75, 100].contains(pct) ? pct : 100,
              items: [for (final p in const [0, 5, 10, 25, 50, 75, 100]) DropdownMenuItem(value: p, child: Text('$p% of people'))], onChanged: (v) => save(on, v!))])),
        ]));
      }(),
    ]));
  }
}
