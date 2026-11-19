import '../ui/depth.dart';
import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/catch_up.dart';
import '../services/matrix_service.dart';
import '../services/feature_flags.dart';
import 'chat_screen.dart';

/// "What did I miss": one card per chat with unread messages, ranked mentions first, then direct chats.
class CatchUpScreen extends StatefulWidget {
  const CatchUpScreen({super.key});
  @override State<CatchUpScreen> createState() => _S();
}

class _S extends State<CatchUpScreen> {
  Map<String, dynamic>? d; String? err; bool busy = false;
  @override void initState() { super.initState(); _run(); }

  Future<void> _run({bool refresh = false}) async {
    if (!Flags.instance.on('ai_plain_server')) { setState(() => err = 'Your organisation does not allow encrypted chats to go to the AI service. Catch me up needs an attested enclave, which is not deployed yet.'); return; }
    setState(() { busy = true; err = null; });
    try {
      final r = await CatchUp(context.read<MatrixService>().client, context.read<ApiService>()).run(refresh: refresh);
      if (mounted) setState(() => d = r);
    } catch (e) {
      if (mounted) setState(() => err = 'Could not build your catch-up: ${'$e'.replaceFirst('Exception: ', '')}');
    } finally { if (mounted) setState(() => busy = false); }
  }

  static const _kindIcon = {'direct': Icons.person_outline, 'channel': Icons.tag, 'meeting': Icons.videocam_outlined, 'group': Icons.group_outlined};

  Widget _card(BuildContext c, Map x) {
    final cs = Theme.of(c).colorScheme;
    final dec = (x['decisions'] as List? ?? const []).cast<String>(), reply = (x['needs_reply'] as List? ?? const []).cast<String>();
    final st = x['status'] as String;
    return DepthCard(margin: const EdgeInsets.fromLTRB(12, 6, 12, 6), child: InkWell(borderRadius: BorderRadius.circular(12),
      onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: x['room_id'] as String))),
      child: Padding(padding: const EdgeInsets.all(14), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(_kindIcon[x['kind']] ?? Icons.chat_bubble_outline, size: 20, color: cs.primary), const SizedBox(width: 8),
          Expanded(child: Text(x['name'] as String? ?? '', style: const TextStyle(fontWeight: FontWeight.w600), overflow: TextOverflow.ellipsis)),
          if ((x['mentions'] as int? ?? 0) > 0) Padding(padding: const EdgeInsets.only(right: 6),
            child: Chip(visualDensity: VisualDensity.compact, avatar: const Icon(Icons.alternate_email, size: 14), label: Text('${x['mentions']}'))),
          Text('${x['unread']} new', style: TextStyle(color: cs.outline, fontSize: 12)),
        ]),
        if ((x['summary'] as String? ?? '').isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8),
          child: Text(x['summary'] as String, style: TextStyle(color: st == 'ok' ? null : cs.outline, fontStyle: st == 'ok' ? null : FontStyle.italic))),
        if (dec.isNotEmpty) ...[const SizedBox(height: 8), Text('Decisions', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.primary)),
          for (final t in dec) Text('• $t')],
        if (reply.isNotEmpty) ...[const SizedBox(height: 8), Text('Waiting for your reply', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: cs.error)),
          for (final t in reply) Text('• $t')],
        if (st == 'label') Padding(padding: const EdgeInsets.only(top: 6), child: Row(children: [Icon(Icons.lock, size: 14, color: cs.outline), const SizedBox(width: 4),
          Text('Sensitivity label: kept out of AI', style: TextStyle(fontSize: 12, color: cs.outline))])),
      ]))));
  }

  @override Widget build(BuildContext c) {
    final cards = (d?['cards'] as List? ?? const []).cast<Map>(), more = (d?['more'] as List? ?? const []).cast<Map>();
    final t = d?['totals'] as Map? ?? const {};
    final noAi = cards.isNotEmpty && cards.every((x) => x['status'] == 'no_ai' || x['status'] == 'label' || x['status'] == 'empty');
    return Scaffold(
      appBar: AppBar(title: Text(L.t(context, 'Catch me up')), actions: [
        IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: busy ? null : () => _run(refresh: true))]),
      body: busy && d == null ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
          CircularProgressIndicator(), SizedBox(height: 12), Text('Reading your unread chats on this device…')]))
        : err != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
            Text(err!, textAlign: TextAlign.center), const SizedBox(height: 12), FilledButton(onPressed: _run, child: Text(L.t(context, 'Try again')))])))
        : cards.isEmpty ? const Center(child: Column(mainAxisSize: MainAxisSize.min, children: [
            Icon(Icons.done_all, size: 48, color: Colors.green), SizedBox(height: 8), Text("You're all caught up")]))
        : RefreshIndicator(onRefresh: () => _run(refresh: true), child: ListView(padding: const EdgeInsets.only(bottom: 24), children: [
            Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text(
              '${t['messages'] ?? 0} new messages in ${t['rooms'] ?? 0} chats${(t['mentions'] ?? 0) > 0 ? ' · ${t['mentions']} mention you' : ''}${d?['cached'] == true ? ' · from 30 min cache' : ''}',
              style: Theme.of(c).textTheme.titleSmall)),
            Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 8), child: Text(
              noAi ? 'AI summaries are not set up on this server, so chats are listed by priority without summaries.'
                   : 'Unread messages were decrypted on this device and sent to your organisation\'s AI service only for this digest (not end-to-end encrypted; no enclave yet). Confidential and Restricted chats are never sent.',
              style: TextStyle(fontSize: 12, color: Theme.of(c).colorScheme.outline))),
            for (final x in cards) _card(c, x),
            if (more.isNotEmpty) ...[
              Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('${more.length} more chats', style: Theme.of(c).textTheme.titleSmall)),
              for (final x in more) ListTile(dense: true, title: Text(x['name'] as String? ?? ''), trailing: Text('${x['unread']} new'),
                onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: x['room_id'] as String))))],
          ])),
    );
  }
}
