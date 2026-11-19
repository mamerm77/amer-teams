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
import 'chat_info_screen.dart';
import '../services/chat_extras.dart';
import '../services/outbox.dart';
import '../services/compliance_service.dart';

/// Encrypted chat: replies, reactions, edit, delete, typing indicator, read receipts,
/// photo previews (decrypted on device), files, search, call and meeting cards.
/// [threadRootId]: show one thread. [filesOnly]: show only shared files, photos and voice.
class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key, required this.roomId, this.threadRootId, this.filesOnly = false});
  final String roomId; final String? threadRootId; final bool filesOnly;
  @override State<ChatScreen> createState() => _S();
}
class _S extends State<ChatScreen> {
  final _meetLive = <String, (Future<int>, DateTime)>{};
  Future<int> _live(String callId) {
    final c = _meetLive[callId];
    if (c != null && DateTime.now().difference(c.$2).inSeconds < 15) return c.$1;
    final f = context.read<ApiService>().presence(room.id, callId); _meetLive[callId] = (f, DateTime.now()); return f;
  }
  Timeline? tl; final input = TextEditingController(); final searchCtl = TextEditingController();
  Event? replyTo, editing; bool searching = false; Timer? typingOff; bool typing = false;
  final _thumbs = <String, Future<Uint8List?>>{};
  final _rec = AudioRecorder(); DateTime? _recStart; String? _recPath;
  final _player = AudioPlayer(); String? _playing;
  Future<CachedPresence>? _presence;
  // The SDK briefly drops rooms while it re-syncs (e.g. after blocking someone): keep the last known room, never crash.
  Room? _room;
  Room get room => _room = context.read<MatrixService>().client.getRoomById(widget.roomId) ?? _room ?? (throw StateError('This chat is no longer available'));
  String get me => room.client.userID!;

