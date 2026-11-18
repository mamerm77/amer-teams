import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/api_service.dart';
import '../services/call_controller.dart';
import '../services/call_manager.dart';
import '../services/call_service.dart';
import '../services/call_signaling.dart';
import '../services/matrix_service.dart';
import '../services/meeting_service.dart';
import 'whiteboard_screen.dart';

/// Encrypted call or meeting: video grid, participants, in-meeting chat, raise hand, reactions,
/// screen share, camera switch, on-device captions, waiting room for the host, Amer minutes.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.roomId, this.callId, this.video = true, this.meeting = false, this.controller});
  final String roomId; final String? callId; final bool video, meeting;
  /// 1:1 calls (protocol v2): the signalling controller. Null for meetings.
  final CallController? controller;
  @override State<CallScreen> createState() => _S();
}

enum _Panel { none, people, chat }

class _S extends State<CallScreen> {
  SecureCall? call; String? err;
  CallController? ctl; bool _closing = false; CallManager? cm;
  bool mic = true, cam = true, sharing = false, captions = false, amerNotes = false, myHand = false, grid = true, front = true;
  _Panel panel = _Panel.none;
  final hands = <String>{}; final floating = <(String, String, DateTime)>[];
  final stt = SpeechToText(); final transcript = StringBuffer(); String liveCaption = '';
  Timer? tick; EventsListener<RoomEvent>? ev;
  final chatInput = TextEditingController();
  Future<mx.Timeline>? _chatTl;   // loaded once, updates itself
  StreamSubscription? _roomEvents;
  String get me => room.client.userID!;
  bool get isHost => room.getPowerLevelByUserId(me).level >= 50;
  bool get attendee => call?.role == 'attendee';
  String get callId => widget.meeting ? 'meet-${widget.roomId}' : (call?.callId ?? '');
  Map<String, Object?> get meetingSettings => Map<String, Object?>.from(room.getState('com.amerteams.meeting.settings')?.content ?? {});
  bool get webinar => meetingSettings['mode'] == 'webinar';
  bool get locked => room.joinRules == mx.JoinRules.invite;
  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  // ---------- host controls ----------
  Future<void> _host(String action, {String? identity}) async {
    try {
      final r = await context.read<ApiService>().meetingControl(widget.roomId, callId, action, identity: identity);
      _snack({'mute': 'Muted', 'mute_all': 'Muted ${r['affected']} participant(s)', 'stop_video': 'Video stopped', 'remove': 'Removed', 'end': 'Meeting ended for everyone'}[action] ?? 'Done');
      if (action == 'end' && mounted) await _leave();
    } catch (e) { _snack('$e'.replaceFirst('Exception: ', '')); }
  }
  Future<void> _setWebinar(bool on) async {
    final st = meetingSettings..['mode'] = on ? 'webinar' : 'meeting';
    await room.client.setRoomStateWithKey(room.id, 'com.amerteams.meeting.settings', '', st);
    _snack(on ? 'Webinar mode on: new attendees can watch, chat and raise hands' : 'Webinar mode off'); setState(() {});
  }
  Future<void> _makePresenter(String userId) async {
    final st = meetingSettings; final pres = ((st['presenters'] as List?) ?? []).cast<String>().toSet()..add(userId);
    st['presenters'] = pres.toList();
    await room.client.setRoomStateWithKey(room.id, 'com.amerteams.meeting.settings', '', st);
    _snack('They can rejoin to speak and share video');
  }
  Future<void> _toggleLock() async {
    await room.setJoinRules(locked ? mx.JoinRules.knock : mx.JoinRules.invite);
    _snack(locked ? 'Meeting unlocked' : 'Meeting locked: nobody new can ask to join'); setState(() {});
  }
  void _shareLink() {
    final mid = meetings.meetingIdOf(room);
    final text = 'Join my Amer Teams meeting "${room.getLocalizedDisplayname()}"\n'
        '${mid != null ? 'Meeting ID: ${MeetingService.format(mid)}\nOpen Amer Teams → Calls → Join with ID' : 'Open the chat in Amer Teams and tap Join'}';
    Clipboard.setData(ClipboardData(text: text)); _snack('Invitation copied — paste it into an email or message');
  }

