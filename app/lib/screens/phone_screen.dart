import '../services/locale.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import 'package:matrix/matrix.dart' as mx;
import '../services/matrix_service.dart';
import 'chat_screen.dart' show ChatScreen;

/// Picks a person from the people I share chats with.
Future<String?> askPerson(BuildContext c, String title) async {
  final cl = c.read<MatrixService>().client; final seen = <String>{}; final people = <mx.User>[];
  for (final r in cl.rooms.where((r) => r.membership == mx.Membership.join)) { for (final u in r.getParticipants()) { if (u.id != cl.userID && seen.add(u.id)) people.add(u); } }
  people.sort((a, b) => a.calcDisplayname().compareTo(b.calcDisplayname()));
  return showDialog<String>(context: c, builder: (d) => SimpleDialog(title: Text(title), children: [
    for (final u in people) SimpleDialogOption(onPressed: () => Navigator.pop(d, u.id), child: ListTile(dense: true, title: Text(u.calcDisplayname()), subtitle: Text(u.id)))]));
}

/// Voicemail inbox: unanswered calls to the company line, recorded and posted encrypted by the voicemail service.
class VoicemailScreen extends StatelessWidget {
  const VoicemailScreen({super.key});
  @override Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Voicemail')), body: FutureBuilder<Map<String, dynamic>>(
    future: c.read<ApiService>().getMap('/v1/phone/voicemail/room'), builder: (_, s) {
      if (!s.hasData) return Center(child: s.hasError ? Text('${s.error}') : const CircularProgressIndicator());
      final room = c.read<MatrixService>().client.getRoomById('${s.data!['room_id']}');
      if (room == null) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Voicemail is not set up, or you are not in the voicemail chat. Ask your administrator.')));
      return FutureBuilder<mx.Timeline>(future: room.getTimeline(limit: 500), builder: (_, t) {
        if (!t.hasData) return const Center(child: CircularProgressIndicator());
        final vms = t.data!.events.where((e) => e.messageType == mx.MessageTypes.Audio && e.body.startsWith('Voicemail')).toList();
        if (vms.isEmpty) return const Center(child: Text('No voicemail.'));
        return ListView(children: [for (final e in vms) ListTile(leading: const Icon(Icons.voicemail), title: Text(e.body),
          subtitle: Text(e.originServerTs.toLocal().toString().substring(0, 16)),
          trailing: TextButton(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id))), child: const Text('Play in chat')))]);
      });
    }));
}

