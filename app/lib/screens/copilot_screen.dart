import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

class CopilotScreen extends StatefulWidget { const CopilotScreen({super.key}); @override State<CopilotScreen> createState() => _S(); }
class _S extends State<CopilotScreen> {
  final msgs = <(bool, String, List)>[(false, 'I am Amer. Ask me to summarise, translate, draft or plan. Each answer shows which agents handled it.', [])];
  final input = TextEditingController(); bool busy = false;
  Future<void> send([String? s]) async {
    final t = (s ?? input.text).trim(); if (t.isEmpty) return; input.clear();
    setState(() { msgs.add((true, t, [])); busy = true; });
    try { final r = await context.read<ApiService>().ask(t); msgs.add((false, r['answer'], r['trace'] ?? [])); }
    catch (e) { msgs.add((false, 'Error: $e', [])); }
    setState(() => busy = false);
  }
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Amer co-pilot')), body: Column(children: [
    Expanded(child: ListView(padding: const EdgeInsets.all(12), children: [for (final m in msgs) Align(alignment: m.$1 ? Alignment.centerRight : Alignment.centerLeft, child: Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      SelectableText(m.$2),
      if (m.$3.isNotEmpty) Wrap(spacing: 4, children: [for (final s in m.$3) Chip(visualDensity: VisualDensity.compact, label: Text('${s['agent']}${s['ms'] > 0 ? ' · ${s['ms']} ms' : ''}'))])]))))])),
    if (busy) const LinearProgressIndicator(),
    Wrap(spacing: 6, children: [for (final s in ['Translate “OSNR margin is fine” to Arabic', 'Draft a reply declining Thursday']) ActionChip(label: Text(s), onPressed: () => send(s))]),
    SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: input, decoration: const InputDecoration(hintText: 'Ask Amer…', border: OutlineInputBorder()), onSubmitted: (_) => send())),
      IconButton(icon: const Icon(Icons.send), onPressed: () => send())]))),
  ]));
}
