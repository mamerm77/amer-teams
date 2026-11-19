import '../ui/depth.dart';
import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Usage analytics for administrators (docs/ANALYTICS.md): aggregates only, small groups folded together.
class AnalyticsScreen extends StatefulWidget {
  const AnalyticsScreen({super.key});
  @override State<AnalyticsScreen> createState() => _S();
}
class _S extends State<AnalyticsScreen> {
  int days = 30; Map<String, dynamic>? d; String? err;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    setState(() { d = null; err = null; });
    try { final r = await context.read<ApiService>().analytics(days); if (mounted) setState(() => d = r); } catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Widget _bars(String title, List<dynamic> rows, String key, String unit) {
    final max = rows.fold<num>(1, (m, r) => (r[key] as num) > m ? r[key] as num : m);
    return DepthCard(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(title, style: Theme.of(context).textTheme.titleMedium), const SizedBox(height: 8),
      if (rows.isEmpty) const Text('No data in this period'),
      for (final r in rows.length > 31 ? rows.sublist(rows.length - 31) : rows) Padding(padding: const EdgeInsets.symmetric(vertical: 2), child: Row(children: [
        SizedBox(width: 84, child: Text('${r['day']}'.substring(5), style: const TextStyle(fontSize: 12))),
        Expanded(child: LinearProgressIndicator(value: (r[key] as num) / max, minHeight: 10, borderRadius: BorderRadius.circular(4))),
        SizedBox(width: 70, child: Text(' ${r[key]} $unit', style: const TextStyle(fontSize: 12)))]))])));
  }
  Widget _tile(String label, String value) => DepthCard(child: SizedBox(width: 170, child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text(value, style: Theme.of(context).textTheme.headlineSmall), Text(label, style: const TextStyle(fontSize: 12))]))));
  @override
  Widget build(BuildContext c) {
    final x = d;
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Usage analytics')), actions: [
      DropdownButton<int>(value: days, items: const [DropdownMenuItem(value: 7, child: Text('7 days')), DropdownMenuItem(value: 30, child: Text('30 days')), DropdownMenuItem(value: 90, child: Text('90 days'))],
        onChanged: (v) { days = v!; _load(); }), const SizedBox(width: 12)]),
      body: err != null ? Center(child: Text(err!)) : x == null ? const Center(child: CircularProgressIndicator()) : ListView(padding: const EdgeInsets.all(12), children: [
        const Text('Totals only. No message content, no individual rankings; any group of fewer than five people is shown as "Other".', style: TextStyle(fontSize: 12)),
        Wrap(children: [
          _tile('active people', '${x['active']['people']}'),
          _tile('calls and meetings', '${(x['calls']['per_day'] as List).fold<num>(0, (s, r) => s + r['calls'])}'),
          _tile('meeting minutes', '${(x['calls']['per_day'] as List).fold<num>(0, (s, r) => s + r['minutes'])}'),
          _tile('average call quality (MOS)', '${x['calls']['quality']['avg_mos'] ?? '–'}'),
          _tile('AI requests', '${(x['ai']['per_day'] as List).fold<num>(0, (s, r) => s + r['requests'])}'),
          _tile('workflow runs', '${x['workflows']['runs']}'),
          _tile('decisions recorded', '${x['decisions']}'),
        ]),
        _bars('Active people per day', x['active']['per_day'], 'people', ''),
        _bars('Calls and meetings per day', x['calls']['per_day'], 'calls', ''),
        DepthCard(child: Column(children: [const ListTile(title: Text('Feature adoption')),
          for (final f in x['features'] as List) ListTile(dense: true, title: Text('${f['name']}'), trailing: Text('${f['people'] ?? '<5'} people · ${f['count']} uses'))])),
        DepthCard(child: Column(children: [const ListTile(title: Text('AI by agent')),
          for (final f in x['ai']['by_agent'] as List) ListTile(dense: true, title: Text('${f['name']}'), trailing: Text('${f['people'] ?? '<5'} people · ${f['count']} requests'))])),
      ]));
  }
}