/// Calls to ordinary phone numbers through the company SIP trunk.
/// Phones cannot do end-to-end encryption, so these calls are a separate, clearly labelled call type.
/// [bridgeRoomId]: join a meeting's phone dial-in bridge instead (docs/PHONE_DIALIN.md).
class PhoneScreen extends StatefulWidget { const PhoneScreen({super.key, this.bridgeRoomId}); final String? bridgeRoomId; @override State<PhoneScreen> createState() => _S(); }
class _S extends State<PhoneScreen> {
  final number = TextEditingController(text: '+971'); Map<String, dynamic>? policy; Room? room; String? err, status; bool muted = false;
  List<dynamic>? incoming; Timer? _poll; String? holding;   // the company-line call I am on (for transfer and park)
  List<String> speed = [];
  @override void initState() {
    super.initState(); context.read<ApiService>().phonePolicy().then((p) => setState(() => policy = p)).catchError((e) => setState(() => err = '$e'));
    if (widget.bridgeRoomId != null) { WidgetsBinding.instance.addPostFrameCallback((_) => _connect(() => context.read<ApiService>().postMap('/v1/phone/dialin/${Uri.encodeComponent(widget.bridgeRoomId!)}/join', {}), 'In the phone bridge')); }
    _loadSpeed(); _checkIncoming(); _poll = Timer.periodic(const Duration(seconds: 5), (_) => _checkIncoming());
  }
  /// Inbound calls for the hunt group (docs/PHONE_DIALIN.md); hidden for anyone not in it.
  Future<void> _checkIncoming() async {
    try { final r = await context.read<ApiService>().listGet('/v1/phone/inbound'); if (mounted) setState(() => incoming = r.where((x) => x['answered_by'] == null).toList()); }
    catch (_) { _poll?.cancel(); }
  }
  Future<void> _connect(Future<Map<String, dynamic>> Function() get, String connected) async {
    setState(() { err = null; status = 'Connecting…'; });
    try {
      final r = await get();
      final rm = Room(); await rm.connect(r['url'], r['token']); await rm.localParticipant?.setMicrophoneEnabled(true);
      rm.addListener(() { if (mounted) setState(() => status = rm.remoteParticipants.isEmpty ? 'Waiting for the other side…' : connected); });
      setState(() { room = rm; status = connected; });
    } catch (e) { setState(() { err = '$e'.replaceFirst('Exception: ', ''); status = null; }); }
  }
  Future<void> call() async {
    setState(() { err = null; status = 'Calling…'; });
    try {
      final r = await context.read<ApiService>().dial(number.text);
      final rm = Room();
      await rm.connect(r['url'], r['token']);
      await rm.localParticipant?.setMicrophoneEnabled(true);
      rm.addListener(() => setState(() => status = rm.remoteParticipants.isEmpty ? 'Ringing…' : 'Connected'));
      setState(() { room = rm; status = 'Ringing…'; });
    } catch (e) { setState(() { err = '$e'.replaceFirst('Exception: ', ''); status = null; }); }
  }
  Future<void> hangUp() async { await room?.disconnect(); setState(() { room = null; status = null; holding = null; }); }
  Future<void> _transfer() async {
    final who = await askPerson(context, 'Transfer to'); if (who == null || holding == null || !mounted) return;
    try { await context.read<ApiService>().postMap('/v1/phone/inbound/${Uri.encodeComponent(holding!)}/transfer', {'to': who}); await room?.disconnect();
      setState(() { room = null; holding = null; status = 'Transferred. Their app shows the call now.'; }); }
    catch (e) { setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  Future<void> _park() async {
    if (holding == null) return;
    try { final r = await context.read<ApiService>().postMap('/v1/phone/inbound/${Uri.encodeComponent(holding!)}/park', {}); await room?.disconnect();
      setState(() { room = null; holding = null; status = 'Parked. Pick it up anywhere with code ${r['code']}'; }); }
    catch (e) { setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  Future<void> _pickup() async {
    final code = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Pick up a parked call'),
      content: TextField(controller: code, autofocus: true, keyboardType: TextInputType.number, maxLength: 3, decoration: const InputDecoration(labelText: 'Park code')),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Pick up'))]));
    if (ok != true || !mounted) return;
    await _connect(() async { final r = await context.read<ApiService>().postMap('/v1/phone/pickup/${code.text.trim()}', {}); holding = '${r['call']}'; return r; }, 'Picked up');
  }
  Future<void> _forwarding() async {
    final api = context.read<ApiService>(); Map<String, dynamic> cur;
    try { cur = await api.getMap('/v1/phone/forwarding'); } catch (e) { setState(() => err = '$e'); return; }
    if (!mounted) return;
    var mode = '${cur['mode']}'; String? target = cur['target'] as String?;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Call forwarding'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final (k, l) in const [('off', 'Ring me'), ('also_ring', 'Ring me and someone else'), ('forward', 'Forward to someone'), ('voicemail', 'Send to voicemail')])
          RadioListTile<String>(dense: true, value: k, groupValue: mode, title: Text(l), onChanged: (v) => set(() => mode = v!)),
        if (mode == 'forward' || mode == 'also_ring') ListTile(leading: const Icon(Icons.person_outline), title: Text(target ?? 'Choose a person'), onTap: () async { final p = await askPerson(d, 'Who?'); if (p != null) set(() => target = p); }),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))])));
    if (ok != true) return;
    try { await api.putMap('/v1/phone/forwarding', {'mode': mode, 'target': target}); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Call forwarding saved'))); }
    catch (e) { setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  Future<void> _loadSpeed() async { try { final d = context.read<MatrixService>().client.accountData['com.amerteams.speed_dial']?.content['numbers']; if (d is List) setState(() => speed = d.map((x) => '$x').toList()); } catch (_) {} }
  Future<void> _saveSpeed(List<String> n) async { final c = context.read<MatrixService>().client; await c.setAccountData(c.userID!, 'com.amerteams.speed_dial', {'numbers': n}); setState(() => speed = n); }
  @override void dispose() { _poll?.cancel(); room?.disconnect(); super.dispose(); }

  @override Widget build(BuildContext c) {
    final off = policy != null && (policy!['enabled'] != true || policy!['trunk_configured'] != true);
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Phone')), actions: [
        IconButton(tooltip: 'Voicemail', icon: const Icon(Icons.voicemail), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const VoicemailScreen()))),
        IconButton(tooltip: 'Pick up a parked call', icon: const Icon(Icons.local_parking), onPressed: room == null ? _pickup : null),
        IconButton(tooltip: 'Call forwarding', icon: const Icon(Icons.phone_forwarded), onPressed: _forwarding)]), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        MaterialBanner(leading: const Icon(Icons.lock_outline), content: const Text('Phone calls are encrypted to the phone network (TLS + SRTP) but not end-to-end. Use an Amer Teams call for confidential topics.'), actions: const [SizedBox.shrink()]),
        const SizedBox(height: 16),
        if (room == null && (incoming?.isNotEmpty ?? false)) Card(color: Colors.green.withValues(alpha: 0.12), child: Column(children: [
          const ListTile(leading: Icon(Icons.phone_callback), title: Text('Incoming calls to the company line')),
          for (final i in incoming!) ListTile(title: Text('${i['caller']}${i['park_code'] != null ? ' · parked, code ${i['park_code']}' : ''}'), subtitle: Text('${i['transferred_by'] != null ? 'Transferred to you · ' : ''}waiting ${((DateTime.now().millisecondsSinceEpoch ~/ 1000 - (i['arrived_at'] as int)) ).clamp(0, 3600)} s'),
            trailing: FilledButton.icon(onPressed: () { holding = '${i['call']}'; _connect(() => context.read<ApiService>().postMap('/v1/phone/inbound/${Uri.encodeComponent(i['call'])}/answer', {}), 'Connected to ${i['caller']}'); }, icon: const Icon(Icons.call), label: Text(L.t(context, 'Answer')))),
        ])),
        if (off) Text(policy!['enabled'] != true ? 'Phone calls are switched off by your administrator.' : 'No phone line is configured yet.'),
        if (policy != null && !off) Text('Allowed: ${(policy!['allowed_prefixes'] as List).join(', ')}', style: Theme.of(c).textTheme.bodySmall),
        TextField(controller: number, enabled: room == null && !off, keyboardType: TextInputType.phone, style: Theme.of(c).textTheme.headlineSmall,
          decoration: const InputDecoration(labelText: 'Number in international format')),
        if (status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(status!, style: Theme.of(c).textTheme.titleMedium)),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
        const SizedBox(height: 24),
        if (room == null) Column(children: [
          FilledButton.icon(onPressed: off ? null : call, icon: const Icon(Icons.call), label: Text(L.t(context, 'Call'))),
          const SizedBox(height: 16),
          Wrap(spacing: 6, runSpacing: 6, alignment: WrapAlignment.center, children: [
            for (final n in speed) InputChip(avatar: const Icon(Icons.star, size: 16), label: Text(n), onPressed: () => number.text = n, onDeleted: () => _saveSpeed(speed.where((x) => x != n).toList())),
            ActionChip(avatar: const Icon(Icons.star_border, size: 16), label: const Text('Add to speed dial'), onPressed: () { final n = number.text.trim(); if (n.length > 4 && !speed.contains(n)) _saveSpeed([...speed, n]); }),
          ])])
        else Wrap(spacing: 12, children: [
          IconButton.filledTonal(icon: Icon(muted ? Icons.mic_off : Icons.mic), onPressed: () { muted = !muted; room!.localParticipant?.setMicrophoneEnabled(!muted); setState(() {}); }),
          if (holding != null) IconButton.filledTonal(tooltip: 'Transfer', icon: const Icon(Icons.phone_forwarded), onPressed: _transfer),
          if (holding != null) IconButton.filledTonal(tooltip: 'Park', icon: const Icon(Icons.local_parking), onPressed: _park),
          IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.red), icon: const Icon(Icons.call_end), onPressed: hangUp)]),
      ])))));
  }
}
