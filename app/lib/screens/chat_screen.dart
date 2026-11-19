import 'meeting_twin_screen.dart';
import 'team_room_bar.dart';
import 'frontline_screen.dart';
import 'skills_screen.dart';
import 'operator_screen.dart';
import '../services/premortem.dart';
import '../services/office_text.dart';
import 'file_preview_screen.dart';
import 'dart:math' show min;
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
import '../services/workflow_engine.dart';
import 'canvas_screen.dart';
import 'find_time_screen.dart';
import 'tasks_screen.dart';
import 'security_badge.dart';
import '../services/quick_views.dart';
import '../services/feature_flags.dart';
import '../services/ai_gate.dart';
import '../services/dlp.dart';
import '../services/decisions_tasks.dart';

const kAnnouncement = 'com.amerteams.announcement', kAck = 'com.amerteams.ack';

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
  final _translated = <String, String>{};          // translation cache per message, this session
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
    if (widget.threadRootId == null && !widget.filesOnly) {
      Drafts.instance.load().then((_) { final d = Drafts.instance.of(room.id); if (d != null && input.text.isEmpty && mounted) setState(() => input.text = d); });
    }
    if (widget.threadRootId != null) Threads.markSeen(room.client, room.id, widget.threadRootId!).catchError((_) {});
    WidgetsBinding.instance.addPostFrameCallback((_) async {
      tl = await room.getTimeline(onUpdate: () { if (mounted) setState(() {}); _markRead(); });
      final dm = room.directChatMatrixID; if (dm != null) _presence = room.client.fetchCurrentPresence(dm);
      _markRead(); setState(() {});
    });
  }
  @override void dispose() { if (widget.threadRootId == null && !widget.filesOnly && editing == null) Drafts.instance.set(room.id, input.text); tl?.cancelSubscriptions(); typingOff?.cancel(); if (typing) _safeTyping(false); outbox.dispose(); _rec.dispose(); _player.dispose(); super.dispose(); }

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

  // ---------- slash commands (docs/CHAT_EXTRAS.md) ----------
  static const slash = {
    '/poll': 'Create a poll', '/meet': 'Start a meeting in this chat now', '/remind': '/remind 30 text: remind me in 30 minutes',
    '/ask': '/ask question: ask Amer, answer only you see', '/announce': '/announce text: announcement everyone acknowledges',
    '/later': 'Schedule this message', '/canvas': 'Open this chat\'s canvases', '/premortem': '/premortem plan: how could this fail? (or the recent chat)', '/skill': 'Run one of your skills or agents on this chat'};
  Future<bool> _command(String t) async {
    if (!t.startsWith('/')) return false;
    final sp = t.indexOf(' '); final cmd = (sp < 0 ? t : t.substring(0, sp)).toLowerCase(); final arg = sp < 0 ? '' : t.substring(sp + 1).trim();
    switch (cmd) {
      case '/poll': await _newPoll();
      case '/meet': Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, meeting: true)));
      case '/canvas': Navigator.push(context, MaterialPageRoute(builder: (_) => CanvasListScreen(room: room)));
      case '/later': input.text = arg; await _sendLater();
      case '/announce':
        if (arg.isEmpty) { _snack('Write the announcement after /announce'); return true; }
        await room.sendEvent({'body': '📣 $arg', 'text': arg}, type: kAnnouncement);
      case '/remind':
        final m = RegExp(r'^(\d+)\s*(.*)$').firstMatch(arg);
        if (m == null) { _snack('Use /remind 30 what to remember'); return true; }
        Reminders.instance.add(room.id, '', m.group(2)!.isEmpty ? 'Reminder' : m.group(2)!, DateTime.now().add(Duration(minutes: int.parse(m.group(1)!))));
        _snack('I will remind you in ${m.group(1)} minutes');
      case '/premortem': await _premortem(arg);
      case '/skill':
        final ctx = (tl?.events ?? []).where((e) => e.type == EventTypes.Message).take(30).toList().reversed.map((e) => '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${plainMentions(e.body)}').join('\n');
        Navigator.push(context, MaterialPageRoute(builder: (_) => SkillsScreen(room: room, context: ctx)));
      case '/ask':
        if (arg.isEmpty) { _snack('Write a question after /ask'); return true; }
        final g = aiFor(room); if (!g.allowed) { _snack(g.where); return true; }
        final label = room.getState('com.amerteams.sensitivity')?.content['label'] as String?;
        final ctx = (tl?.events ?? []).where((e) => e.type == EventTypes.Message).take(30).toList().reversed.map((e) => '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${plainMentions(e.body)}').join('\n');
        try {
          final r = await context.read<ApiService>().ask(arg, context: 'Recent messages in this chat:\n$ctx', labels: [if (label != null) label], encrypted: room.encrypted);
          if (mounted) showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Amer · only you can see this', style: TextStyle(fontWeight: FontWeight.w600)), const SizedBox(height: 8), SelectableText('${r['answer']}'), const SizedBox(height: 8), Text(g.where, style: const TextStyle(fontSize: 12))])));
        } catch (e) { _snack('Amer could not answer: $e'); }
      default:
        final near = slash.keys.where((k) => k.startsWith(cmd.substring(0, min(3, cmd.length)))).join(', ');
        _snack('Unknown command $cmd. Try ${near.isEmpty ? slash.keys.join(', ') : near}');
    }
    return true;
  }

  /// Pre-mortem agent (docs/PREMORTEM.md): risks only you see first; share them or turn mitigations into tasks.
  Future<void> _premortem(String plan) async {
    final g = aiFor(room); if (!g.allowed) { _snack(g.where); return; }
    final label = room.getState('com.amerteams.sensitivity')?.content['label'] as String?;
    final ctx = plan.isNotEmpty ? plan : (tl?.events ?? []).where((e) => e.type == EventTypes.Message).take(40).toList().reversed.map((e) => '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${plainMentions(e.body)}').join('\n');
    if (ctx.trim().isEmpty) { _snack('Write the plan after /premortem'); return; }
    _snack('Amer is imagining how this could fail…');
    try {
      final r = await context.read<ApiService>().ask('Run a pre-mortem on this plan.', context: ctx, agent: 'premortem', labels: [if (label != null) label], encrypted: room.encrypted);
      if (r['blocked'] == true) { _snack('${r['answer']}'); return; }
      final p = PreMortem.parse('${r['answer']}');
      if (!mounted) return;
      final picked = <int>{};
      await showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => StatefulBuilder(builder: (s, set) => DraggableScrollableSheet(expand: false, initialChildSize: 0.8, builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.all(16), children: [
        Text('Pre-mortem · only you can see this', style: Theme.of(s).textTheme.titleMedium), if (p.summary.isNotEmpty) Text(p.summary), Text(g.where, style: const TextStyle(fontSize: 12)),
        for (var i = 0; i < p.risks.length; i++) CheckboxListTile(value: picked.contains(i), onChanged: (v) => set(() => v! ? picked.add(i) : picked.remove(i)),
          title: Text('${p.risks[i]['risk']}'), subtitle: Text('Likelihood ${p.risks[i]['likelihood']} · impact ${p.risks[i]['impact']}\n${p.risks[i]['why_it_fails']}\nWatch for: ${p.risks[i]['early_warning']}\nMitigation: ${p.risks[i]['mitigation']}'), isThreeLine: true),
        Wrap(spacing: 8, children: [
          OutlinedButton.icon(icon: const Icon(Icons.share), label: const Text('Share in chat'), onPressed: () async { Navigator.pop(s); await room.sendTextEvent(p.toMessage()); }),
          FilledButton.icon(icon: const Icon(Icons.add_task), label: Text('Make ${picked.length} mitigation task${picked.length == 1 ? '' : 's'}'), onPressed: picked.isEmpty ? null : () async {
            Navigator.pop(s);
            for (final i in picked) { await saveTask(room, {'task_id': 'pm-${DateTime.now().microsecondsSinceEpoch}-$i', 'title': 'Mitigate: ${p.risks[i]['mitigation']}', 'owner': room.client.userID, 'status': 'open', 'reason': 'Pre-mortem risk: ${p.risks[i]['risk']}'}); }
            _snack('Added ${picked.length} task(s)'); }),
        ]),
      ]))));
    } catch (e) { _snack('Pre-mortem failed: $e'); }
  }

  /// Post-incident review (docs/OPERATOR_MODE.md): drafted by Amer from this war room's timeline, shown to you first.
  Future<void> _incidentReview() async {
    final g = aiFor(room); if (!g.allowed) { _snack(g.where); return; }
    final s = room.getState(kIncident)!.content;
    final evs = (tl?.events ?? []).where((e) => e.type == EventTypes.Message).toList().reversed;
    final timeline = evs.map((e) => '${e.originServerTs.toUtc().toIso8601String().substring(11, 16)}Z ${e.senderFromMemoryOrFallback.calcDisplayname()}: ${plainMentions(e.body)}').join('\n');
    _snack('Amer is drafting the review…');
    try {
      final r = await context.read<ApiService>().ask('Write a blameless post-incident review for ${s['number']} (${s['severity']}, ${s['service']}). Sections: Summary; Impact (${s['impact'] ?? 'unknown'}); Timeline (UTC, from the messages); Root cause (say "not yet known" if the chat does not establish it); What went well; What went badly; Actions (owner, due). British English. Never invent facts that are not in the timeline.',
          context: timeline, agent: 'minutes', encrypted: room.encrypted);
      if (!mounted) return;
      final text = '${r['answer']}';
      await showModalBottomSheet(context: context, isScrollControlled: true, builder: (b) => DraggableScrollableSheet(expand: false, initialChildSize: 0.85, builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.all(16), children: [
        Text('Draft post-incident review · only you see it until you share', style: Theme.of(b).textTheme.titleMedium), Text(g.where, style: const TextStyle(fontSize: 12)), const SizedBox(height: 8),
        SelectableText(text), const SizedBox(height: 12),
        FilledButton.icon(onPressed: () async { Navigator.pop(b); await room.sendTextEvent('📝 Post-incident review (draft)\n$text'); }, icon: const Icon(Icons.share), label: const Text('Share in the war room')),
      ])));
    } catch (e) { _snack('Could not draft the review: $e'); }
  }

  Future<void> send() async {
    final t = input.text.trim(); if (t.isEmpty) return;
    if (editing == null && t.startsWith('/') && !t.startsWith('//')) { input.clear(); setState(() {}); await _command(t); return; }   // '//' sends a literal slash
    if (room.getState('com.amerteams.shared') != null) {          // data-loss check before it leaves for another organisation
      final hits = dlpScan(t);
      if (hits.isNotEmpty) {
        await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Not sent'),
          content: Text('This channel is shared with another organisation, and your message contains a ${hits.map((h) => h.kind).toSet().join(' and a ')}. Remove it, or share it another way.'),
          actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Edit message'))]));
        return;                                                    // the text stays in the box
      }
    }
    input.clear();
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
    setState(() {}); _snack('Scheduled for ${DateFormat('d MMM HH:mm').format(at)}. Sent from this device; if the app is closed then, it is sent when you next open it.');
  }

  /// Scheduled messages for this chat: edit the text, change the time, send now, or cancel. Editable until sent.
  Future<void> _scheduledList() async {
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => StatefulBuilder(builder: (s, set) {
      final items = ScheduledSender.instance.forRoom(room.id);
      return SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
        const ListTile(title: Text('Scheduled messages'), subtitle: Text('Kept on this device and sent from it at the time; the server never holds the text')),
        for (final i in items) ListTile(leading: const Icon(Icons.schedule_send), title: Text('${i['text']}', maxLines: 2, overflow: TextOverflow.ellipsis),
          subtitle: Text(DateFormat('EEE d MMM HH:mm').format(DateTime.parse('${i['at']}'))),
          trailing: PopupMenuButton<String>(onSelected: (v) async {
            if (v == 'now') ScheduledSender.instance.edit('${i['id']}', at: DateTime.now());
            if (v == 'cancel') ScheduledSender.instance.cancel('${i['id']}');
            if (v == 'edit') {
              final t = TextEditingController(text: '${i['text']}');
              final nt = await showDialog<String>(context: s, builder: (d) => AlertDialog(title: const Text('Edit scheduled message'), content: TextField(controller: t, maxLines: 5),
                actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, t.text), child: const Text('Save'))]));
              if (nt != null && nt.trim().isNotEmpty) ScheduledSender.instance.edit('${i['id']}', text: nt.trim());
            }
            if (v == 'time' && s.mounted) {
              final at = DateTime.parse('${i['at']}');
              final d = await showDatePicker(context: s, initialDate: at, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 30)));
              if (d == null || !s.mounted) return;
              final tm = await showTimePicker(context: s, initialTime: TimeOfDay.fromDateTime(at));
              if (tm != null) ScheduledSender.instance.edit('${i['id']}', at: DateTime(d.year, d.month, d.day, tm.hour, tm.minute));
            }
            set(() {}); if (mounted) setState(() {});
          }, itemBuilder: (_) => const [PopupMenuItem(value: 'edit', child: Text('Edit text')), PopupMenuItem(value: 'time', child: Text('Change time')),
            PopupMenuItem(value: 'now', child: Text('Send now')), PopupMenuItem(value: 'cancel', child: Text('Cancel'))])),
        if (items.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Nothing scheduled')),
      ]));
    }));
    if (mounted) setState(() {});
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
    final g = aiFor(room); if (!g.allowed) { _snack(g.where); return; }
    final label = room.getState('com.amerteams.sensitivity')?.content['label'] as String?;    // Guardian blocks Confidential/Restricted
    final r = await context.read<ApiService>().ask('Summarise this thread', context: text, agent: 'summ', labels: [if (label != null) label], encrypted: room.encrypted);
    if (!mounted) return;
    showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(r['answer']), const SizedBox(height: 8), Text(g.where, style: const TextStyle(fontSize: 12))]))));
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
      ListTile(leading: const Icon(Icons.alarm_add_outlined), title: const Text('Remind me'), onTap: () => Navigator.pop(s, 'remind')),
      ListTile(leading: const Icon(Icons.add_task), title: const Text('Create task'), onTap: () => Navigator.pop(s, 'task')),
      ListTile(leading: const Icon(Icons.gavel), title: const Text('Mark as decision'), onTap: () => Navigator.pop(s, 'decision')),
      ListTile(leading: const Icon(Icons.copy), title: const Text('Copy'), onTap: () => Navigator.pop(s, 'copy')),
      if (canEdit) ListTile(leading: const Icon(Icons.edit), title: const Text('Edit'), onTap: () => Navigator.pop(s, 'edit')),
      if (canDelete) ListTile(leading: Icon(Icons.delete, color: Theme.of(context).colorScheme.error), title: Text(mine ? 'Delete for everyone' : 'Delete for everyone (moderator)'), onTap: () => Navigator.pop(s, 'delete')),
      if (mine && !canEdit && e.messageType == MessageTypes.Text) const ListTile(dense: true, leading: Icon(Icons.info_outline), title: Text('Messages can be edited for 24 hours')),
    ]))));
    if (a == null) return;
    if (a.startsWith('react:')) await sendEncryptedReaction(room, e.eventId, a.substring(6));
    if (a == 'reply') setState(() { replyTo = e; editing = null; });
    if (a == 'copy') await Clipboard.setData(ClipboardData(text: _text(e)));
    if (a == 'task' && mounted) await editTask(context, room, title: plainMentions(_text(e)), sourceEvent: e.eventId);
    if (a == 'decision' && mounted) await proposeDialog(context, room, text: plainMentions(_text(e)), sourceEvent: e.eventId);
    if (a == 'remind' && mounted) {
      final now = DateTime.now(), tomorrow9 = DateTime(now.year, now.month, now.day + 1, 9);
      final at = await showDialog<DateTime>(context: context, builder: (d) => SimpleDialog(title: const Text('Remind me'), children: [
        for (final (l, t) in [('In 20 minutes', now.add(const Duration(minutes: 20))), ('In 1 hour', now.add(const Duration(hours: 1))),
                              ('In 3 hours', now.add(const Duration(hours: 3))), ('Tomorrow at 09:00', tomorrow9)])
          SimpleDialogOption(onPressed: () => Navigator.pop(d, t), child: Text(l))]));
      if (at != null) { Reminders.instance.add(room.id, e.eventId, '${e.senderFromMemoryOrFallback.calcDisplayname()}: ${plainMentions(_text(e))}', at); _snack('Reminder set for ${DateFormat('d MMM HH:mm').format(at)}'); }
    }
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
        final label = room.getState('com.amerteams.sensitivity')?.content['label'] as String?;
        final gate = aiFor(room, small: true);
        if (!gate.allowed) { _snack(gate.where); return; }
        final r = a == 'translate' && _translated.containsKey(e.eventId) ? {'answer': _translated[e.eventId]}
            : await context.read<ApiService>().ask(a == 'translate' ? 'Translate to ${Localizations.localeOf(context).languageCode == 'ar' ? 'English' : 'Arabic'}' : 'Suggest a short, polite reply to this message',
            context: plainMentions(_text(e)), agent: a == 'translate' ? 'trans' : 'assist', labels: [if (label != null) label], encrypted: room.encrypted);
        if (a == 'translate' && r['blocked'] != true) _translated[e.eventId] = '${r['answer']}';
        if (!mounted) return;
        if (a == 'suggest') { setState(() => input.text = r['answer'] as String); } else {
          showModalBottomSheet(context: context, builder: (_) => Padding(padding: const EdgeInsets.all(20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [SelectableText(r['answer'] as String), const SizedBox(height: 8), Text(gate.where, style: const TextStyle(fontSize: 12))])));
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
    const shownTypes = {kDecisionProposal, kTask, kAnnouncement, 'com.amerteams.canvas.create', EventTypes.Message, EventTypes.Encrypted, kCallInviteEvent, kCallEndEvent, 'com.amerteams.meeting', PollEventContent.startType, kChecklistEvent};
    final lifetime = (room.getState('m.room.retention')?.content['max_lifetime'] as num?)?.toInt();
    final latestTask = <String>{}; final hideTask = <String>{};
    for (final e in (tl?.events ?? []).where((e) => e.type == kTask)) { if (!latestTask.add('${e.content['task_id']}')) hideTask.add(e.eventId); }
    var evs = (tl?.events ?? []).where((e) => shownTypes.contains(e.type) && !hideTask.contains(e.eventId) && e.relationshipType != RelationshipTypes.edit
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
          if (widget.threadRootId != null) PopupMenuButton<String>(tooltip: 'Thread notifications', icon: Icon(switch (Threads.mode(room.client, room.id, widget.threadRootId!)) {
              'follow' => Icons.notifications_active, 'mute' => Icons.notifications_off, _ => Icons.notifications_none }),
            onSelected: (v) async { await Threads.setMode(room.client, room.id, widget.threadRootId!, v == 'none' ? null : v); if (mounted) setState(() {}); },
            itemBuilder: (_) => const [PopupMenuItem(value: 'follow', child: Text('Follow this thread')), PopupMenuItem(value: 'mute', child: Text('Mute this thread')), PopupMenuItem(value: 'none', child: Text('Default'))]),
          IconButton(tooltip: 'Encryption details', icon: Icon(room.encrypted ? Icons.lock : Icons.lock_open, color: room.encrypted ? Colors.green : Theme.of(c).colorScheme.error), onPressed: () => showSecurityDetails(c, room)),
          IconButton(tooltip: searching ? 'Close search' : 'Search', icon: Icon(searching ? Icons.close : Icons.search), onPressed: () => setState(() { searching = !searching; searchCtl.clear(); })),
          if (Flags.instance.on('canvases')) IconButton(tooltip: 'Canvases', icon: const Icon(Icons.description_outlined), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CanvasListScreen(room: room)))),
          IconButton(tooltip: 'Voice call', icon: const Icon(Icons.call), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id, video: false)))),
          IconButton(tooltip: 'Video call', icon: const Icon(Icons.videocam), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: room.id)))),
          PopupMenuButton<String>(tooltip: 'Chat menu', onSelected: (v) {
            if (v == 'sum') summarise();
            if (v == 'info') Navigator.push(c, MaterialPageRoute(builder: (_) => ChatInfoScreen(roomId: room.id)));
            if (v == 'files') Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: room.id, filesOnly: true)));
            if (v == 'time') Navigator.push(c, MaterialPageRoute(builder: (_) => FindTimeScreen(room: room)));
            if (v == 'tasks') Navigator.push(c, MaterialPageRoute(builder: (_) => TasksScreen(room: room)));
            if (v == 'twin') Navigator.push(c, MaterialPageRoute(builder: (_) => MeetingTwinScreen(room: room)));
            if (v == 'shifts') Navigator.push(c, MaterialPageRoute(builder: (_) => ShiftsScreen(room: room)));
            if (v == 'ptt') Navigator.push(c, MaterialPageRoute(builder: (_) => WalkieTalkieScreen(room: room)));
          }, itemBuilder: (_) => [
            const PopupMenuItem(value: 'twin', child: Text('Meeting twin')),
            const PopupMenuItem(value: 'shifts', child: Text('Shifts')),
            if (room.encrypted) const PopupMenuItem(value: 'ptt', child: Text('Walkie-talkie')),
            if (Flags.instance.on('decisions')) const PopupMenuItem(value: 'tasks', child: Text('Tasks')),
            if (Flags.instance.on('find_time')) const PopupMenuItem(value: 'time', child: Text('Find a time')),
            const PopupMenuItem(value: 'info', child: Text('Chat info')),
            const PopupMenuItem(value: 'files', child: Text('Files and media')),
            const PopupMenuItem(value: 'sum', child: Text('Summarise with Amer'))]),
        ]),
      body: Column(children: [
        if (room.getState(kIncident) != null) IncidentBanner(room: room, onReview: _incidentReview),
        if (!room.isDirectChat && room.encrypted && !widget.filesOnly) TeamRoomBar(room: room),
        if (lifetime != null) Container(width: double.infinity, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4), color: Theme.of(c).colorScheme.surfaceContainerHigh,
          child: Row(children: [const Icon(Icons.timer_outlined, size: 14), const SizedBox(width: 6), Expanded(child: Text(
            'Disappearing messages: deleted after ${lifetime >= 31536000000 ? '${lifetime ~/ 31536000000} year${lifetime >= 63072000000 ? 's' : ''}' : lifetime >= 86400000 ? '${lifetime ~/ 86400000} day${lifetime >= 172800000 ? 's' : ''}' : '${lifetime ~/ 3600000} hours'}, on every device and on the server',
            style: const TextStyle(fontSize: 12)))])),
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
        if (!widget.filesOnly && input.text.startsWith('/') && !input.text.contains(' ')) Material(elevation: 2, child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (final k in slash.keys.where((k) => k.startsWith(input.text.toLowerCase()))) ListTile(dense: true, leading: const Icon(Icons.keyboard_command_key, size: 18),
            title: Text(k), subtitle: Text(slash[k]!), onTap: () { input.text = '$k '; input.selection = TextSelection.collapsed(offset: input.text.length); setState(() {}); }),
          if (slash.keys.every((k) => !k.startsWith(input.text.toLowerCase())) && input.text.length > 1) ListTile(dense: true, title: Text('No command ${input.text}'), subtitle: Text('Commands: ${slash.keys.join(' ')}')),
        ])),
        if (!widget.filesOnly && ScheduledSender.instance.forRoom(room.id).isNotEmpty) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(left: 8),
          child: ActionChip(avatar: const Icon(Icons.schedule_send, size: 18), label: Text('${ScheduledSender.instance.forRoom(room.id).length} scheduled'), onPressed: _scheduledList))),
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

  /// A workflow's form or approval request (docs/WORKFLOWS.md). Only the people asked get the buttons; the answer is an
  /// encrypted room event that the owner's workflow runner picks up.
  Widget _workflowCard(BuildContext c, Event e, Map<String, Object?> wf) {
    final cs = Theme.of(c).colorScheme;
    final people = ((wf['people'] as List?) ?? const []).cast<String>();
    final answers = (tl?.events ?? []).where((x) => x.type == kWfResponse && x.content['run'] == wf['run'] && x.content['step'] == wf['step'] && people.contains(x.senderId)).toList();
    final done = answers.isNotEmpty ? answers.first : null;
    final approval = wf['kind'] == 'approval', mine = people.contains(me) && done == null;
    Future<void> respond(Map<String, Object?> extra) =>
        room.sendEvent({'run': wf['run'], 'step': wf['step'], 'body': approval ? 'Workflow decision' : 'Workflow form answer', ...extra}, type: kWfResponse);
    Future<void> fill() async {
      final fields = ((wf['fields'] as List?) ?? const []).cast<String>();
      final ctrls = {for (final f in fields) f: TextEditingController()};
      final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text('${wf['workflow'] ?? 'Workflow'}'),
        content: Column(mainAxisSize: MainAxisSize.min, children: [for (final f in fields) TextField(controller: ctrls[f], decoration: InputDecoration(labelText: f))]),
        actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send'))]));
      if (ok == true) await respond({'values': {for (final f in fields) f: ctrls[f]!.text.trim()}});
    }
    final status = done == null ? 'Waiting for ${people.map((p) => room.unsafeGetUserFromMemoryOrFallback(p).calcDisplayname()).join(', ')}'
        : approval ? '${done.content['decision'] == 'approved' ? 'Approved' : 'Rejected'} by ${done.senderFromMemoryOrFallback.calcDisplayname()}'
        : 'Answered by ${done.senderFromMemoryOrFallback.calcDisplayname()}';
    return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(approval ? Icons.verified_outlined : Icons.assignment_outlined, size: 18, color: cs.primary), const SizedBox(width: 6),
        Expanded(child: Text('${wf['workflow'] ?? 'Workflow'} · ${approval ? 'Approval' : 'Form'}', style: Theme.of(c).textTheme.titleSmall))]),
      const SizedBox(height: 6), Text(e.body),
      const SizedBox(height: 6), Text(status, style: TextStyle(fontSize: 12, color: done == null ? cs.outline : cs.primary)),
      if (mine) Padding(padding: const EdgeInsets.only(top: 8), child: Wrap(spacing: 8, children: approval
          ? [OutlinedButton(onPressed: () => respond({'decision': 'rejected'}), child: const Text('Reject')), FilledButton(onPressed: () => respond({'decision': 'approved'}), child: const Text('Approve'))]
          : [FilledButton(onPressed: fill, child: const Text('Fill in'))])),
    ])));
  }

  /// Text with ``` code blocks rendered monospace with a copy button (Markdown is also sent as formatted_body by the SDK).
  Widget _rich(BuildContext c, String t) {
    if (!t.contains('```')) return Text(t);
    final parts = t.split('```'); final cs = Theme.of(c).colorScheme;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
      for (var i = 0; i < parts.length; i++)
        if (i.isOdd) () {
          final nl = parts[i].indexOf('\n'); final lang = nl > 0 && !parts[i].substring(0, nl).contains(' ') ? parts[i].substring(0, nl).trim() : '';
          final code = (lang.isNotEmpty ? parts[i].substring(nl + 1) : parts[i]).trimRight();
          return Container(margin: const EdgeInsets.symmetric(vertical: 4), padding: const EdgeInsets.fromLTRB(10, 4, 4, 8),
            decoration: BoxDecoration(color: cs.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: cs.outlineVariant)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [Text(lang.isEmpty ? 'code' : lang, style: TextStyle(fontSize: 11, color: cs.outline)), const Spacer(),
                IconButton(tooltip: 'Copy code', visualDensity: VisualDensity.compact, icon: const Icon(Icons.copy, size: 16), onPressed: () { Clipboard.setData(ClipboardData(text: code)); _snack('Code copied'); })]),
              SingleChildScrollView(scrollDirection: Axis.horizontal, child: SelectableText(code, style: const TextStyle(fontFamily: 'monospace', fontSize: 13))),
            ]));
        }()
        else if (parts[i].trim().isNotEmpty) Text(parts[i].trim()),
    ]);
  }

  // ---------- decisions (docs/DECISIONS.md) ----------
  Map<String, Map>? _ledger; DateTime? _ledgerAt;
  Map<String, Map> _ledgerNow() {
    if (_ledgerAt == null || DateTime.now().difference(_ledgerAt!) > const Duration(seconds: 15)) {
      _ledgerAt = DateTime.now();
      context.read<ApiService>().decisionsIn(room.id).then((l) { if (mounted) setState(() => _ledger = {for (final d in l.cast<Map>()) '${d['decision_id']}|${d['version']}': d}); }).catchError((_) {});
    }
    return _ledger ?? const {};
  }
  Widget _decision(BuildContext c, Event e) {
    final cs = Theme.of(c).colorScheme, k = '${e.content['decision_id']}|${e.content['version']}';
    final led = _ledgerNow()[k];
    final confirms = {for (final x in (tl?.events ?? []).where((x) => x.type == kDecisionConfirm && x.content['decision_id'] == e.content['decision_id'] && x.content['version'] == e.content['version'])) x.senderId};
    final owner = room.unsafeGetUserFromMemoryOrFallback('${e.content['owner']}').calcDisplayname();
    final expired = led == null && DateTime.now().difference(e.originServerTs) > const Duration(hours: 72);
    final status = led?['status'] as String?;
    return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), color: status == 'superseded' ? cs.surfaceContainerHigh : cs.primaryContainer.withValues(alpha: .5), child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [Icon(Icons.gavel, color: cs.primary), const SizedBox(width: 8), Expanded(child: Text(
          status == null ? (expired ? 'Proposed decision · not confirmed within 72 h' : 'Proposed decision') : status == 'superseded' ? 'Decision · superseded' : 'Decision · in the ledger (#${led!['seq']})',
          style: Theme.of(c).textTheme.titleSmall)), Text('v${e.content['version']}', style: Theme.of(c).textTheme.labelSmall)]),
      const SizedBox(height: 6),
      Text('${e.content['text']}', style: TextStyle(fontSize: 15, decoration: status == 'superseded' ? TextDecoration.lineThrough : null)),
      const SizedBox(height: 6),
      Text('Owner $owner${e.content['due'] != null ? ' · due ${e.content['due']}' : ''}${status != null && status != 'confirmed' && status != 'superseded' ? ' · ${status.replaceAll('_', ' ')}' : ''}', style: const TextStyle(fontSize: 12)),
      Text(confirms.isEmpty ? 'No confirmations yet: the owner and one other member are needed' : 'Confirmed by ${confirms.map((u) => room.unsafeGetUserFromMemoryOrFallback(u).calcDisplayname()).join(', ')}',
          style: TextStyle(fontSize: 12, color: cs.outline)),
      Wrap(spacing: 8, children: [
        if (status == null && !expired && !confirms.contains(me)) FilledButton.icon(icon: const Icon(Icons.check), label: const Text('Confirm'), onPressed: () async {
          try { final r = await confirmDecision(room, context.read<ApiService>(), e); _ledgerAt = null;
            _snack(r['status'] == 'confirmed' ? 'Confirmed: the decision is in the ledger' : 'Confirmed. Still needs ${r['needs']}.'); }
          catch (x) { debugPrint('DECISION confirm failed: $x');
            if (mounted) showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Could not confirm'), content: Text('$x'.replaceFirst('Exception: ', '')),
              actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('OK'))])); } }),
        if (status != 'superseded') TextButton(onPressed: () => proposeDialog(c, room, previous: e), child: const Text('Change (new version)')),
        if (led != null && e.content['owner'] == me && (status == 'confirmed' || status == 'in_progress')) TextButton(onPressed: () async {
          await context.read<ApiService>().decisionStatus('${e.content['decision_id']}', room.id, (e.content['version'] as num).toInt(), 'done'); _ledgerAt = null; setState(() {}); }, child: const Text('Mark done')),
      ]),
    ])));
  }

  /// Announcement with "I acknowledge"; the sender sees who has and has not, and can remind the rest.
  Widget _announcement(BuildContext c, Event e) {
    final cs = Theme.of(c).colorScheme;
    final acks = {for (final x in (tl?.events ?? []).where((x) => x.type == kAck && x.content['announcement'] == e.eventId)) x.senderId};
    final members = room.getParticipants().where((u) => u.membership == Membership.join && u.id != e.senderId && !u.id.startsWith('@amer')).toList();
    final pending = members.where((u) => !acks.contains(u.id)).toList();
    final mineAnn = e.senderId == me;
    return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), color: cs.secondaryContainer, child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [const Icon(Icons.campaign), const SizedBox(width: 8), Expanded(child: Text('Announcement · ${e.senderFromMemoryOrFallback.calcDisplayname()}', style: Theme.of(c).textTheme.titleSmall)),
        Text(DateFormat('d MMM HH:mm').format(e.originServerTs), style: Theme.of(c).textTheme.labelSmall)]),
      const SizedBox(height: 8), Text('${e.content['text'] ?? e.body}', style: const TextStyle(fontSize: 16)),
      const SizedBox(height: 8),
      Text('${acks.length} of ${members.length} acknowledged', style: TextStyle(fontSize: 12, color: cs.outline)),
      if (!mineAnn && !acks.contains(me)) Padding(padding: const EdgeInsets.only(top: 6), child: FilledButton.icon(icon: const Icon(Icons.check), label: const Text('I acknowledge'),
          onPressed: () => room.sendEvent({'announcement': e.eventId, 'body': 'Acknowledged'}, type: kAck))),
      if (!mineAnn && acks.contains(me)) const Padding(padding: EdgeInsets.only(top: 6), child: Text('✓ You acknowledged this')),
      if (mineAnn) ExpansionTile(tilePadding: EdgeInsets.zero, title: Text(pending.isEmpty ? 'Everyone acknowledged' : '${pending.length} pending'), children: [
        for (final u in members) ListTile(dense: true, leading: Icon(acks.contains(u.id) ? Icons.check_circle : Icons.schedule, color: acks.contains(u.id) ? Colors.green : cs.outline), title: Text(u.calcDisplayname())),
        if (pending.isNotEmpty) Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.notifications_active_outlined), label: const Text('Remind pending'),
          onPressed: () => room.sendTextEvent('Reminder: please acknowledge the announcement. ${pending.map((u) => mentionMarkdown(u.calcDisplayname(), u.id)).join(' ')}'))),
      ]),
    ])));
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
    if (e.type == kAnnouncement) return _announcement(c, e);
    if (e.type == kDecisionProposal) return _decision(c, e);
    if (e.type == kTask) return TaskTile(t: Task(e), onChanged: () => setState(() {}));
    if (e.type == 'com.amerteams.canvas.create') {
      return Card(margin: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: ListTile(leading: const Icon(Icons.description_outlined),
        title: Text('${e.content['title'] ?? 'Canvas'}'), subtitle: Text('Canvas by ${e.senderFromMemoryOrFallback.calcDisplayname()}'),
        trailing: const Icon(Icons.open_in_new), onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CanvasScreen(room: room, id: '${e.content['canvas_id']}')))));
    }
    final wf = e.type == EventTypes.Message ? e.content[kWfContent] : null;
    if (wf is Map && (wf['kind'] == 'form' || wf['kind'] == 'approval')) return _workflowCard(c, e, Map<String, Object?>.from(wf));
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
      final canPreview = e.messageType == MessageTypes.File && OfficeText.canPreview(e.body);
      body = InkWell(onTap: () => canPreview ? Navigator.push(c, MaterialPageRoute(builder: (_) => FilePreviewScreen(room: room, event: e, onDownload: () => download(e)))) : download(e),
        child: Row(mainAxisSize: MainAxisSize.min, children: [Icon(canPreview ? Icons.description : Icons.insert_drive_file), const SizedBox(width: 8),
        Flexible(child: Text(e.body)), const SizedBox(width: 8), canPreview ? IconButton(tooltip: 'Download', visualDensity: VisualDensity.compact, icon: const Icon(Icons.download, size: 18), onPressed: () => download(e)) : const Icon(Icons.download, size: 18)]));
    } else {
      final mentioned = mentionsMe(e, me);
      body = Container(color: mentioned && !mine ? cs.tertiaryContainer : null, child: _rich(c, _text(e)));
      if (looksLikeDecision(e.body) && !(tl?.events ?? []).any((x) => x.type == kDecisionProposal && x.content['source_event'] == e.eventId)) {
        body = Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [body,
          TextButton.icon(style: TextButton.styleFrom(padding: EdgeInsets.zero, visualDensity: VisualDensity.compact), icon: const Icon(Icons.gavel, size: 16),
            label: const Text('Looks like a decision · propose it'), onPressed: () => proposeDialog(c, room, text: plainMentions(_text(e)), sourceEvent: e.eventId))]);
      }
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
            if (e.content['com.amerteams.scheduled'] is Map) Text((e.content['com.amerteams.scheduled'] as Map)['late'] == true ? 'scheduled · sent late · ' : 'scheduled · ', style: Theme.of(c).textTheme.labelSmall),
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
