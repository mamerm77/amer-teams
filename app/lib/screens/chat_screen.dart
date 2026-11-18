import 'dart:async';
import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
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
  Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  String get me => room.client.userID!;

  @override void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      tl = await room.getTimeline(onUpdate: () { if (mounted) setState(() {}); _markRead(); });
      _markRead(); setState(() {});
    });
  }
  @override void dispose() { tl?.cancelSubscriptions(); typingOff?.cancel(); if (typing) room.setTyping(false); super.dispose(); }

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
    const shownTypes = {EventTypes.Message, EventTypes.Encrypted, kCallInviteEvent, kCallEndEvent, 'com.amerteams.meeting'};
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
                Text(typers.isNotEmpty ? '${typers.join(', ')} ${typers.length == 1 ? 'is' : 'are'} typing…' : '🔒 End-to-end encrypted · $members member${members == 1 ? '' : 's'}',
                    style: Theme.of(c).textTheme.labelSmall?.copyWith(color: typers.isNotEmpty ? cs.primary : null)),
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
        SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          IconButton(tooltip: 'Share encrypted file or photo', icon: const Icon(Icons.add_circle_outline), onPressed: attach),
          Expanded(child: TextField(controller: input, minLines: 1, maxLines: 5, onChanged: _onTyping, textInputAction: TextInputAction.send,
              decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder(), isDense: true), onSubmitted: (_) => send())),
          IconButton.filled(icon: Icon(editing != null ? Icons.check : Icons.send), onPressed: send)]))),
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
    } else if (e.messageType == MessageTypes.File || e.messageType == MessageTypes.Video || e.messageType == MessageTypes.Audio) {
      body = InkWell(onTap: () => download(e), child: Row(mainAxisSize: MainAxisSize.min, children: [const Icon(Icons.insert_drive_file), const SizedBox(width: 8),
        Flexible(child: Text(e.body)), const SizedBox(width: 8), const Icon(Icons.download, size: 18)]));
    } else {
      body = Text(_text(e));
    }
    final replyId = e.relationshipType == null ? e.content.tryGetMap<String, Object?>('m.relates_to')?.tryGetMap<String, Object?>('m.in_reply_to')?['event_id'] as String? : null;
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