  // ---------- breakout rooms ----------
  Future<void> _breakouts() async {
    final members = room.getParticipants().where((u) => u.id != me).toList();
    if (members.length < 2) { _snack('Breakout rooms need at least two other people in the meeting'); return; }
    var n = 2;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Breakout rooms'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${members.length} participants will be split evenly.'),
        Row(children: [const Text('Rooms'), Expanded(child: Slider(min: 2, max: members.length.clamp(2, 10).toDouble(), divisions: (members.length.clamp(2, 10) - 2).clamp(1, 8), value: n.toDouble(), label: '$n', onChanged: (v) => set(() => n = v.round()))), Text('$n')]),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Open rooms'))])));
    if (ok != true) return;
    final groups = List.generate(n, (_) => <String>[]);
    for (var i = 0; i < members.length; i++) { groups[i % n].add(members[i].id); }
    final rooms = <Map<String, Object?>>[];
    for (var i = 0; i < n; i++) {
      final (rid, _) = await meetings.create('${room.getLocalizedDisplayname()} · Room ${i + 1}', invite: groups[i]);
      rooms.add({'room_id': rid, 'title': 'Room ${i + 1}', 'members': groups[i]});
    }
    await room.sendEvent({'rooms': rooms, 'body': '🚪 Breakout rooms are open'}, type: 'com.amerteams.breakout');
    _snack('Breakout rooms opened');
  }
  void _onRoomEvent(mx.Event e) async {
    if (e.roomId != widget.roomId || e.type != 'com.amerteams.breakout' || e.senderId == me) return;
    final mine = ((e.content['rooms'] as List?) ?? []).cast<Map>().where((r) => (r['members'] as List).contains(me)).firstOrNull;
    if (mine == null || !mounted) return;
    final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Breakout room'),
      content: Text('The host has moved you to ${mine['title']}.'),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Stay')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Join'))]));
    if (go != true || !mounted) return;
    final child = room.client.getRoomById(mine['room_id'] as String);
    if (child != null && child.membership == mx.Membership.invite) await child.join();
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(roomId: mine['room_id'] as String, meeting: true, video: cam)));
    _snack('Back in the main meeting');
  }
  mx.Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  MeetingService get meetings => MeetingService(context.read<MatrixService>());

  @override void initState() { super.initState(); cam = widget.video; _start(); tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); }); }

  Future<void> _start() async {
    final api = context.read<ApiService>(); cm = context.read<CallManager>();
    if (!widget.meeting && widget.callId == null) {          // 1:1 call: ring first, media only after answer
      try {
        ctl = widget.controller ?? await cm!.startCall(room, video: widget.video);
        ctl!.addListener(_onCtl); _onCtl();
      } catch (e) { setState(() => err = '$e'.replaceFirst('Bad state: ', '')); }
      return;
    }
    if (widget.meeting) cm!.inCall = true;
    try {
      final id = widget.meeting ? 'meet-${widget.roomId}' : widget.callId;   // same on every device
      call = widget.meeting ? await SecureCall.joinOrStart(api, room, id!, video: widget.video)
          : widget.callId == null ? await SecureCall.start(api, room, video: widget.video)
          : await SecureCall.join(api, room, widget.callId!, video: widget.video);
      call!.lk.addListener(_refresh);
      ev = call!.lk.createListener()..on<DataReceivedEvent>(_onData);
      _roomEvents = room.client.onTimelineEvent.stream.listen(_onRoomEvent);
      cam = cam && call!.deviceWarnings.every((w) => !w.contains('camera'));
      mic = call!.deviceWarnings.every((w) => !w.contains('microphone'));
      for (final w in call!.deviceWarnings) { _snack(w); }
      setState(() {});
    } catch (e) { setState(() => err = '$e'.replaceFirst('Bad state: ', '')); }
  }
  void _refresh() { if (mounted) setState(() {}); }

  void _onCtl() {
    final c = ctl!;
    if (call == null && c.state == CallState.connected && c.media != null) {
      call = c.media; call!.lk.addListener(_refresh);
      ev = call!.lk.createListener()..on<DataReceivedEvent>(_onData);
      _roomEvents = room.client.onTimelineEvent.stream.listen(_onRoomEvent);
      cam = cam && call!.deviceWarnings.every((w) => !w.contains('camera'));
      mic = call!.deviceWarnings.every((w) => !w.contains('microphone'));
      for (final w in call!.deviceWarnings) { WidgetsBinding.instance.addPostFrameCallback((_) { if (mounted) _snack(w); }); }
    }
    if (c.ended && !_closing) {
      _closing = true; call = null;
      Future.delayed(Duration(milliseconds: c.sig.outcome == CallOutcome.completed || c.sig.outcome == CallOutcome.remoteHangup ? 1200 : 2500),
          () { if (mounted) Navigator.of(context).maybePop(); });
    }
    _refresh();
  }

  /// Before media connects (Calling… / Ringing… / Connecting…) and after the call ends (outcome).
  Widget _status(BuildContext c) {
    final k = ctl!; final cs = Theme.of(c).colorScheme;
    final endedBad = k.ended && !{CallOutcome.completed, CallOutcome.remoteHangup}.contains(k.sig.outcome);
    return Scaffold(backgroundColor: cs.surfaceContainerHighest, body: SafeArea(child: Column(children: [
      const Spacer(),
      CircleAvatar(radius: 56, child: Text(_initials(k.peerName ?? room.getLocalizedDisplayname()), style: const TextStyle(fontSize: 36))),
      const SizedBox(height: 20),
      Text(k.peerName ?? room.getLocalizedDisplayname(), style: Theme.of(c).textTheme.headlineSmall),
      const SizedBox(height: 8),
      Text(k.label, style: Theme.of(c).textTheme.titleMedium?.copyWith(color: endedBad ? cs.error : null)),
      const SizedBox(height: 6),
      Row(mainAxisAlignment: MainAxisAlignment.center, children: [const Icon(Icons.lock, size: 14, color: Colors.green), const SizedBox(width: 4),
        Text('${k.video ? 'Video' : 'Voice'} call · end-to-end encrypted', style: Theme.of(c).textTheme.labelSmall)]),
      const Spacer(),
      if (!k.ended) Padding(padding: const EdgeInsets.only(bottom: 40), child: FloatingActionButton.large(heroTag: 'end', backgroundColor: Colors.red,
        onPressed: () => k.hangup(), child: const Icon(Icons.call_end, color: Colors.white))),
      if (k.ended) const SizedBox(height: 136),
    ])));
  }

  // ---------- raise hand and reactions (small data messages between participants) ----------
  void _onData(DataReceivedEvent e) {
    try {
      final j = jsonDecode(utf8.decode(e.data)); final who = e.participant?.name ?? 'Someone';
      setState(() {
        if (j['t'] == 'hand') { j['up'] == true ? hands.add(who) : hands.remove(who); }
        if (j['t'] == 'react') floating.add((who, j['e'] as String, DateTime.now()));
      });
    } catch (_) {}
  }
  Future<void> _send(Map<String, dynamic> m) => call!.lk.localParticipant!.publishData(utf8.encode(jsonEncode(m)), reliable: true, topic: 'meeting');
  Future<void> _toggleHand() async { myHand = !myHand; await _send({'t': 'hand', 'up': myHand}); setState(() {}); }
  Future<void> _react(String e) async { await _send({'t': 'react', 'e': e}); setState(() => floating.add(('You', e, DateTime.now()))); }

  Future<void> _toggleCaptions() async {
    if (!captions && await stt.initialize()) {
      stt.listen(onResult: (r) { setState(() => liveCaption = r.recognizedWords); if (r.finalResult) transcript.writeln('Me: ${r.recognizedWords}'); },
                 listenOptions: SpeechListenOptions(partialResults: true, onDevice: true));
      setState(() => captions = true);
    } else { await stt.stop(); setState(() => captions = false); }
  }

  Future<void> _switchCamera() async {
    final t = call!.lk.localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (t is LocalVideoTrack) { front = !front; await t.setCameraPosition(front ? CameraPosition.front : CameraPosition.back); }
  }

  Future<void> _leave() async {
    if (ctl != null) {                         // 1:1: signalling sends hangup + end and tears media down
      await stt.stop(); await ev?.dispose(); ev = null; await ctl!.hangup(); return;
    }
    cm?.inCall = false;
    tick?.cancel(); await stt.stop(); await ev?.dispose(); await call?.leave();
    if (amerNotes && transcript.isNotEmpty && mounted) {
      final r = await context.read<ApiService>().ask('Write minutes', context: transcript.toString(), agent: 'minutes');
      await room.sendTextEvent('📝 Minutes by Amer\n\n${r['answer']}');
    }
    if (mounted) Navigator.pop(context);
  }
  @override void dispose() { ctl?.removeListener(_onCtl); if (ctl != null && !ctl!.ended) ctl!.hangup(); if (widget.meeting) cm?.inCall = false; tick?.cancel(); ev?.dispose(); _roomEvents?.cancel(); _chatTl?.then((t) => t.cancelSubscriptions()); super.dispose(); }

  // ---------- UI ----------
  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    if (err != null) return Scaffold(appBar: AppBar(), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('Could not join: $err', textAlign: TextAlign.center), const SizedBox(height: 16),
      FilledButton(onPressed: () => Navigator.of(c).maybePop(), child: const Text('Back'))]))));
    if (ctl != null && (call == null || ctl!.ended)) return _status(c);
    if (call == null) return Scaffold(body: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [const CircularProgressIndicator(), const SizedBox(height: 16), Text(widget.meeting ? 'Joining meeting…' : 'Connecting securely…')])));
    final lk = call!.lk;
    final people = <Participant>[if (lk.localParticipant != null) lk.localParticipant!, ...lk.remoteParticipants.values];
    final waiting = widget.meeting ? meetings.waiting(room) : <mx.User>[];
    final mid = meetings.meetingIdOf(room);
    floating.removeWhere((f) => DateTime.now().difference(f.$3).inSeconds > 4);
    final t = ctl?.sig.duration ?? call!.elapsed; final timer = '${t.inMinutes.toString().padLeft(2, '0')}:${(t.inSeconds % 60).toString().padLeft(2, '0')}';
    final wide = MediaQuery.sizeOf(c).width > 900;

    final stage = Stack(children: [
      _videos(people, wide),
      Positioned(right: 12, bottom: 12, child: Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
        for (final f in floating) Container(margin: const EdgeInsets.only(top: 4), padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          decoration: BoxDecoration(color: cs.surface.withValues(alpha: .9), borderRadius: BorderRadius.circular(20)), child: Text('${f.$2}  ${f.$1}', style: const TextStyle(fontSize: 18))),
      ])),
      if (hands.isNotEmpty) Positioned(left: 12, top: 12, child: Chip(avatar: const Text('✋'), label: Text(hands.join(', ')))),
      if (waiting.isNotEmpty) Positioned(left: 12, right: 12, top: 56, child: Card(color: cs.tertiaryContainer, child: Column(children: [
        for (final u in waiting) ListTile(leading: const Icon(Icons.hourglass_top), title: Text('${u.calcDisplayname()} is in the waiting room'),
          trailing: Wrap(spacing: 6, children: [
            TextButton(onPressed: () async { await meetings.decline(room, u.id); setState(() {}); }, child: const Text('Decline')),
            FilledButton(onPressed: () async { await meetings.admit(room, u.id); setState(() {}); }, child: const Text('Admit'))])),
      ]))),
    ]);

    return Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(room.getLocalizedDisplayname(), overflow: TextOverflow.ellipsis),
          Row(children: [
            Icon(Icons.lock, size: 14, color: call!.encrypted ? Colors.green : cs.error), const SizedBox(width: 4),
            Flexible(child: Text('${call!.encrypted ? 'Encrypted · quantum-safe' : 'NOT ENCRYPTED'} · $timer · code ${call!.safetyCode}',
                style: Theme.of(c).textTheme.labelSmall, overflow: TextOverflow.ellipsis)),
          ]),
        ]),
        actions: [
          if (mid != null) TextButton.icon(icon: const Icon(Icons.copy, size: 16), label: Text(MeetingService.format(mid)),
            onPressed: () { Clipboard.setData(ClipboardData(text: MeetingService.format(mid))); ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Meeting ID copied'))); }),
          IconButton(tooltip: grid ? 'Speaker view' : 'Grid view', icon: Icon(grid ? Icons.person : Icons.grid_view), onPressed: () => setState(() => grid = !grid)),
          IconButton(tooltip: 'Participants', icon: Badge(isLabelVisible: waiting.isNotEmpty, label: Text('${waiting.length}'), child: const Icon(Icons.people)),
              onPressed: () => setState(() => panel = panel == _Panel.people ? _Panel.none : _Panel.people)),
          IconButton(tooltip: 'Chat', icon: const Icon(Icons.chat), onPressed: () => setState(() => panel = panel == _Panel.chat ? _Panel.none : _Panel.chat)),
          PopupMenuButton<String>(tooltip: 'More', onSelected: (v) {
            switch (v) {
              case 'wb': Navigator.push(c, MaterialPageRoute(builder: (_) => WhiteboardScreen(roomId: widget.roomId)));
              case 'share': _shareLink();
              case 'breakout': _breakouts();
              case 'muteall': _host('mute_all');
              case 'lock': _toggleLock();
              case 'webinar': _setWebinar(!webinar);
              case 'end': _host('end');
            }
          }, itemBuilder: (_) => [
            const PopupMenuItem(value: 'wb', child: ListTile(leading: Icon(Icons.draw), title: Text('Whiteboard'))),
            const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share), title: Text('Copy invitation'))),
            if (isHost && widget.meeting) const PopupMenuItem(value: 'breakout', child: ListTile(leading: Icon(Icons.call_split), title: Text('Breakout rooms'))),
            if (isHost) const PopupMenuItem(value: 'muteall', child: ListTile(leading: Icon(Icons.mic_off), title: Text('Mute everyone'))),
            if (isHost && widget.meeting) PopupMenuItem(value: 'lock', child: ListTile(leading: Icon(locked ? Icons.lock_open : Icons.lock), title: Text(locked ? 'Unlock meeting' : 'Lock meeting'))),
            if (isHost && widget.meeting) PopupMenuItem(value: 'webinar', child: ListTile(leading: const Icon(Icons.campaign), title: Text(webinar ? 'Turn off webinar mode' : 'Webinar mode'))),
            if (isHost) const PopupMenuItem(value: 'end', child: ListTile(leading: Icon(Icons.stop_circle, color: Colors.red), title: Text('End for everyone'))),
          ]),
        ]),
      body: Column(children: [
        if (attendee) MaterialBanner(content: const Text('You are an attendee in this webinar. Raise your hand to ask to speak.'), actions: [TextButton(onPressed: _toggleHand, child: Text(myHand ? 'Lower hand' : 'Raise hand'))]),
        if (amerNotes) MaterialBanner(content: const Text('Amer is taking notes. The on-device transcript goes to the AI engine when you leave.'), actions: [TextButton(onPressed: () => setState(() => amerNotes = false), child: const Text('Stop'))]),
        Expanded(child: wide || panel == _Panel.none
            ? Row(children: [Expanded(child: stage), if (panel != _Panel.none) SizedBox(width: 340, child: _panel(people, waiting))])
            : _panel(people, waiting)),
        if (captions) Container(width: double.infinity, padding: const EdgeInsets.all(12), color: cs.surfaceContainerHighest, child: Text(liveCaption.isEmpty ? 'Listening on this device…' : liveCaption)),
        SafeArea(top: false, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 8, children: [
          if (!attendee) _btn(mic ? Icons.mic : Icons.mic_off, mic ? 'Mute' : 'Unmute', () { mic = !mic; lk.localParticipant?.setMicrophoneEnabled(mic); setState(() {}); }, off: !mic),
          if (!attendee) _btn(cam ? Icons.videocam : Icons.videocam_off, cam ? 'Stop video' : 'Start video', () { cam = !cam; lk.localParticipant?.setCameraEnabled(cam); setState(() {}); }, off: !cam),
          if (cam && !attendee) _btn(Icons.cameraswitch, 'Switch camera', _switchCamera),
          if (!attendee) _btn(Icons.screen_share, sharing ? 'Stop sharing' : 'Share screen', () { sharing = !sharing; lk.localParticipant?.setScreenShareEnabled(sharing); setState(() {}); }, off: sharing),
          _btn(Icons.back_hand, myHand ? 'Lower hand' : 'Raise hand', _toggleHand, off: myHand),
          PopupMenuButton<String>(tooltip: 'React', onSelected: _react, icon: const CircleAvatar(child: Text('😀')),
            itemBuilder: (_) => [for (final e in ['👍', '👏', '❤️', '😂', '😮', '🎉']) PopupMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 22)))]),
          _btn(captions ? Icons.closed_caption : Icons.closed_caption_off, 'Captions', _toggleCaptions, off: captions),
          _btn(Icons.auto_awesome, 'Amer minutes', () => setState(() => amerNotes = !amerNotes), off: amerNotes),
          FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size(110, 48)), onPressed: _leave, icon: const Icon(Icons.call_end), label: const Text('Leave')),
        ]))),
      ]),
    );
  }

  Widget _btn(IconData i, String tip, VoidCallback f, {bool off = false}) => IconButton.filledTonal(tooltip: tip, onPressed: f,
      style: off ? IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.secondaryContainer) : null, icon: Icon(i));

  Widget _tile(Participant p) {
    final vt = p.videoTrackPublications.where((x) => !x.muted).map((x) => x.track).whereType<VideoTrack>().firstOrNull;
    final cs = Theme.of(context).colorScheme;
    return AnimatedContainer(duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.isSpeaking ? cs.primary : Colors.transparent, width: 3)),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        if (vt != null) VideoTrackRenderer(vt) else Center(child: CircleAvatar(radius: 36, child: Text(_initials(p.name.isEmpty ? p.identity : p.name), style: const TextStyle(fontSize: 22)))),
        Positioned(left: 8, bottom: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: cs.surface.withValues(alpha: .85), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (p.isMuted) const Icon(Icons.mic_off, size: 14), const SizedBox(width: 4),
            Text(p is LocalParticipant ? 'You' : (p.name.isEmpty ? p.identity : p.name)),
          ]))),
      ]));
  }
  static String _initials(String n) => n.replaceAll('@', '').split(RegExp(r'[\s:._]')).where((s) => s.isNotEmpty).take(2).map((s) => s[0].toUpperCase()).join();

  Widget _videos(List<Participant> people, bool wide) {
    if (!grid && people.length > 1) {
      final main = people.firstWhere((p) => p is! LocalParticipant && p.isSpeaking, orElse: () => people.firstWhere((p) => p is! LocalParticipant, orElse: () => people.first));
      return Column(children: [
        Expanded(child: Padding(padding: const EdgeInsets.all(8), child: _tile(main))),
        SizedBox(height: 110, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 8),
          children: [for (final p in people.where((p) => p != main)) Padding(padding: const EdgeInsets.only(right: 8), child: SizedBox(width: 150, child: _tile(p)))])),
      ]);
    }
    final n = people.length; final cols = n <= 1 ? 1 : n <= 4 ? 2 : wide ? 4 : 3;
    return GridView.count(crossAxisCount: cols, padding: const EdgeInsets.all(8), mainAxisSpacing: 8, crossAxisSpacing: 8, childAspectRatio: 16 / 11,
        children: [for (final p in people) _tile(p)]);
  }

  Widget _panel(List<Participant> people, List<mx.User> waiting) {
    final head = Row(children: [
      Expanded(child: Text(panel == _Panel.people ? 'Participants (${people.length})' : 'Meeting chat', style: Theme.of(context).textTheme.titleMedium)),
      IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => panel = _Panel.none))]);
    if (panel == _Panel.people) {
      return Material(child: ListView(padding: const EdgeInsets.all(12), children: [head,
        if (waiting.isNotEmpty) ...[const Text('Waiting room'), for (final u in waiting) ListTile(title: Text(u.calcDisplayname()),
          trailing: FilledButton(onPressed: () async { await meetings.admit(room, u.id); setState(() {}); }, child: const Text('Admit')))],
        for (final p in people) ListTile(leading: CircleAvatar(child: Text(_initials(p.name.isEmpty ? p.identity : p.name))),
          title: Text(p is LocalParticipant ? 'You' : (p.name.isEmpty ? p.identity : p.name)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (hands.contains(p.name)) const Text('✋ '),
            Icon(p.isMuted ? Icons.mic_off : Icons.mic, size: 18), const SizedBox(width: 6),
            Icon(p.isCameraEnabled() ? Icons.videocam : Icons.videocam_off, size: 18),
            if (isHost && p is! LocalParticipant) PopupMenuButton<String>(onSelected: (a) => a == 'presenter' ? _makePresenter(p.identity) : _host(a, identity: p.identity),
              itemBuilder: (_) => [
                const PopupMenuItem(value: 'mute', child: Text('Mute')),
                const PopupMenuItem(value: 'stop_video', child: Text('Stop video')),
                if (webinar) const PopupMenuItem(value: 'presenter', child: Text('Make presenter')),
                const PopupMenuItem(value: 'remove', child: Text('Remove from meeting'))]),
          ])),
        const Divider(),
        ListTile(leading: const Icon(Icons.person_add), title: const Text('Invite people'), onTap: _shareLink, subtitle: Text(meetings.meetingIdOf(room) != null ? 'Share meeting ID ${MeetingService.format(meetings.meetingIdOf(room)!)}' : 'Add people to this chat')),
      ]));
    }
    return Material(child: Column(children: [Padding(padding: const EdgeInsets.fromLTRB(12, 12, 12, 0), child: head),
      Expanded(child: FutureBuilder<mx.Timeline>(future: _chatTl ??= room.getTimeline(onUpdate: _refresh), builder: (_, s) {
        if (!s.hasData) return const Center(child: CircularProgressIndicator());
        final msgs = s.data!.events.where((e) => e.type == mx.EventTypes.Message).take(50).toList();
        return ListView.builder(reverse: true, padding: const EdgeInsets.all(12), itemCount: msgs.length, itemBuilder: (_, i) {
          final e = msgs[i];
          return Padding(padding: const EdgeInsets.only(bottom: 8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(e.senderFromMemoryOrFallback.calcDisplayname(), style: Theme.of(context).textTheme.labelSmall), Text(e.body)]));
        });
      })),
      SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        Expanded(child: TextField(controller: chatInput, decoration: const InputDecoration(hintText: 'Message everyone (encrypted)', border: OutlineInputBorder(), isDense: true),
          onSubmitted: (_) => _sendChat())),
        IconButton(icon: const Icon(Icons.send), onPressed: _sendChat)]))),
    ]));
  }
  Future<void> _sendChat() async { final t = chatInput.text.trim(); if (t.isEmpty) return; chatInput.clear(); await room.sendTextEvent(t); }
}
