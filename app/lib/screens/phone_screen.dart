import '../services/locale.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Calls to ordinary phone numbers through the company SIP trunk.
/// Phones cannot do end-to-end encryption, so these calls are a separate, clearly labelled call type.
/// [bridgeRoomId]: join a meeting's phone dial-in bridge instead (docs/PHONE_DIALIN.md).
class PhoneScreen extends StatefulWidget { const PhoneScreen({super.key, this.bridgeRoomId}); final String? bridgeRoomId; @override State<PhoneScreen> createState() => _S(); }
class _S extends State<PhoneScreen> {
  final number = TextEditingController(text: '+971'); Map<String, dynamic>? policy; Room? room; String? err, status; bool muted = false;
  List<dynamic>? incoming; Timer? _poll;
  @override void initState() {
    super.initState(); context.read<ApiService>().phonePolicy().then((p) => setState(() => policy = p)).catchError((e) => setState(() => err = '$e'));
    if (widget.bridgeRoomId != null) { WidgetsBinding.instance.addPostFrameCallback((_) => _connect(() => context.read<ApiService>().postMap('/v1/phone/dialin/${Uri.encodeComponent(widget.bridgeRoomId!)}/join', {}), 'In the phone bridge')); }
    _checkIncoming(); _poll = Timer.periodic(const Duration(seconds: 5), (_) => _checkIncoming());
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
  Future<void> hangUp() async { await room?.disconnect(); setState(() { room = null; status = null; }); }
  @override void dispose() { _poll?.cancel(); room?.disconnect(); super.dispose(); }

  @override Widget build(BuildContext c) {
    final off = policy != null && (policy!['enabled'] != true || policy!['trunk_configured'] != true);
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Phone'))), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        MaterialBanner(leading: const Icon(Icons.lock_outline), content: const Text('Phone calls are encrypted to the phone network (TLS + SRTP) but not end-to-end. Use an Amer Teams call for confidential topics.'), actions: const [SizedBox.shrink()]),
        const SizedBox(height: 16),
        if (room == null && (incoming?.isNotEmpty ?? false)) Card(color: Colors.green.withValues(alpha: 0.12), child: Column(children: [
          const ListTile(leading: Icon(Icons.phone_callback), title: Text('Incoming calls to the company line')),
          for (final i in incoming!) ListTile(title: Text('${i['caller']}'), subtitle: Text('waiting ${((DateTime.now().millisecondsSinceEpoch ~/ 1000 - (i['arrived_at'] as int)) ).clamp(0, 3600)} s'),
            trailing: FilledButton.icon(onPressed: () => _connect(() => context.read<ApiService>().postMap('/v1/phone/inbound/${Uri.encodeComponent(i['call'])}/answer', {}), 'Connected to ${i['caller']}'), icon: const Icon(Icons.call), label: Text(L.t(context, 'Answer')))),
        ])),
        if (off) Text(policy!['enabled'] != true ? 'Phone calls are switched off by your administrator.' : 'No phone line is configured yet.'),
        if (policy != null && !off) Text('Allowed: ${(policy!['allowed_prefixes'] as List).join(', ')}', style: Theme.of(c).textTheme.bodySmall),
        TextField(controller: number, enabled: room == null && !off, keyboardType: TextInputType.phone, style: Theme.of(c).textTheme.headlineSmall,
          decoration: const InputDecoration(labelText: 'Number in international format')),
        if (status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(status!, style: Theme.of(c).textTheme.titleMedium)),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
        const SizedBox(height: 24),
        if (room == null) FilledButton.icon(onPressed: off ? null : call, icon: const Icon(Icons.call), label: Text(L.t(context, 'Call')))
        else Wrap(spacing: 12, children: [
          IconButton.filledTonal(icon: Icon(muted ? Icons.mic_off : Icons.mic), onPressed: () { muted = !muted; room!.localParticipant?.setMicrophoneEnabled(!muted); setState(() {}); }),
          IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.red), icon: const Icon(Icons.call_end), onPressed: hangUp)]),
      ])))));
  }
}
