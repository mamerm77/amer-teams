import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

/// Operator mode for telecoms (docs/OPERATOR_MODE.md): on call now, open incidents, declare an incident and open
/// its end-to-end encrypted war room, MTTA / MTTR.
const kIncident = 'com.amerteams.incident';

class OperatorScreen extends StatefulWidget {
  const OperatorScreen({super.key});
  @override State<OperatorScreen> createState() => _S();
}
class _S extends State<OperatorScreen> {
  List<dynamic>? oncall, open; Map<String, dynamic>? metrics; String? err;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final api = context.read<ApiService>();
    try {
      final a = await api.listGet('/v1/oncall'), b = await api.listGet('/v1/incidents?open_only=true'), m = await api.getMap('/v1/incidents/metrics');
      if (mounted) setState(() { oncall = a; open = b; metrics = m; err = null; });
    } catch (e) { if (mounted) setState(() => err = '$e'); }
  }

  /// Declare (or take over an alert's incident): number from the server, war room created on this device.
  Future<void> _declare({Map? fromAlert}) async {
    var sev = '${fromAlert?['severity'] ?? 'P2'}'; final title = TextEditingController(), service = TextEditingController(text: '${fromAlert?['service'] ?? ''}'), impact = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text(fromAlert == null ? 'Declare an incident' : 'Open war room for ${fromAlert['number']}'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        SegmentedButton<String>(segments: const [ButtonSegment(value: 'P1', label: Text('P1')), ButtonSegment(value: 'P2', label: Text('P2')), ButtonSegment(value: 'P3', label: Text('P3')), ButtonSegment(value: 'P4', label: Text('P4'))],
          selected: {sev}, onSelectionChanged: (v) => set(() => sev = v.first)),
        TextField(controller: title, decoration: const InputDecoration(labelText: 'What is happening, e.g. OSNR drop on AUH–DXB span')),
        TextField(controller: service, decoration: InputDecoration(labelText: 'Service or network', helperText: oncall?.isNotEmpty == true ? 'Rotas: ${oncall!.map((o) => o['service']).join(', ')}' : null)),
        TextField(controller: impact, decoration: const InputDecoration(labelText: 'Customer impact (optional), e.g. 1,200 FTTH, 3 enterprise circuits')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Open war room'))])));
    if (ok != true || !mounted) return;
    final api = context.read<ApiService>(); final m = context.read<MatrixService>();
    try {
      final Map<String, dynamic> d;
      if (fromAlert == null) { d = await api.postMap('/v1/incidents', {'severity': sev, 'service': service.text.trim().isEmpty ? 'network' : service.text.trim()}); }
      else { d = {'number': fromAlert['number'], 'on_call': oncall?.firstWhere((o) => o['service'] == fromAlert['service'], orElse: () => {})['on_call']}; }
      final number = '${d['number']}';
      final page = <String>{if (d['on_call'] != null) '${d['on_call']}', if (sev == 'P1' && d['escalation'] != null) '${d['escalation']}'}..remove(m.client.userID);
      final rid = await m.createRoom(name: '$number · $sev · ${title.text.trim().isEmpty ? service.text : title.text.trim()}', invite: page.toList());
      if (m.client.getRoomById(rid) == null) await m.client.waitForRoomInSync(rid, join: true);
      final room = m.client.getRoomById(rid)!;
      await room.client.setRoomStateWithKey(rid, kIncident, '', {'number': number, 'severity': sev, 'service': service.text, 'state': 'investigating', 'impact': impact.text, 'declared_at': DateTime.now().toIso8601String()});
      await api.postMap('/v1/incidents/$number/room', {'room_id': rid});
      // the page: a mention is "high" priority, so it rings through quiet hours (docs/NOTIFICATIONS.md)
      await room.sendEvent({'msgtype': 'm.text', 'body': '🚨 $number $sev declared: ${title.text}\nImpact: ${impact.text.isEmpty ? 'being assessed' : impact.text}\nPaging ${page.isEmpty ? 'nobody (no rota for this service)' : page.join(', ')}. Acknowledge in the banner above.',
        'm.mentions': {'user_ids': page.toList()}});
      if (!mounted) return;
      Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(roomId: rid)));
      _load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not declare: $e'))); }
  }

  Color _sev(String s) => switch (s) { 'P1' => Colors.red, 'P2' => Colors.orange, 'P3' => Colors.amber, _ => Colors.blueGrey };

  @override
  Widget build(BuildContext c) {
    final rooms = context.watch<MatrixService>().client.rooms.where((r) => r.getState(kIncident) != null).toList();
    return Scaffold(appBar: AppBar(title: const Text('Operator'), actions: [IconButton(tooltip: 'Refresh', icon: const Icon(Icons.refresh), onPressed: _load)]),
      floatingActionButton: FloatingActionButton.extended(backgroundColor: Colors.red, foregroundColor: Colors.white, onPressed: () => _declare(), icon: const Icon(Icons.campaign), label: const Text('Declare incident')),
      body: err != null ? Center(child: Text(err!)) : oncall == null ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _load, child: ListView(children: [
        const ListTile(title: Text('On call now')),
        if (oncall!.isEmpty) const ListTile(dense: true, title: Text('No rotas yet'), subtitle: Text('An administrator sets them up (PUT /v1/oncall/rotas)')),
        for (final o in oncall!) ListTile(dense: true, leading: const Icon(Icons.support_agent), title: Text('${o['service']}'), subtitle: Text('${o['on_call']} · next ${o['next']}${'${o['escalation']}'.isNotEmpty ? ' · escalation ${o['escalation']}' : ''}')),
        const Divider(),
        ListTile(title: Text('Open incidents (${open!.length})')),
        for (final i in open!) () {
          final room = rooms.where((r) => r.getState(kIncident)?.content['number'] == i['number']).firstOrNull;
          return ListTile(leading: CircleAvatar(backgroundColor: _sev('${i['severity']}'), child: Text('${i['severity']}', style: const TextStyle(color: Colors.white, fontSize: 12))),
            title: Text('${i['number']} · ${room?.getLocalizedDisplayname().split(' · ').last ?? i['service']}'),
            subtitle: Text('${i['state']}${i['acked_by'] != null ? ' · acknowledged by ${i['acked_by']}' : ' · not acknowledged'}${i['source'] == 'alert' ? ' · from monitoring' : ''}'),
            trailing: room != null ? const Icon(Icons.chevron_right) : FilledButton.tonal(onPressed: () => _declare(fromAlert: i), child: const Text('Open war room')),
            onTap: room == null ? null : () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id))));
        }(),
        const Divider(),
        const ListTile(title: Text('Last 90 days')),
        for (final e in (metrics ?? {}).entries) ListTile(dense: true, leading: CircleAvatar(radius: 12, backgroundColor: _sev(e.key), child: Text(e.key, style: const TextStyle(color: Colors.white, fontSize: 10))),
          title: Text('${e.value['incidents']} incidents · ${e.value['open']} open'), subtitle: Text('MTTA ${e.value['mtta_min'] ?? '–'} min · MTTR ${e.value['mttr_min'] ?? '–'} min')),
      ])));
  }
}

