import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Calls to ordinary phone numbers through the company SIP trunk.
/// Phones cannot do end-to-end encryption, so these calls are a separate, clearly labelled call type.
class PhoneScreen extends StatefulWidget { const PhoneScreen({super.key}); @override State<PhoneScreen> createState() => _S(); }
class _S extends State<PhoneScreen> {
  final number = TextEditingController(text: '+971'); Map<String, dynamic>? policy; Room? room; String? err, status; bool muted = false;
  @override void initState() { super.initState(); context.read<ApiService>().phonePolicy().then((p) => setState(() => policy = p)).catchError((e) => setState(() => err = '$e')); }
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
  @override void dispose() { room?.disconnect(); super.dispose(); }

  @override Widget build(BuildContext c) {
    final off = policy != null && (policy!['enabled'] != true || policy!['trunk_configured'] != true);
    return Scaffold(appBar: AppBar(title: const Text('Phone')), body: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 420),
      child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
        MaterialBanner(leading: const Icon(Icons.lock_outline), content: const Text('Phone calls are encrypted to the phone network (TLS + SRTP) but not end-to-end. Use an Amer Teams call for confidential topics.'), actions: const [SizedBox.shrink()]),
        const SizedBox(height: 16),
        if (off) Text(policy!['enabled'] != true ? 'Phone calls are switched off by your administrator.' : 'No phone line is configured yet.'),
        if (policy != null && !off) Text('Allowed: ${(policy!['allowed_prefixes'] as List).join(', ')}', style: Theme.of(c).textTheme.bodySmall),
        TextField(controller: number, enabled: room == null && !off, keyboardType: TextInputType.phone, style: Theme.of(c).textTheme.headlineSmall,
          decoration: const InputDecoration(labelText: 'Number in international format')),
        if (status != null) Padding(padding: const EdgeInsets.only(top: 16), child: Text(status!, style: Theme.of(c).textTheme.titleMedium)),
        if (err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
        const SizedBox(height: 24),
        if (room == null) FilledButton.icon(onPressed: off ? null : call, icon: const Icon(Icons.call), label: const Text('Call'))
        else Wrap(spacing: 12, children: [
          IconButton.filledTonal(icon: Icon(muted ? Icons.mic_off : Icons.mic), onPressed: () { muted = !muted; room!.localParticipant?.setMicrophoneEnabled(!muted); setState(() {}); }),
          IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.red), icon: const Icon(Icons.call_end), onPressed: hangUp)]),
      ])))));
  }
}
