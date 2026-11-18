import 'package:flutter/material.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/api_service.dart';
import '../services/call_service.dart';
import '../services/matrix_service.dart';

/// Encrypted call / meeting. Captions are produced on-device; Amer only receives the
/// transcript if the user explicitly invites it to take minutes.
class CallScreen extends StatefulWidget { const CallScreen({super.key, required this.roomId, this.callId}); final String roomId; final String? callId; @override State<CallScreen> createState() => _S(); }
class _S extends State<CallScreen> {
  SecureCall? call; String? err; bool mic = true, cam = true, captions = false, amerNotes = false;
  final stt = SpeechToText(); final transcript = StringBuffer(); String liveCaption = '';
  @override void initState() { super.initState(); _start(); }
  Future<void> _start() async {
    final api = context.read<ApiService>(); final room = context.read<MatrixService>().client.getRoomById(widget.roomId)!;
    try {
      call = widget.callId == null ? await SecureCall.start(api, room) : await SecureCall.join(api, room, widget.callId!);
      call!.lk.addListener(() => setState(() {}));
      setState(() {});
    } catch (e) { setState(() => err = '$e'); }
  }
  Future<void> _toggleCaptions() async {
    if (!captions && await stt.initialize()) {
      stt.listen(onResult: (r) { setState(() => liveCaption = r.recognizedWords); if (r.finalResult) transcript.writeln('Me: ${r.recognizedWords}'); },
                 listenOptions: SpeechListenOptions(partialResults: true, onDevice: true));
      setState(() => captions = true);
    } else { await stt.stop(); setState(() => captions = false); }
  }
  Future<void> _leave() async {
    await stt.stop(); await call?.leave();
    if (amerNotes && transcript.isNotEmpty && mounted) {
      final r = await context.read<ApiService>().ask('Write minutes', context: transcript.toString(), agent: 'minutes');
      final room = context.read<MatrixService>().client.getRoomById(widget.roomId)!;
      await room.sendTextEvent('📝 Minutes by Amer\n\n${r['answer']}');   // stays E2EE in the room
    }
    if (mounted) Navigator.pop(context);
  }
  @override
  Widget build(BuildContext c) {
    if (err != null) return Scaffold(appBar: AppBar(), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Could not start the encrypted call: $err'))));
    if (call == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));
    final lk = call!.lk;
    final tracks = <VideoTrack>[
      if (lk.localParticipant?.videoTrackPublications.firstOrNull?.track case final VideoTrack t) t,
      for (final p in lk.remoteParticipants.values) for (final pub in p.videoTrackPublications) if (pub.track case final VideoTrack t) t];
    return Scaffold(
      appBar: AppBar(title: Row(children: [
        Icon(Icons.lock, color: call!.encrypted ? Colors.green : Colors.red), const SizedBox(width: 6),
        Text(call!.encrypted ? 'End-to-end encrypted' : 'NOT ENCRYPTED'),
      ]), actions: [Center(child: Padding(padding: const EdgeInsets.only(right: 16), child: Text('Safety code ${call!.safetyCode}', style: const TextStyle(fontFamily: 'monospace'))))]),
      body: Column(children: [
        if (amerNotes) MaterialBanner(content: const Text('Amer is taking notes. Your transcript will be sent to the AI engine when the call ends.'), actions: [TextButton(onPressed: () => setState(() => amerNotes = false), child: const Text('Stop'))]),
        Expanded(child: GridView.count(crossAxisCount: MediaQuery.sizeOf(c).width > 900 ? 3 : 2, padding: const EdgeInsets.all(8), mainAxisSpacing: 8, crossAxisSpacing: 8,
          children: [for (final t in tracks) ClipRRect(borderRadius: BorderRadius.circular(12), child: VideoTrackRenderer(t))])),
        if (captions) Container(width: double.infinity, padding: const EdgeInsets.all(12), color: Theme.of(c).colorScheme.surfaceContainerHighest, child: Text(liveCaption.isEmpty ? 'Listening on-device…' : liveCaption)),
        SafeArea(child: Wrap(alignment: WrapAlignment.center, spacing: 12, children: [
          IconButton.filledTonal(icon: Icon(mic ? Icons.mic : Icons.mic_off), onPressed: () { mic = !mic; lk.localParticipant?.setMicrophoneEnabled(mic); setState(() {}); }),
          IconButton.filledTonal(icon: Icon(cam ? Icons.videocam : Icons.videocam_off), onPressed: () { cam = !cam; lk.localParticipant?.setCameraEnabled(cam); setState(() {}); }),
          IconButton.filledTonal(icon: const Icon(Icons.screen_share), onPressed: () => lk.localParticipant?.setScreenShareEnabled(true)),
          IconButton.filledTonal(tooltip: 'On-device captions', icon: Icon(captions ? Icons.closed_caption : Icons.closed_caption_off), onPressed: _toggleCaptions),
          IconButton.filledTonal(tooltip: 'Invite Amer to take minutes', icon: Icon(Icons.auto_awesome, color: amerNotes ? Colors.amber : null), onPressed: () => setState(() => amerNotes = !amerNotes)),
          IconButton.filled(style: IconButton.styleFrom(backgroundColor: Colors.red), icon: const Icon(Icons.call_end), onPressed: _leave),
        ])),
      ]),
    );
  }
}
