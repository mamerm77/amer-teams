import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import 'call_screen.dart';

class ChatScreen extends StatefulWidget { const ChatScreen({super.key, required this.roomId}); final String roomId; @override State<ChatScreen> createState() => _S(); }
class _S extends State<ChatScreen> {
  Timeline? tl; final input = TextEditingController();
  Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  @override void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) async {
    tl = await room.getTimeline(onUpdate: () => setState(() {})); setState(() {}); }); }
  @override void dispose() { tl?.cancelSubscriptions(); super.dispose(); }

  Future<void> send() async {
    final t = input.text.trim(); if (t.isEmpty) return; input.clear();
    await context.read<MatrixService>().sendText(room, t);
  }
  Future<void> attach() async {
    final files = await FilePicker.pickFiles();
    if (files.isEmpty) return;
    final f = files.first;
    final bytes = await f.xFile.readAsBytes();
    if (!mounted) return;
    await context.read<MatrixService>().sendFile(room, f.name, bytes);   // encrypted before upload
  }
  Future<void> download(Event e) async {
    final file = await e.downloadAndDecryptAttachment();   // decrypts locally
    final saved = await FilePicker.saveFile(fileName: file.name, bytes: file.bytes);
    if (mounted && saved != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${file.name}')));
  }
  Future<void> summarise() async {
    final text = (tl?.events ?? []).where((e) => e.type == EventTypes.Message).take(80).toList().reversed
        .map((e) => '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${e.body}').join('\n');
    final r = await context.read<ApiService>().ask('Summarise this thread', context: text, agent: 'summ');
    if (!mounted) return;
    showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: SingleChildScrollView(child: Text(r['answer']))));
  }

  @override
  Widget build(BuildContext c) {
    final evs = (tl?.events ?? []).where((e) => e.type == EventTypes.Message || e.type == kCallInviteEvent || e.type == 'com.amerteams.meeting').toList();
    return Scaffold(
      appBar: AppBar(title: Row(children: [const Icon(Icons.lock, size: 16), const SizedBox(width: 6), Flexible(child: Text(room.getLocalizedDisplayname()))]), actions: [
        IconButton(tooltip: 'Summarise with Amer', icon: const Icon(Icons.auto_awesome), onPressed: summarise),
        IconButton(tooltip: 'Encrypted call', icon: const Icon(Icons.videocam), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id)))),
      ]),
      body: Column(children: [
        Expanded(child: ListView.builder(reverse: true, itemCount: evs.length, itemBuilder: (_, i) {
          final e = evs[i];
          if (e.type == kCallInviteEvent) {
            return ListTile(leading: const Icon(Icons.videocam), title: const Text('Encrypted call'),
              trailing: FilledButton(child: const Text('Join'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, callId: e.content['call_id'] as String)))));
          }
          if (e.type == 'com.amerteams.meeting') {
            return ListTile(leading: const Icon(Icons.event), title: Text(e.content['title'] as String? ?? 'Meeting'), subtitle: Text('${e.content['start']} · ${e.content['duration_min']} min'));
          }
          if (e.messageType == MessageTypes.File || e.messageType == MessageTypes.Image) {
            return ListTile(leading: const Icon(Icons.insert_drive_file), title: Text(e.body), subtitle: const Text('Encrypted file'),
              trailing: IconButton(icon: const Icon(Icons.download), onPressed: () => download(e)));
          }
          final me = e.senderId == room.client.userID;
          return Align(alignment: me ? Alignment.centerRight : Alignment.centerLeft, child: Container(
            margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), padding: const EdgeInsets.all(10),
            constraints: const BoxConstraints(maxWidth: 520),
            decoration: BoxDecoration(color: me ? Theme.of(c).colorScheme.primaryContainer : Theme.of(c).colorScheme.surfaceContainerHighest, borderRadius: BorderRadius.circular(12)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              if (!me) Text(e.senderFromMemoryOrFallback.calcDisplayname(), style: Theme.of(c).textTheme.labelSmall),
              Text(e.type == EventTypes.Encrypted ? '🔒 Unable to decrypt (keys not yet shared)' : e.body)])));
        })),
        SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          Expanded(child: TextField(controller: input, decoration: const InputDecoration(hintText: 'Encrypted message', border: OutlineInputBorder()), onSubmitted: (_) => send())),
          IconButton(tooltip: 'Share encrypted file', icon: const Icon(Icons.attach_file), onPressed: attach),
          IconButton(icon: const Icon(Icons.send), onPressed: send)]))),
      ]),
    );
  }
}
