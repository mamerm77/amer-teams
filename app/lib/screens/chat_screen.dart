import 'dart:async';
import 'dart:typed_data';
import 'dart:io';
import 'package:audioplayers/audioplayers.dart';
import 'package:file_picker/file_picker.dart';
import 'package:path_provider/path_provider.dart';
import 'package:record/record.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../services/api_service.dart';
import '../services/call_manager.dart';
import '../services/matrix_service.dart';
import '../services/meeting_service.dart';
import 'call_screen.dart';

/// Encrypted chat: replies, reactions, edit, delete, typing indicator, read receipts,
/// photo previews (decrypted on device), files, search, call and meeting cards.
class ChatScreen extends StatefulWidget { const ChatScreen({super.key, required this.roomId}); final String roomId; @override State<ChatScreen> createState() => _S(); }
class _S extends State<ChatScreen> {
  Timeline? tl; final input = TextEditingController(); final searchCtl = TextEditingController();
  Event? replyTo, editing; bool searching = false; Timer? typingOff; bool typing = false;
  final _thumbs = <String, Future<Uint8List?>>{};
  final _rec = AudioRecorder(); DateTime? _recStart; String? _recPath;
  final _player = AudioPlayer(); String? _playing;
  Future<CachedPresence>? _presence;
  Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  String get me => room.client.userID!;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      tl = await room.getTimeline(onUpdate: () { if (mounted) setState(() {}); _markRead(); });
      final dm = room.directChatMatrixID; if (dm != null) _presence = room.client.fetchCurrentPresence(dm);
      _markRead(); setState(() {});
    });
  }
  @override void dispose() { tl?.cancelSubscriptions(); typingOff?.cancel(); if (typing) room.setTyping(false); _rec.dispose(); _player.dispose(); super.dispose(); }

  // ---------- voice messages ----------
  Future<void> _toggleRecord() async {
    if (_recStart == null) {
      if (!await _rec.hasPermission()) { _snack('Allow microphone access to record voice messages'); return; }
      _recPath = '${(await getTemporaryDirectory()).path}/voice-${DateTime.now().millisecondsSinceEpoch}.m4a';
      await _rec.start(const RecordConfig(encoder: AudioEncoder.aacLc, bitRate: 64000, sampleRate: 44100), path: _recPath!);
      setState(() => _recStart = DateTime.now());
      Timer.periodic(const Duration(seconds: 1), (t) { if (_recStart == null || !mounted) { t.cancel(); } else { setState(() {}); } });
    } else {
      final ms = DateTime.now().difference(_recStart!).inMilliseconds;
      final path = await _rec.stop(); setState(() => _recStart = null);
      if (path == null || ms < 700) return;
      final bytes = await File(path).readAsBytes();
      await room.sendFileEvent(MatrixAudioFile(bytes: bytes, name: 'Voice message.m4a', mimeType: 'audio/mp4', duration: ms),
          extraContent: {'org.matrix.msc3245.voice': {}, 'org.matrix.msc1767.audio': {'duration': ms}});   // encrypted before upload
    }
  }
  Future<void> _cancelRecord() async { await _rec.cancel(); setState(() => _recStart = null); }
  Future<void> _play(Event e) async {
    if (_playing == e.eventId) { await _player.stop(); setState(() => _playing = null); return; }
    final f = await e.downloadAndDecryptAttachment();
    setState(() => _playing = e.eventId);
    await _player.play(BytesSource(f.bytes, mimeType: f.mimeType));
    _player.onPlayerComplete.first.then((_) { if (mounted) setState(() => _playing = null); });
  }

  // ---------- polls ----------
  Future<void> _newPoll() async {
    final q = TextEditingController(); final opts = [TextEditingController(), TextEditingController()];
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Create poll'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: q, decoration: const InputDecoration(labelText: 'Question')),
        for (var i = 0; i < opts.length; i++) TextField(controller: opts[i], decoration: InputDecoration(labelText: 'Option ${i + 1}')),
        if (opts.length < 10) TextButton.icon(onPressed: () => set(() => opts.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('Add option')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send poll'))])));
    final answers = opts.map((o) => o.text.trim()).where((t) => t.isNotEmpty).toList();
    if (ok != true || q.text.trim().isEmpty || answers.length < 2) return;
    await room.startPoll(question: q.text.trim(), kind: PollKind.disclosed,
        answers: [for (var i = 0; i < answers.length; i++) PollAnswer(id: 'a$i', mText: answers[i])]);
  }

  Future<void> _attachMenu() async {
    final a = await showModalBottomSheet<String>(context: context, builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo), title: const Text('Photo or file'), onTap: () => Navigator.pop(s, 'file')),
      ListTile(leading: const Icon(Icons.poll), title: const Text('Poll'), onTap: () => Navigator.pop(s, 'poll')),
    ])));
    if (a == 'file') await attach();
    if (a == 'poll') await _newPoll();
  }
  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  void _markRead() { final last = tl?.events.firstOrNull; if (last != null && last.senderId != me) tl!.setReadMarker(eventId: last.eventId); }

  void _onTyping(String t) {
    if (!typing && t.isNotEmpty) { typing = true; room.setTyping(true, timeout: 10000); }
    typingOff?.cancel();
    typingOff = Timer(const Duration(seconds: 4), () { typing = false; room.setTyping(false); });
  }

  Future<void> send() async {
    final t = input.text.trim(); if (t.isEmpty) return; input.clear();
    typing = false; room.setTyping(false);
    if (!room.encrypted) throw StateError('Refusing to send in an unencrypted room');
    if (editing != null) { await room.sendTextEvent(t, editEventId: editing!.eventId); }
    else { await room.sendTextEvent(t, inReplyTo: replyTo); }
    setState(() { replyTo = null; editing = null; });
  }

  Future<void> attach() async {
    final files = await FilePicker.pickFiles(); if (files.isEmpty) return;
    final f = files.first; final bytes = await f.xFile.readAsBytes(); if (!mounted) return;
    await context.read<MatrixService>().sendFile(room, f.name, bytes);   // encrypted before upload
  }
  Future<void> download(Event e) async {
    final file = await e.downloadAndDecryptAttachment();
    final saved = await FilePicker.saveFile(fileName: file.name, bytes: file.bytes);
    if (mounted && saved != null) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Saved ${file.name}')));
  }
  Future<Uint8List?> _thumb(Event e) => _thumbs[e.eventId] ??= e.downloadAndDecryptAttachment(getThumbnail: e.hasThumbnail).then((f) => f.bytes).catchError((_) => null);

  Future<void> summarise() async {
    final text = (tl?.events ?? []).where((e) => e.type == EventTypes.Message).take(80).toList().reversed
        .map((e) => '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${e.body}').join('\n');
    final r = await context.read<ApiService>().ask('Summarise this thread', context: text, agent: 'summ');
    if (!mounted) return;
    showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: SingleChildScrollView(child: Text(r['answer']))));
  }

  Future<void> _actions(Event e) async {
    final mine = e.senderId == me;
    final a = await showModalBottomSheet<String>(context: context, builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, children: [
        for (final r in ['👍', '❤️', '😂', '😮', '😢', '🙏']) ActionChip(label: Text(r, style: const TextStyle(fontSize: 22)), onPressed: () => Navigator.pop(s, 'react:$r'))])),
      ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(s, 'reply')),
      ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(s, 'copy')),
      if (mine && e.messageType == MessageTypes.Text) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(s, 'edit')),
      if (e.canRedact) ListTile(leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error), title: const Text('Delete for everyone'), onTap: () => Navigator.pop(s, 'delete')),
    ])));
    if (a == null) return;
    if (a.startsWith('react:')) await room.sendReaction(e.eventId, a.substring(6));
    if (a == 'reply') setState(() { replyTo = e; editing = null; });
    if (a == 'copy') await Clipboard.setData(ClipboardData(text: _text(e)));
    if (a == 'edit') setState(() { editing = e; replyTo = null; input.text = _text(e); });
    if (a == 'delete') await room.redactEvent(e.eventId);
  }

  /// Text without the quoted reply fallback.
  String _text(Event e) {
    final shown = tl == null ? e : e.getDisplayEvent(tl!);
    return shown.body.split('\n').skipWhile((l) => l.startsWith('> ')).join('\n').trim();
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    const shownTypes = {EventTypes.Message, EventTypes.Encrypted, kCallInviteEvent, kCallEndEvent, 'com.amerteams.meeting', PollEventContent.startType};
    var evs = (tl?.events ?? []).where((e) => shownTypes.contains(e.type) && e.relationshipType != RelationshipTypes.edit).toList();
    final q = searchCtl.text.trim().toLowerCase();
    if (searching && q.isNotEmpty) evs = evs.where((e) => e.type == EventTypes.Message && e.body.toLowerCase().contains(q)).toList();
    final typers = room.typingUsers.where((u) => u.id != me).map((u) => u.calcDisplayname()).toList();
    final members = room.summary.mJoinedMemberCount ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: searching
            ? TextField(controller: searchCtl, autofocus: true, decoration: const InputDecoration(hintText: 'Search messages', border: InputBorder.none), onChanged: (_) => setState(() {}))
            : Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(room.getLocalizedDisplayname(), overflow: TextOverflow.ellipsis),
                FutureBuilder<CachedPresence>(future: _presence, builder: (_, p) {
                  final online = p.data?.currentlyActive == true || p.data?.presence == PresenceType.online;
                  final status = p.data?.statusMsg;
                  final line = typers.isNotEmpty ? '${typers.join(', ')} ${typers.length == 1 ? 'is' : 'are'} typing…'
                      : room.isDirectChat ? '${online ? 'Online' : 'Offline'}${status != null && status.isNotEmpty ? ' · $status' : ''} · 🔒 encrypted'
                      : '🔒 End-to-end encrypted · $members member${members == 1 ? '' : 's'}';
                  return Text(line, style: Theme.of(c).textTheme.labelSmall?.copyWith(color: typers.isNotEmpty || online ? cs.primary : null));
                }),
              ]),
        actions: [
          IconButton(tooltip: searching ? 'Close search' : 'Search', icon: Icon(searching ? Icons.close : Icons.search), onPressed: () => setState(() { searching = !searching; searchCtl.clear(); })),
          IconButton(tooltip: 'Voice call', icon: const Icon(Icons.call), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, video: false)))),
          IconButton(tooltip: 'Video call', icon: const Icon(Icons.videocam), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id)))),
          PopupMenuButton<String>(onSelected: (v) { if (v == 'sum') summarise(); }, itemBuilder: (_) => const [PopupMenuItem(value: 'sum', child: Text('Summarise with Amer'))]),
        ]),
      body: Column(children: [
        Expanded(child: ListView.builder(reverse: true, itemCount: evs.length, itemBuilder: (_, i) {
          final e = evs[i];
          final newDay = i == evs.length - 1 || !DateUtils.isSameDay(e.originServerTs, evs[i + 1].originServerTs);
          return Column(children: [
            if (newDay) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Chip(label: Text(DateFormat('EEEE d MMMM').format(e.originServerTs)))),
            _item(c, e, isLastMine: e.senderId == me && evs.indexWhere((x) => x.senderId == me) == i),
          ]);
        })),
        if (replyTo != null || editing != null) Container(color: cs.surfaceContainerHighest, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [
          Icon(editing != null ? Icons.edit : Icons.reply, size: 18), const SizedBox(width: 8),
          Expanded(child: Text(editing != null ? 'Editing message' : 'Replying to ${replyTo!.senderFromMemoryOrFallback.calcDisplayname()}: ${_text(replyTo!)}', maxLines: 1, overflow: TextOverflow.ellipsis)),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() { replyTo = null; editing = null; input.clear(); }))])),
        SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: _recStart != null
          ? Row(children: [
              IconButton(tooltip: 'Cancel', icon: const Icon(Icons.delete_outline), onPressed: _cancelRecord),
              const Icon(Icons.fiber_manual_record, color: Colors.red), const SizedBox(width: 8),
              Expanded(child: Text('Recording ${DateTime.now().difference(_recStart!).inSeconds}s · tap send to share (encrypted)')),
              IconButton.filled(icon: const Icon(Icons.send), onPressed: _toggleRecord)])
          : Row(children: [
              IconButton(tooltip: 'Photo, file or poll', icon: const Icon(Icons.add_circle_outline), onPressed: _attachMenu),
              Expanded(child: TextField(controller: input, minLines: 1, maxLines: 5, onChanged: (t) { _onTyping(t); setState(() {}); }, textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder(), isDense: true), onSubmitted: (_) => send())),
              input.text.trim().isEmpty && editing == null
                  ? IconButton.filledTonal(tooltip: 'Record voice message', icon: const Icon(Icons.mic), onPressed: _toggleRecord)
                  : IconButton.filled(icon: Icon(editing != null ? Icons.check : Icons.send), onPressed: send)]))),
      ]),
    );
  }

  Widget _item(BuildContext c, Event e, {required bool isLastMine}) {
    final cs = Theme.of(c).colorScheme; final mine = e.senderId == me;
    if (e.type == kCallInviteEvent) {
      final v = e.content['media'] != 'audio';
      return ListTile(leading: CircleAvatar(child: Icon(v ? Icons.videocam : Icons.call)), title: Text(v ? 'Video call' : 'Voice call'),
        subtitle: Text('${e.senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('HH:mm').format(e.originServerTs)} · encrypted'),
        trailing: FilledButton(child: const Text('Join'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, callId: e.content['call_id'] as String, video: v)))));
    }
    if (e.type == kCallEndEvent) {
      return Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(e.body, style: Theme.of(c).textTheme.labelSmall)));
    }
    if (e.type == 'com.amerteams.meeting') {
      final id = e.content['meeting_id'] as String?;
      final st = DateTime.tryParse(e.content['start'] as String? ?? '')?.toLocal();
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: ListTile(leading: const Icon(Icons.event),
        title: Text(e.content['title'] as String? ?? 'Meeting'),
        subtitle: Text('${st != null ? DateFormat('EEE d MMM, HH:mm').format(st) : ''} · ${e.content['duration_min']} min${id != null ? '\nID ${MeetingService.format(id)}' : ''}'),
        isThreeLine: id != null,
        trailing: FilledButton(child: const Text('Join'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, meeting: id != null))))));
    }
    if (e.type == PollEventContent.startType && tl != null) {
      final poll = e.parsedPollEventContent.pollStartContent;
      final votes = e.getPollResponses(tl!); final mineVote = votes[me] ?? {};
      final total = votes.length;
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [const Icon(Icons.poll, size: 18), const SizedBox(width: 6), Expanded(child: Text(poll.question.mText, style: Theme.of(c).textTheme.titleSmall))]),
        const SizedBox(height: 8),
        for (final a in poll.answers) () {
          final n = votes.values.where((v) => v.contains(a.id)).length;
          return InkWell(onTap: () => e.answerPoll([a.id]), child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [Icon(mineVote.contains(a.id) ? Icons.radio_button_checked : Icons.radio_button_off, size: 18), const SizedBox(width: 6), Expanded(child: Text(a.mText)), Text('$n')]),
            const SizedBox(height: 4), LinearProgressIndicator(value: total == 0 ? 0 : n / total)])));
        }(),
        Text('$total vote${total == 1 ? '' : 's'} · ${e.senderFromMemoryOrFallback.calcDisplayname()}', style: Theme.of(c).textTheme.labelSmall),
      ])));
    }
    if (e.redacted) {
      return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text('🚫 Message deleted', style: TextStyle(fontStyle: FontStyle.italic, color: cs.outline))));
    }
    final shown = tl == null ? e : e.getDisplayEvent(tl!);
    final edited = shown.eventId != e.eventId;
    final reactions = <String, int>{};
    if (tl != null) { for (final r in e.aggregatedEvents(tl!, RelationshipTypes.reaction)) { final k = r.content.tryGetMap<String, Object?>('m.relates_to')?['key'] as String?; if (k != null) reactions[k] = (reactions[k] ?? 0) + 1; } }
    final seen = isLastMine && e.receipts.any((r) => r.user.id != me);

    Widget body;
    if (e.type == EventTypes.Encrypted) {
      body = const Text('🔒 Waiting for this message’s key (open the app on the sender’s device)');
    } else if (e.messageType == MessageTypes.Image) {
      body = FutureBuilder<Uint8List?>(future: _thumb(e), builder: (_, s) => s.data == null
          ? const SizedBox(width: 220, height: 160, child: Center(child: CircularProgressIndicator()))
          : GestureDetector(onTap: () => download(e), child: ClipRRect(borderRadius: BorderRadius.circular(8), child: Image.memory(s.data!, width: 260, fit: BoxFit.cover))));
    } else if (e.messageType == MessageTypes.Audio) {
      final ms = (e.content.tryGetMap<String, Object?>('info')?['duration'] as num?)?.toInt() ?? 0;
      body = Row(mainAxisSize: MainAxisSize.min, children: [
        IconButton(icon: Icon(_playing == e.eventId ? Icons.stop_circle : Icons.play_circle, size: 34), onPressed: () => _play(e)),
        const Icon(Icons.graphic_eq), const SizedBox(width: 8),
        Text(ms > 0 ? '${ms ~/ 60000}:${((ms ~/ 1000) % 60).toString().padLeft(2, '0')}' : 'Voice message')]);
    } else if (e.messageType == MessageTypes.File || e.messageType == MessageTypes.Video) {
      body = InkWell(onTap: () => download(e), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.insert_drive_file), const SizedBox(width: 8),
        Flexible(child: Text(e.body)), const SizedBox(width: 8), const Icon(Icons.download, size: 18)]));
    } else {
      body = Text(_text(e));
    }
    final replyId = e.relationshipType == null ? (e.content.tryGetMap<String, Object?>('m.relates_to')?.tryGetMap<String, Object?>('m.in_reply_to')?['event_id'] as String?) : null;
    final replied = replyId == null || tl == null ? null : tl!.events.where((x) => x.eventId == replyId).firstOrNull;

    return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: GestureDetector(
      onLongPress: () => _actions(e), onSecondaryTap: () => _actions(e),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 3), padding: const EdgeInsets.fromLTRB(10, 8, 10, 6),
        constraints: const BoxConstraints(maxWidth: 520),
        decoration: BoxDecoration(color: mine ? cs.primaryContainer : cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          if (!mine && !room.isDirectChat) Text(e.senderFromMemoryOrFallback.calcDisplayname(), style: Theme.of(c).textTheme.labelSmall?.copyWith(color: cs.primary)),
          if (replied != null) Container(margin: const EdgeInsets.only(bottom: 4), padding: const EdgeInsets.all(6),
            decoration: BoxDecoration(border: Border(left: BorderSide(color: cs.primary, width: 3)), color: cs.surface.withValues(alpha: .5)),
            child: Text('${replied.senderFromMemoryOrFallback.calcDisplayname()}: ${_text(replied)}', maxLines: 2, overflow: TextOverflow.ellipsis, style: Theme.of(c).textTheme.bodySmall)),
          body,
          const SizedBox(height: 2),
          Row(mainAxisSize: MainAxisSize.min, children: [
            if (edited) Text('edited · ', style: Theme.of(c).textTheme.labelSmall),
            Text(DateFormat('HH:mm').format(e.originServerTs), style: Theme.of(c).textTheme.labelSmall),
            if (mine) Padding(padding: const EdgeInsets.only(left: 4), child: Icon(seen ? Icons.done_all : Icons.done, size: 14, color: seen ? cs.primary : null)),
          ]),
          if (reactions.isNotEmpty) Wrap(spacing: 4, children: [for (final r in reactions.entries) Chip(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero,
            label: Text('${r.key} ${r.value}'))]),
        ]))));
  }
}