  late final Outbox outbox;
  static String _initials(String n) { final p = n.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList(); return p.isEmpty ? '?' : (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase(); }
  static String _lastSeen(DateTime t) {
    final now = DateTime.now(); final d = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
    if (d == today) return 'today at ${DateFormat('HH:mm').format(t)}';
    if (d == today.subtract(const Duration(days: 1))) return 'yesterday at ${DateFormat('HH:mm').format(t)}';
    return DateFormat('d MMM, HH:mm').format(t);
  }
  /// 1:1 chat where the other person was invited but has never joined (e.g. has not signed in yet).
  bool get _peerInvitedOnly {
    final dm = room.directChatMatrixID; if (dm == null) return false;
    return room.getState(EventTypes.RoomMember, dm)?.content['membership'] == 'invite';
  }
  void _safeTyping(bool on, {int? timeout}) { room.setTyping(on, timeout: timeout).catchError((_) {}); }   // best effort; never throws

  @override void initState() {
    super.initState();
    outbox = Outbox(room)..addListener(() { if (mounted) setState(() {}); })..load();
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      tl = await room.getTimeline(onUpdate: () { if (mounted) setState(() {}); _markRead(); });
      final dm = room.directChatMatrixID; if (dm != null) _presence = room.client.fetchCurrentPresence(dm);
      _markRead(); setState(() {});
    });
  }
  @override void dispose() { tl?.cancelSubscriptions(); typingOff?.cancel(); if (typing) _safeTyping(false); outbox.dispose(); _rec.dispose(); _player.dispose(); super.dispose(); }

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
    final a = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (s) => SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.photo), title: const Text('Photo or file'), onTap: () => Navigator.pop(s, 'file')),
      ListTile(leading: const Icon(Icons.poll), title: const Text('Poll'), onTap: () => Navigator.pop(s, 'poll')),
      ListTile(leading: const Icon(Icons.checklist), title: const Text('Checklist'), onTap: () => Navigator.pop(s, 'check')),
      ListTile(leading: const Icon(Icons.schedule_send), title: const Text('Schedule a message'), onTap: () => Navigator.pop(s, 'later')),
    ]))));
    if (a == 'file') await attach();
    if (a == 'poll') await _newPoll();
    if (a == 'check') await _newChecklist();
    if (a == 'later') await _sendLater();
  }
  void _snack(String t) => ScaffoldMessenger.of(context)..hideCurrentSnackBar()..showSnackBar(SnackBar(content: Text(t), duration: const Duration(seconds: 3)));

  void _markRead() { final last = tl?.events.firstOrNull; if (last != null && last.senderId != me) tl!.setReadMarker(eventId: last.eventId); }

  void _onTyping(String t) {
    ScaffoldMessenger.of(context).hideCurrentSnackBar();      // notices must not cover the message box while typing
    if (!typing && t.isNotEmpty) { typing = true; _safeTyping(true, timeout: 10000); }
    typingOff?.cancel();
    typingOff = Timer(const Duration(seconds: 4), () { typing = false; _safeTyping(false); });
  }

  Future<void> send() async {
    final t = input.text.trim(); if (t.isEmpty) return; input.clear();
    typing = false; _safeTyping(false);
    if (!room.encrypted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This chat is not encrypted; sending is refused'))); return; }
    var text = t;
    _mentions.forEach((name, id) => text = text.replaceAll('@$name', mentionMarkdown(name, id)));   // @Name -> pill
    _mentions.clear();
    try {
      if (editing != null) { await room.sendTextEvent(text, editEventId: editing!.eventId).timeout(const Duration(seconds: 20)); }
      else if (widget.threadRootId != null) {
        final last = (tl?.events ?? []).where((e) => _inThread(e)).firstOrNull?.eventId ?? widget.threadRootId;
        await room.sendTextEvent(text, threadRootEventId: widget.threadRootId, threadLastEventId: last, inReplyTo: replyTo).timeout(const Duration(seconds: 20));
      } else {
        await outbox.send(text, replyTo: replyTo);          // never lost: kept as "Not sent" and retried if the server is unreachable
      }
    } catch (e) {
      // edits and thread replies: give the text back so nothing is lost
      input.text = t; _snack('Not sent: no connection to the server. Your text is kept, so tap send to try again.');
      return;
    }
    setState(() { replyTo = null; editing = null; });
  }

  // ---------- threads ----------
  String? _threadOf(Event e) {
    final r = e.content.tryGetMap<String, Object?>('m.relates_to');
    return r?['rel_type'] == RelationshipTypes.thread ? r!['event_id'] as String? : null;
  }
  bool _inThread(Event e) => _threadOf(e) == widget.threadRootId;
  int _replyCount(Event root) => (tl?.events ?? []).where((e) => _threadOf(e) == root.eventId).length;

  // ---------- @mentions ----------
  final _mentions = <String, String>{};   // display name -> user id
  List<User> _mentionCandidates() {
    final m = RegExp(r'@(\w*)$').firstMatch(input.text.substring(0, input.selection.baseOffset < 0 ? input.text.length : input.selection.baseOffset));
    if (m == null) return [];
    final q = m.group(1)!.toLowerCase();
    return room.getParticipants().where((u) => u.id != me && (u.calcDisplayname().toLowerCase().contains(q) || u.id.toLowerCase().contains(q))).take(6).toList();
  }
  void _insertMention(User u) {
    final name = u.calcDisplayname().replaceAll(' ', '_');
    input.text = input.text.replaceFirst(RegExp(r'@\w*$'), '@$name ');
    input.selection = TextSelection.collapsed(offset: input.text.length);
    _mentions[name] = u.id; setState(() {});
  }

  // ---------- formatting ----------
  void _wrap(String l, [String? r]) {
    final sel = input.selection; final t = input.text;
    final a = sel.start < 0 ? t.length : sel.start, b = sel.end < 0 ? t.length : sel.end;
    input.text = t.substring(0, a) + l + t.substring(a, b) + (r ?? l) + t.substring(b);
    input.selection = TextSelection.collapsed(offset: b + l.length);
    setState(() {});
  }
  bool _format = false;

  // ---------- send later ----------
  Future<void> _sendLater() async {
    final t = input.text.trim(); if (t.isEmpty) return;
    final d = await showDatePicker(context: context, initialDate: DateTime.now(), firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 30)));
    if (d == null || !mounted) return;
    final tm = await showTimePicker(context: context, initialTime: TimeOfDay.fromDateTime(DateTime.now().add(const Duration(minutes: 5))));
    if (tm == null) return;
    final at = DateTime(d.year, d.month, d.day, tm.hour, tm.minute);
    ScheduledSender.instance.add(room, t, at); input.clear();
    _snack('Will send at ${DateFormat('d MMM HH:mm').format(at)} (keep the app open)');
  }

  // ---------- checklist ----------
  Future<void> _newChecklist() async {
    final title = TextEditingController(); final items = [TextEditingController(), TextEditingController()];
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Checklist'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
        for (var i = 0; i < items.length; i++) TextField(controller: items[i], decoration: InputDecoration(labelText: 'Task ${i + 1}')),
        TextButton.icon(onPressed: () => set(() => items.add(TextEditingController())), icon: const Icon(Icons.add), label: const Text('Add task'))])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send'))])));
    final list = items.map((i) => i.text.trim()).where((t) => t.isNotEmpty).toList();
    if (ok != true || list.isEmpty) return;
    await room.sendEvent({'title': title.text.trim().isEmpty ? 'Checklist' : title.text.trim(), 'items': list,
        'body': '☑ ${title.text.trim()}\n${list.map((t) => '☐ $t').join('\n')}'}, type: kChecklistEvent);
  }
  Map<int, bool> _ticks(Event cl) {
    final out = <int, bool>{};
    for (final e in (tl?.events ?? []).reversed) {
      if (e.type == kChecklistTick && e.content['checklist'] == cl.eventId) out[(e.content['item'] as num).toInt()] = e.content['done'] == true;
    }
    return out;
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
    // Rules (docs/FEATURE_LOGIC.md): edit own text within 24 h; delete own within 2 days; moderators (power >= 50) any message.
    final age = DateTime.now().difference(e.originServerTs);
    final moderator = room.getPowerLevelByUserId(me).level >= 50;
    final canEdit = mine && e.messageType == MessageTypes.Text && age < const Duration(hours: 24);
    final canDelete = e.canRedact && ((mine && age < const Duration(days: 2)) || (!mine && moderator));
    final a = await showModalBottomSheet<String>(context: context, isScrollControlled: true, builder: (s) => SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
      Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 8, children: [
        for (final r in ['👍', '❤️', '😂', '😮', '😢', '🙏']) ActionChip(label: Text(r, style: const TextStyle(fontSize: 22)), onPressed: () => Navigator.pop(s, 'react:$r'))])),
      ListTile(leading: const Icon(Icons.reply), title: const Text('Reply'), onTap: () => Navigator.pop(s, 'reply')),
      if (widget.threadRootId == null) ListTile(leading: const Icon(Icons.forum_outlined), title: const Text('Reply in thread'), onTap: () => Navigator.pop(s, 'thread')),
      ListTile(leading: const Icon(Icons.shortcut), title: const Text('Forward'), onTap: () => Navigator.pop(s, 'forward')),
      ListTile(leading: Icon(StarService(context.read<MatrixService>()).isStarred(room.id, e.eventId) ? Icons.bookmark_remove : Icons.bookmark_add_outlined),
        title: Text(StarService(context.read<MatrixService>()).isStarred(room.id, e.eventId) ? 'Remove from saved' : 'Save'), onTap: () => Navigator.pop(s, 'star')),
      if (e.messageType == MessageTypes.Text) ListTile(leading: const Icon(Icons.translate), title: const Text('Translate (Amer)'), onTap: () => Navigator.pop(s, 'translate')),
      if (!mine && e.messageType == MessageTypes.Text) ListTile(leading: const Icon(Icons.auto_awesome), title: const Text('Suggest a reply (Amer)'), onTap: () => Navigator.pop(s, 'suggest')),
      ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(s, 'copy')),
      if (canEdit) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(s, 'edit')),
      if (canDelete) ListTile(leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error), title: Text(mine ? 'Delete for everyone' : 'Delete for everyone (moderator)'), onTap: () => Navigator.pop(s, 'delete')),
      if (mine && !canEdit && e.messageType == MessageTypes.Text) const ListTile(dense: true, leading: Icon(Icons.info_outline), title: Text('Messages can be edited for 24 hours')),
    ]))));
    if (a == null) return;
    if (a.startsWith('react:')) await sendEncryptedReaction(room, e.eventId, a.substring(6));
    if (a == 'reply') setState(() { replyTo = e; editing = null; });
    if (a == 'copy') await Clipboard.setData(ClipboardData(text: _text(e)));
    if (a == 'edit') setState(() { editing = e; replyTo = null; input.text = _text(e); });
    if (a == 'delete') await room.redactEvent(e.eventId);
    if (a == 'thread' && mounted) Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, threadRootId: e.eventId)));
    if (a == 'star' && mounted) { await StarService(context.read<MatrixService>()).toggle(room.id, e.eventId); _snack('Saved messages updated'); }
    if (a == 'forward' && mounted) {
      final rooms = context.read<MatrixService>().chats;
      final to = await showDialog<Room>(context: context, builder: (d) => SimpleDialog(title: const Text('Forward to'), children: [
        for (final r in rooms) SimpleDialogOption(onPressed: () => Navigator.pop(d, r), child: Text(r.getLocalizedDisplayname()))]));
      if (to != null) {
        final content = Map<String, Object?>.from(e.content)..remove('m.relates_to')..remove('m.new_content');
        await to.sendEvent(content, type: e.type == EventTypes.Encrypted ? EventTypes.Message : e.type);   // file keys travel inside, re-encrypted
        _snack('Forwarded to ${to.getLocalizedDisplayname()}');
      }
    }
    if ((a == 'translate' || a == 'suggest') && mounted) {
      try {
        final r = await context.read<ApiService>().ask(a == 'translate' ? 'Translate to ${Localizations.localeOf(context).languageCode == 'ar' ? 'English' : 'Arabic'}' : 'Suggest a short, polite reply to this message',
            context: plainMentions(_text(e)), agent: a == 'translate' ? 'trans' : 'assist');
        if (!mounted) return;
        if (a == 'suggest') { setState(() => input.text = r['answer'] as String); } else {
          showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: SelectableText(r['answer'] as String)));
        }
      } catch (err) { _snack('$err'); }
    }
  }

  /// Text without the quoted reply fallback.
  String _text(Event e) {
    final shown = tl == null ? e : e.getDisplayEvent(tl!);
    return plainMentions(shown.body.split('\n').skipWhile((l) => l.startsWith('> ')).join('\n').trim());
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    const shownTypes = {EventTypes.Message, EventTypes.Encrypted, kCallInviteEvent, kCallEndEvent, 'com.amerteams.meeting', PollEventContent.startType, kChecklistEvent};
    final lifetime = (room.getState('m.room.retention')?.content['max_lifetime'] as num?)?.toInt();
    var evs = (tl?.events ?? []).where((e) => shownTypes.contains(e.type) && e.relationshipType != RelationshipTypes.edit
        && (lifetime == null || DateTime.now().difference(e.originServerTs).inMilliseconds < lifetime)).toList();
    evs = widget.threadRootId != null
        ? evs.where((e) => e.eventId == widget.threadRootId || _inThread(e)).toList()
        : evs.where((e) => _threadOf(e) == null).toList();
    if (widget.filesOnly) evs = evs.where((e) => {MessageTypes.Image, MessageTypes.File, MessageTypes.Audio, MessageTypes.Video}.contains(e.messageType)).toList();
    final q = searchCtl.text.trim().toLowerCase();
    if (searching && q.isNotEmpty) evs = evs.where((e) => e.type == EventTypes.Message && e.body.toLowerCase().contains(q)).toList();
    final typers = room.typingUsers.where((u) => u.id != me).map((u) => u.calcDisplayname()).toList();
    final members = room.summary.mJoinedMemberCount ?? 0;

    return Scaffold(
      appBar: AppBar(
        title: searching
            ? TextField(controller: searchCtl, autofocus: true, decoration: const InputDecoration(hintText: 'Search messages', border: InputBorder.none), onChanged: (_) => setState(() {}))
            : Row(children: [
              if (widget.threadRootId == null && !widget.filesOnly) Padding(padding: const EdgeInsets.only(right: 10),
                child: CircleAvatar(radius: 18, backgroundColor: cs.primaryContainer, child: Text(_initials(peerName(room)), style: TextStyle(fontSize: 14, color: cs.onPrimaryContainer)))),
              Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(widget.threadRootId != null ? 'Thread' : widget.filesOnly ? 'Files and media' : peerName(room), overflow: TextOverflow.ellipsis),
                FutureBuilder<CachedPresence>(future: _presence, builder: (_, p) {
                  final online = p.data?.currentlyActive == true || p.data?.presence == PresenceType.online;
                  final status = p.data?.statusMsg;
                  final seen = p.data?.lastActiveTimestamp;
                  final away = seen == null ? 'Offline' : 'Last seen ${_lastSeen(seen)}';
                  final line = typers.isNotEmpty ? '${typers.join(', ')} ${typers.length == 1 ? 'is' : 'are'} typing…'
                      : room.isDirectChat && _peerInvitedOnly ? 'Invited · hasn\'t signed in yet · 🔒 encrypted'
                      : room.isDirectChat ? '${online ? 'Online' : away}${status != null && status.isNotEmpty ? ' · $status' : ''} · 🔒 encrypted'
                      : '🔒 End-to-end encrypted · $members member${members == 1 ? '' : 's'}';
                  return Text(line, style: Theme.of(c).textTheme.labelSmall?.copyWith(color: typers.isNotEmpty || online ? cs.primary : null));
                }),
              ]))]),
        actions: [
          IconButton(tooltip: searching ? 'Close search' : 'Search', icon: Icon(searching ? Icons.close : Icons.search), onPressed: () => setState(() { searching = !searching; searchCtl.clear(); })),
          IconButton(tooltip: 'Voice call', icon: const Icon(Icons.call), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, video: false)))),
          IconButton(tooltip: 'Video call', icon: const Icon(Icons.videocam), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id)))),
          PopupMenuButton<String>(onSelected: (v) {
            if (v == 'sum') summarise();
            if (v == 'info') Navigator.push(c, MaterialPageRoute(builder: (_) => ChatInfoScreen(roomId: room.id)));
            if (v == 'files') Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, filesOnly: true)));
          }, itemBuilder: (_) => const [
            PopupMenuItem(value: 'info', child: Text('Chat info')),
            PopupMenuItem(value: 'files', child: Text('Files and media')),
            PopupMenuItem(value: 'sum', child: Text('Summarise with Amer'))]),
        ]),
      body: Column(children: [
        ListenableBuilder(listenable: ComplianceService.instance, builder: (_, __) {
          final cp = ComplianceService.instance;
          if (!cp.enabled || !cp.archives(room)) return const SizedBox.shrink();
          return Container(width: double.infinity, color: cs.tertiaryContainer, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
            child: Row(children: [const Icon(Icons.policy_outlined, size: 16), const SizedBox(width: 8), Expanded(child: Text(
              'This chat is archived by ${cp.orgName ?? 'your organisation'} for compliance (kept ${cp.retentionDays} days). Messages stay end-to-end encrypted in transit.',
              style: Theme.of(c).textTheme.labelSmall))]));
        }),
        if (evs.length < 3 && widget.threadRootId == null && !widget.filesOnly) Padding(padding: const EdgeInsets.fromLTRB(24, 24, 24, 0),
          child: Card(child: Padding(padding: const EdgeInsets.all(16), child: Column(children: [
            const Icon(Icons.lock_outline, size: 28),
            const SizedBox(height: 8),
            const Text('Messages and calls in this chat are end-to-end encrypted. Only the people in it can read or listen to them.', textAlign: TextAlign.center),
            if (_peerInvitedOnly) Padding(padding: const EdgeInsets.only(top: 8), child: Text('${peerName(room)} hasn\'t signed in yet. They will get your messages (✓✓) once they do.', textAlign: TextAlign.center, style: TextStyle(color: cs.primary))),
            if (evs.isEmpty) Padding(padding: const EdgeInsets.only(top: 12), child: ActionChip(avatar: const Text('👋'), label: const Text('Say hello'), onPressed: () { input.text = 'Hello 👋'; send(); })),
          ])))),
        Expanded(child: ListView.builder(reverse: true, itemCount: evs.length, itemBuilder: (_, i) {
          final e = evs[i];
          // a read receipt on a message means everything before it has been read too (newest-first list)
          final readIdx = evs.indexWhere((x) => x.receipts.any((r) => r.user.id != me));
          final newDay = i == evs.length - 1 || !DateUtils.isSameDay(e.originServerTs, evs[i + 1].originServerTs);
          return Column(children: [
            if (newDay) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Chip(label: Text(DateFormat('EEEE d MMMM').format(e.originServerTs)))),
            _item(c, e, isLastMine: e.senderId == me && evs.indexWhere((x) => x.senderId == me) == i, read: readIdx >= 0 && i >= readIdx),
          ]);
        })),
        if (outbox.items.isNotEmpty) Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
          for (final o in outbox.items) Align(alignment: Alignment.centerRight, child: Container(
            margin: const EdgeInsets.fromLTRB(60, 2, 8, 2), padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: cs.errorContainer.withValues(alpha: .5), borderRadius: BorderRadius.circular(14)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Text(o.text),
              InkWell(onTap: () async {
                final a = await showModalBottomSheet<String>(context: c, builder: (s) => SafeArea(child: Wrap(children: [
                  const ListTile(title: Text('Message not sent'), subtitle: Text('It is kept on this device and retried automatically every 10 seconds.')),
                  ListTile(leading: const Icon(Icons.refresh), title: const Text('Retry'), onTap: () => Navigator.pop(s, 'retry')),
                  ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(s, 'del'))])));
                if (a == 'retry') await outbox.retry(o);
                if (a == 'del') await outbox.delete(o);
              }, child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.error, size: 14, color: cs.error),
                Text(' Not sent · tap', style: TextStyle(fontSize: 11, color: cs.error))])),
            ])))]),
        if (replyTo != null || editing != null) Container(color: cs.surfaceContainerHighest, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [
          Icon(editing != null ? Icons.edit : Icons.reply, size: 18), const SizedBox(width: 8),
          Expanded(child: Text(editing != null ? 'Editing message' : 'Replying to ${replyTo!.senderFromMemoryOrFallback.calcDisplayname()}: ${_text(replyTo!)}', maxLines: 1, overflow: TextOverflow.ellipsis)),
          IconButton(icon: const Icon(Icons.close, size: 18), onPressed: () => setState(() { replyTo = null; editing = null; input.clear(); }))])),
        if (_mentionCandidates().isNotEmpty) Material(elevation: 2, child: Column(children: [for (final u in _mentionCandidates()) ListTile(dense: true,
          leading: CircleAvatar(radius: 14, child: Text(u.calcDisplayname().characters.first.toUpperCase())), title: Text(u.calcDisplayname()), subtitle: Text(u.id), onTap: () => _insertMention(u))])),
        if (_format) Row(children: [
          IconButton(tooltip: 'Bold', icon: const Icon(Icons.format_bold), onPressed: () => _wrap('**')),
          IconButton(tooltip: 'Italic', icon: const Icon(Icons.format_italic), onPressed: () => _wrap('_')),
          IconButton(tooltip: 'Strikethrough', icon: const Icon(Icons.format_strikethrough), onPressed: () => _wrap('~~')),
          IconButton(tooltip: 'Code', icon: const Icon(Icons.code), onPressed: () => _wrap('`')),
          IconButton(tooltip: 'Quote', icon: const Icon(Icons.format_quote), onPressed: () => _wrap('> ', '')),
          IconButton(tooltip: 'List', icon: const Icon(Icons.format_list_bulleted), onPressed: () => _wrap('- ', '')),
        ]),
        if (widget.filesOnly) const SizedBox.shrink() else
        SafeArea(child: Padding(padding: const EdgeInsets.all(8), child: _recStart != null
          ? Row(children: [
              IconButton(tooltip: 'Cancel', icon: const Icon(Icons.delete_outline), onPressed: _cancelRecord),
              const Icon(Icons.fiber_manual_record, color: Colors.red), const SizedBox(width: 8),
              Expanded(child: Text('Recording ${DateTime.now().difference(_recStart!).inSeconds}s · tap send to share (encrypted)')),
              IconButton.filled(icon: const Icon(Icons.send), onPressed: _toggleRecord)])
          : Row(children: [
              IconButton(tooltip: 'Photo, file, poll or checklist', icon: const Icon(Icons.add_circle_outline), onPressed: _attachMenu),
              IconButton(tooltip: 'Formatting', icon: Icon(Icons.text_format, color: _format ? Theme.of(c).colorScheme.primary : null), onPressed: () => setState(() => _format = !_format)),
              Expanded(child: TextField(controller: input, minLines: 1, maxLines: 5, onChanged: (t) { _onTyping(t); setState(() {}); }, textInputAction: TextInputAction.send,
                  decoration: const InputDecoration(hintText: 'Message', border: OutlineInputBorder(), isDense: true), onSubmitted: (_) => send())),
              input.text.trim().isEmpty && editing == null
                  ? IconButton.filledTonal(tooltip: 'Record voice message', icon: const Icon(Icons.mic), onPressed: _toggleRecord)
                  : GestureDetector(onLongPress: editing == null ? _sendLater : null,
                      child: IconButton.filled(tooltip: 'Send (long-press to schedule)', icon: Icon(editing != null ? Icons.check : Icons.send), onPressed: send))]))),
      ]),
    );
  }

  /// Delivery status of my own message: 🕓 sending · ✓ on the server · ✓✓ read · ⚠ failed (tap: retry or delete).
  Widget _status(BuildContext c, Event e, bool read) {
    final cs = Theme.of(c).colorScheme;
    if (e.status.isError) {
      return InkWell(onTap: () async {
        final a = await showModalBottomSheet<String>(context: c, builder: (s) => SafeArea(child: Wrap(children: [
          const ListTile(title: Text('Message not sent'), subtitle: Text('It is kept on this device until you retry or delete it.')),
          ListTile(leading: const Icon(Icons.refresh), title: const Text('Retry'), onTap: () => Navigator.pop(s, 'retry')),
          ListTile(leading: const Icon(Icons.delete_outline), title: const Text('Delete'), onTap: () => Navigator.pop(s, 'del'))])));
        if (a == 'retry') await e.sendAgain();
        if (a == 'del') await e.cancelSend();
        if (mounted) setState(() {});
      }, child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.error, size: 14, color: cs.error), Text(' Not sent · tap', style: TextStyle(fontSize: 11, color: cs.error))]));
    }
    if (e.status.isSending) return const Icon(Icons.schedule, size: 14);
    return Icon(read ? Icons.done_all : Icons.done, size: 14, color: read ? cs.primary : null);
  }

  Widget _item(BuildContext c, Event e, {required bool isLastMine, bool read = false}) {
    final cs = Theme.of(c).colorScheme; final mine = e.senderId == me;
    if (e.type == kCallInviteEvent && e.content['version'] == 2) {
      final v = e.content['media'] != 'audio';
      final sm = CallSummary.of(tl?.events ?? const [], e.content['call_id'] as String, e.originServerTs);
      final bad = {'missed', 'declined', 'busy', 'failed'}.contains(sm.outcome);
      return ListTile(leading: CircleAvatar(backgroundColor: bad ? cs.errorContainer : null,
          child: Icon(sm.outcome == 'missed' ? Icons.phone_missed : v ? Icons.videocam : Icons.call, color: bad ? cs.error : null)),
        title: Text(sm.label(mine, v), style: TextStyle(color: bad && !mine ? cs.error : null)),
        subtitle: Text('${DateFormat('HH:mm').format(e.originServerTs)} · end-to-end encrypted'),
        trailing: sm.outcome == 'live' ? null : IconButton.filledTonal(tooltip: 'Call back', icon: Icon(v ? Icons.videocam : Icons.call),
          onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, video: v)))));
    }
    if (e.type == kCallInviteEvent) {
      final v = e.content['media'] != 'audio';
      final meet = (e.content['call_id'] as String? ?? '').startsWith('meet-');
      if (meet) {
        return FutureBuilder<int>(future: _live(e.content['call_id'] as String), builder: (_, s) {
          final n = s.data ?? 0;
          return ListTile(leading: CircleAvatar(child: Icon(n > 0 ? Icons.groups : Icons.groups_outlined)),
            title: Text(!s.hasData ? 'Meeting' : n > 0 ? 'Meeting in progress · $n ${n == 1 ? 'person' : 'people'}' : 'Meeting ended'),
            subtitle: Text('Started by ${e.senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('HH:mm').format(e.originServerTs)} · encrypted'),
            trailing: FilledButton(child: Text(n > 0 ? 'Join' : 'Start'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, meeting: true, video: v)))));
        });
      }
      return ListTile(leading: CircleAvatar(child: Icon(v ? Icons.videocam : Icons.call)), title: Text(v ? 'Video call' : 'Voice call'),
        subtitle: Text('${e.senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('HH:mm').format(e.originServerTs)} · encrypted'),
        trailing: FilledButton(child: const Text('Join'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => meet
            ? CallScreen(roomId: room.id, meeting: true, video: v) : CallScreen(roomId: room.id, video: v)))));
    }
    if (e.type == kCallEndEvent && e.content['version'] == 2) return const SizedBox.shrink();   // shown on the call card
    if (e.type == kCallEndEvent) {
      return Center(child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Text(e.body, style: Theme.of(c).textTheme.labelSmall)));
    }
    if (e.type == 'com.amerteams.meeting') {
      final id = e.content['meeting_id'] as String?;
      final st = DateTime.tryParse(e.content['start'] as String? ?? '')?.toLocal();
      final rsvps = <String, String>{};
      for (final x in (tl?.events ?? []).reversed) {
        if (x.type == 'com.amerteams.meeting.rsvp' && x.content['meeting_id'] == (id ?? e.eventId)) rsvps[x.senderId] = x.content['response'] as String? ?? '';
      }
      final count = (String k) => rsvps.values.where((v) => v == k).length;
      Widget rsvp(String k, String label, IconData i) => ChoiceChip(avatar: Icon(i, size: 16), label: Text('$label ${count(k)}'), selected: rsvps[me] == k,
          onSelected: (_) => room.sendEvent({'meeting_id': id ?? e.eventId, 'response': k, 'body': '${{'yes': '✅', 'maybe': '❔', 'no': '❌'}[k]} $label'}, type: 'com.amerteams.meeting.rsvp'));
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Column(children: [ListTile(leading: const Icon(Icons.event),
        title: Text('${e.content['title'] as String? ?? 'Meeting'}${(e.content['recurrence'] ?? 'none') != 'none' ? ' · repeats ${e.content['recurrence']}' : ''}'),
        subtitle: Text('${st != null ? DateFormat('EEE d MMM, HH:mm').format(st) : ''} · ${e.content['duration_min']} min${id != null ? '\nID ${MeetingService.format(id)}' : ''}'),
        isThreeLine: id != null,
        trailing: FilledButton(child: const Text('Join'), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, meeting: id != null))))),
        Padding(padding: const EdgeInsets.fromLTRB(12, 0, 12, 10), child: Wrap(spacing: 6, children: [
          rsvp('yes', 'Accept', Icons.check), rsvp('maybe', 'Maybe', Icons.help_outline), rsvp('no', 'Decline', Icons.close)])),
      ]));
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
    if (e.type == kChecklistEvent) {
      final items = (e.content['items'] as List? ?? []).cast<String>(); final ticks = _ticks(e);
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        ListTile(dense: true, leading: const Icon(Icons.checklist), title: Text(e.content['title'] as String? ?? 'Checklist'),
          subtitle: Text('${ticks.values.where((v) => v).length}/${items.length} done · ${e.senderFromMemoryOrFallback.calcDisplayname()}')),
        for (var i = 0; i < items.length; i++) CheckboxListTile(dense: true, value: ticks[i] ?? false, title: Text(items[i],
            style: TextStyle(decoration: (ticks[i] ?? false) ? TextDecoration.lineThrough : null)),
          onChanged: (v) => room.sendEvent({'checklist': e.eventId, 'item': i, 'done': v == true, 'body': '${v == true ? '☑' : '☐'} ${items[i]}'}, type: kChecklistTick)),
      ])));
    }
    if (e.redacted) {
      return Align(alignment: mine ? Alignment.centerRight : Alignment.centerLeft, child: Padding(padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 4),
        child: Text(e.redactedBecause != null && e.redactedBecause!.senderId != e.senderId
            ? '🚫 Deleted by ${e.redactedBecause!.senderFromMemoryOrFallback.calcDisplayname()}' : '🚫 This message was deleted', style: TextStyle(fontStyle: FontStyle.italic, color: cs.outline))));
    }
    final shown = tl == null ? e : e.getDisplayEvent(tl!);
    final edited = shown.eventId != e.eventId;
    final reactions = tl == null ? <String, int>{} : reactionsFor(tl!.events, e.eventId);

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
      final mentioned = mentionsMe(e, me);
      body = Container(color: mentioned && !mine ? cs.tertiaryContainer : null, child: Text(_text(e)));
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
            if (mine) Padding(padding: const EdgeInsets.only(left: 4), child: _status(c, e, read)),
            const SizedBox(width: 6),
            InkWell(key: ValueKey('msg-options-${e.eventId}'), borderRadius: BorderRadius.circular(10), onTap: () => _actions(e),
              child: Tooltip(message: 'Reply, react, forward, edit, delete…', child: Icon(Icons.more_horiz, size: 18, color: cs.onSurfaceVariant))),
          ]),
          if (widget.threadRootId == null && _replyCount(e) > 0) TextButton.icon(style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact),
            onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, threadRootId: e.eventId))),
            icon: const Icon(Icons.forum_outlined, size: 16), label: Text('${_replyCount(e)} repl${_replyCount(e) == 1 ? 'y' : 'ies'}')),
          if (reactions.isNotEmpty) Wrap(spacing: 4, children: [for (final r in reactions.entries) Chip(visualDensity: VisualDensity.compact, padding: EdgeInsets.zero,
            label: Text('${r.key} ${r.value}'))]),
        ]))));
  }
}