/// Shown at the top of a war room: state, acknowledge, move forward, draft the post-incident review.
class IncidentBanner extends StatelessWidget {
  const IncidentBanner({super.key, required this.room, required this.onReview});
  final Room room; final VoidCallback onReview;
  static const next = {'investigating': 'identified', 'identified': 'mitigated', 'mitigated': 'resolved'};
  @override
  Widget build(BuildContext c) {
    final s = room.getState(kIncident)?.content; if (s == null) return const SizedBox.shrink();
    final st = '${s['state']}'; final resolved = st == 'resolved';
    Future<void> move(String? to, {bool ack = false}) async {
      try {
        await c.read<ApiService>().postMap('/v1/incidents/${s['number']}', {if (to != null) 'state': to, 'ack': ack});
        if (to != null) await room.client.setRoomStateWithKey(room.id, kIncident, '', {...s, 'state': to});
        await room.sendTextEvent(ack ? '✋ Acknowledged: I am on it' : '➡️ ${s['number']} is now $to');
      } catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'))); }
    }
    return Material(color: resolved ? Colors.green.withValues(alpha: 0.15) : Colors.red.withValues(alpha: 0.12), child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
      Text('${s['number']} · ${s['severity']} · $st${'${s['impact'] ?? ''}'.isNotEmpty ? ' · impact: ${s['impact']}' : ''}', style: const TextStyle(fontWeight: FontWeight.w600)),
      if (!resolved) OutlinedButton(onPressed: () => move(null, ack: true), child: const Text('Acknowledge')),
      if (!resolved && next[st] != null) FilledButton.tonal(onPressed: () => move(next[st]), child: Text('Mark ${next[st]}')),
      if (!resolved && st != 'mitigated') TextButton(onPressed: () => move('resolved'), child: const Text('Resolve')),
      TextButton.icon(onPressed: onReview, icon: const Icon(Icons.description_outlined, size: 18), label: const Text('Post-incident review')),
    ])));
  }
}
