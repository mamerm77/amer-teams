import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import '../services/search_index.dart';

/// Live expertise map (docs/EXPERTISE.md): find who knows about something; publish what you know.
class ExpertiseScreen extends StatefulWidget {
  const ExpertiseScreen({super.key});
  @override State<ExpertiseScreen> createState() => _S();
}
class _S extends State<ExpertiseScreen> {
  final q = TextEditingController(); List<dynamic>? found; List<String> mine = []; String about = ''; List<String> suggested = [];
  @override void initState() { super.initState(); _mine(); }
  Future<void> _mine() async {
    try { final r = await context.read<ApiService>().getMap('/v1/expertise/me'); if (mounted) setState(() { mine = (r['topics'] as List).cast<String>(); about = '${r['about']}'; }); } catch (_) {}
  }
  Future<void> _search() async { try { final r = await context.read<ApiService>().listGet('/v1/expertise?q=${Uri.encodeQueryComponent(q.text)}'); if (mounted) setState(() => found = r); } catch (_) {} }
  Future<void> _suggest() async {
    final me = context.read<MatrixService>().client.userID ?? '';
    final t = await SearchIndex.instance.myTopTerms(me);
    if (mounted) setState(() => suggested = t.where((x) => !mine.contains(x)).toList());
    if (t.isEmpty && mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Not enough of your messages on this device yet')));
  }
  Future<void> _save() async { await context.read<ApiService>().putMap('/v1/expertise/me', {'topics': mine, 'about': about}); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Your topics are published'))); }
  @override
  Widget build(BuildContext c) {
    final m = context.read<MatrixService>();
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Who knows about…'))), body: ListView(padding: const EdgeInsets.all(12), children: [
      TextField(controller: q, decoration: InputDecoration(hintText: 'e.g. ROADM, 800G ZR+, vendor SLAs', suffixIcon: IconButton(tooltip: 'Search', icon: const Icon(Icons.search), onPressed: _search)), onSubmitted: (_) => _search()),
      if (found != null && found!.isEmpty) const ListTile(title: Text('Nobody has published that topic yet')),
      for (final p in found ?? const []) ListTile(leading: const Icon(Icons.person_search),
        title: Text(m.client.getRoomById('')?.unsafeGetUserFromMemoryOrFallback(p['user_id']).calcDisplayname() ?? '${p['user_id']}'),
        subtitle: Text([if ('${p['about']}'.isNotEmpty) p['about'], (p['topics'] as List).join(' · ')].join('\n')),
        trailing: IconButton(tooltip: 'Message', icon: const Icon(Icons.chat_bubble_outline), onPressed: () async { final rid = await m.client.startDirectChat(p['user_id']); if (c.mounted) Navigator.pop(c, rid); })),
      const Divider(height: 32),
      Text('What you know about', style: Theme.of(c).textTheme.titleMedium),
      const Text('Only what you publish here is shared, with people in your organisation. Suggestions are worked out on this device from what you wrote and are never sent unless you add them.', style: TextStyle(fontSize: 12)),
      TextFormField(initialValue: about, decoration: const InputDecoration(labelText: 'One line about you'), onChanged: (v) => about = v),
      Wrap(spacing: 6, children: [for (final t in mine) InputChip(label: Text(t), onDeleted: () => setState(() => mine.remove(t)))]),
      TextField(decoration: const InputDecoration(hintText: 'Add a topic and press Enter'), onSubmitted: (v) { if (v.trim().isNotEmpty) setState(() => mine.add(v.trim().toLowerCase())); }),
      Wrap(spacing: 6, children: [for (final t in suggested) ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(t), onPressed: () => setState(() { mine.add(t); suggested.remove(t); }))]),
      Row(children: [TextButton.icon(onPressed: _suggest, icon: const Icon(Icons.auto_awesome), label: Text(L.t(context, 'Suggest from my messages'))), const Spacer(), FilledButton(onPressed: _save, child: Text(L.t(context, 'Publish')))]),
    ]));
  }
}
