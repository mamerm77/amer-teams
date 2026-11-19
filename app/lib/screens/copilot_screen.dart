import 'skills_screen.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:matrix/matrix.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';
import 'workflows_screen.dart';
import 'personal_agents_screen.dart';
import '../services/feature_flags.dart';

/// Opens (or creates) the encrypted direct chat with the Amer assistant account.
Future<void> openAmerChat(BuildContext c) async {
  final m = c.read<MatrixService>(); final nav = Navigator.of(c); final msg = ScaffoldMessenger.of(c);
  try {
    final a = await c.read<ApiService>().assistant();
    if (a['available'] != true) { msg.showSnackBar(const SnackBar(content: Text('Amer chat is not set up on this server yet (administrator: start the amer-bot service).'))); return; }
    final uid = a['user_id'] as String;
    final roomId = m.client.getDirectChatFromUserId(uid) ?? await m.client.startDirectChat(uid, enableEncryption: true);
    nav.push(MaterialPageRoute(builder: (_) => ChatScreen(roomId: roomId)));
  } catch (e) { msg.showSnackBar(SnackBar(content: Text('Could not open the chat with Amer: $e'))); }
}

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
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Amer co-pilot'), actions: [
    ListenableBuilder(listenable: Flags.instance, builder: (_, __) => Row(mainAxisSize: MainAxisSize.min, children: [
      if (Flags.instance.on('personal_agents')) TextButton.icon(icon: const Icon(Icons.groups_2_outlined), label: const Text('My agents'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const PersonalAgentsScreen()))),
      TextButton.icon(icon: const Icon(Icons.storefront_outlined), label: const Text('Skills and marketplace'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SkillsScreen()))),
      if (Flags.instance.on('workflows')) TextButton.icon(icon: const Icon(Icons.account_tree_outlined), label: const Text('Workflows'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const WorkflowsScreen()))),
    ])),
      Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton.icon(onPressed: () => openAmerChat(c), icon: const Icon(Icons.chat_bubble_outline), label: const Text('Chat with Amer')))]),
    body: Column(children: [
    const ListTile(dense: true, leading: Icon(Icons.info_outline), title: Text('Tip: chat with Amer like a colleague, or @mention Amer in any group chat after adding it to the group.')),
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
