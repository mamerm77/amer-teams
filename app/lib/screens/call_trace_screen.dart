import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Administrators: every call with outcome and quality; tap for the full trace
/// (client signalling ladder, media-server events, per-participant audio/video quality).
class CallTraceScreen extends StatefulWidget { const CallTraceScreen({super.key}); @override State<CallTraceScreen> createState() => _S(); }
class _S extends State<CallTraceScreen> {
  List calls = []; String? err, outcome;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final c = await api.adminCalls(outcome: outcome); setState(() { calls = c; err = null; }); }
    catch (e) { setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  static String t(num? s) => s == null ? '–' : DateTime.fromMillisecondsSinceEpoch((s * 1000).round()).toLocal().toString().substring(0, 19);
  static Color oc(String? o) => switch (o) { 'completed' => Colors.green, 'in_progress' || 'ringing' => Colors.blue, 'missed' || 'cancelled' => Colors.orange, _ => Colors.red };

  @override Widget build(BuildContext ctx) => Scaffold(
    appBar: AppBar(title: Text(L.t(context, 'Call trace')), actions: [
      PopupMenuButton<String?>(icon: const Icon(Icons.filter_list), onSelected: (v) { outcome = v; _load(); }, itemBuilder: (_) => [
        const PopupMenuItem(value: null, child: Text('All')),
        for (final o in ['completed', 'missed', 'declined', 'busy', 'cancelled', 'failed']) PopupMenuItem(value: o, child: Text(o))]),
      IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
    body: err != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(err!)))
      : RefreshIndicator(onRefresh: _load, child: ListView(children: [
        const ListTile(dense: true, leading: Icon(Icons.lock), title: Text('Content is end-to-end encrypted. This trace shows signalling, timing and media quality only, unless the user\'s organisation has enabled compliance archiving.')),
        for (final c in calls) ListTile(
          leading: Icon(c['kind'] == 'meeting' ? Icons.groups : c['media'] == 'video' ? Icons.videocam : Icons.call, color: oc(c['outcome'])),
          title: Text('${c['caller'] ?? '?'} → ${c['callee'] ?? (c['kind'] == 'meeting' ? 'meeting' : '?')}'),
          subtitle: Text('${t(c['started'])} · ${c['outcome']}${c['duration_s'] != null ? ' · ${c['duration_s']} s' : ''}'
              '${c['avg_mos'] != null ? ' · MOS ${c['avg_mos']}' : ''}${c['max_loss_pct'] != null ? ' · loss ${c['max_loss_pct']}%' : ''} · ${c['tenant']}'),
          onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => _Trace(c['call_id'])))),
        if (calls.isEmpty) const Padding(padding: EdgeInsets.all(32), child: Center(child: Text('No calls recorded yet'))),
      ])));
}

class _Trace extends StatelessWidget {
  const _Trace(this.id); final String id;
  @override Widget build(BuildContext ctx) => Scaffold(appBar: AppBar(title: Text(id)), body: FutureBuilder<Map<String, dynamic>>(
    future: ctx.read<ApiService>().callTrace(id),
    builder: (ctx, s) {
      if (s.hasError) return Center(child: Text('${s.error}'.replaceFirst('Exception: ', '')));
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final ev = s.data!['events'] as List, q = s.data!['quality'] as List;
      final t0 = ev.isNotEmpty ? (ev.first['t'] as num) : 0;
      return ListView(children: [
        ListTile(title: Text('Signalling and media events (${ev.length})', style: Theme.of(ctx).textTheme.titleSmall)),
        for (final e in ev) ListTile(dense: true,
          leading: Text('+${((e['t'] as num) - t0).toStringAsFixed(2)}s', style: const TextStyle(fontFamily: 'monospace')),
          title: Text('${e['source'] == 'media' ? '⚙ media server' : e['user']}${e['device'] != null && e['device'] != '' ? ' [${e['device']}]' : ''}  ${e['direction'] == 'in' ? '⇐' : e['direction'] == 'out' ? '⇒' : '•'} ${e['event']}'),
          subtitle: Text({for (final k in (e as Map).keys) if (!{'t', 'source', 'user', 'device', 'event', 'direction'}.contains(k)) k: e[k]}.entries.map((x) => '${x.key}=${x.value}').join('  '),
            style: TextStyle(color: e['encrypted'] == false ? Colors.red : null))),
        const Divider(),
        ListTile(title: Text('Media quality (${q.length} samples)', style: Theme.of(ctx).textTheme.titleSmall)),
        SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(columns: const [
          DataColumn(label: Text('+s')), DataColumn(label: Text('User')), DataColumn(label: Text('Stream')), DataColumn(label: Text('Codec')),
          DataColumn(label: Text('kbit/s')), DataColumn(label: Text('Loss %')), DataColumn(label: Text('Jitter ms')), DataColumn(label: Text('RTT ms')), DataColumn(label: Text('MOS'))],
          rows: [for (final x in q) DataRow(cells: [
            DataCell(Text(((x['t'] as num) - t0).toStringAsFixed(0))), DataCell(Text('${x['user']}')), DataCell(Text('${x['kind']} ${x['dir']}')),
            DataCell(Text('${x['codec'] ?? ''}')), DataCell(Text(_f(x['kbps']))), DataCell(Text(_f(x['loss_pct']), style: TextStyle(color: (x['loss_pct'] ?? 0) > 3 ? Colors.red : null))),
            DataCell(Text(_f(x['jitter_ms']))), DataCell(Text(_f(x['rtt_ms']))), DataCell(Text(_f(x['mos']), style: TextStyle(color: (x['mos'] ?? 5) < 3.6 ? Colors.red : null)))])])),
        Padding(padding: const EdgeInsets.all(16), child: Text('Content: ${s.data!['content']}', style: Theme.of(ctx).textTheme.bodySmall)),
      ]);
    }));
  static String _f(Object? v) => v == null ? '–' : (v as num).toStringAsFixed(1);
}
