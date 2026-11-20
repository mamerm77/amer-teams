import '../services/availability.dart';
import 'package:flutter_tts/flutter_tts.dart';
import 'meeting_options_screen.dart';
import '../services/locale.dart';
import '../services/labels.dart';
import 'dart:math' show min, Random;
import '../services/accessibility.dart';
import 'package:flutter/semantics.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../services/decisions_tasks.dart';
import '../services/ai_gate.dart';
import 'package:flutter/services.dart';
import 'package:livekit_client/livekit_client.dart';
import 'package:amer_background/amer_background.dart';
import '../services/recording.dart';
import '../services/guest_keys.dart';
import '../services/handoff.dart';
import 'package:matrix/matrix.dart' as mx;
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/api_service.dart';
import '../services/call_controller.dart';
import '../services/call_manager.dart';
import '../services/call_service.dart';
import '../services/call_signaling.dart';
import 'prejoin_screen.dart';
import '../services/matrix_service.dart';
import '../services/meeting_service.dart';
import 'whiteboard_screen.dart';
import 'phone_screen.dart';

/// Encrypted call or meeting: video grid, participants, in-meeting chat, raise hand, reactions,
/// screen share, camera switch, on-device captions, waiting room for the host, Amer minutes.
class CallScreen extends StatefulWidget {
  const CallScreen({super.key, required this.roomId, this.callId, this.video = true, this.meeting = false, this.controller, this.ambient = false});
  final String roomId; final String? callId; final bool video, meeting;
  /// The team's always-open drop-in room (docs/AMBIENT.md): joins with microphone and camera off.
  final bool ambient;
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
  /// The meeting's transcript, held only in memory on this device: own final captions plus lines other
  /// participants shared over the encrypted data channel. Gone when the meeting screen closes.
  final lines = <Map<String, Object?>>[];
  static const _aiState = 'com.amerteams.meeting.ai';
  // ---------- agenda with a timer and a parking lot (docs/MEETING_AGENDA.md) ----------
  static const _agState = 'com.amerteams.meeting.agenda', _parkType = 'com.amerteams.meeting.parking';
  static const agendaTemplates = {
    'Weekly sync': [('Updates', 10), ('Blockers', 10), ('Next steps', 5)],
    'Vendor review': [('Commercials', 15), ('Technical fit', 20), ('Risks', 10), ('Decision', 5)],
    'Incident review': [('Timeline', 10), ('Root cause', 15), ('Actions and owners', 10)],
    'Retrospective': [('What went well', 10), ('What to improve', 10), ('Actions', 10)]};
  Map<String, Object?>? get agenda { final a = room.getState(_agState)?.content; return a != null && a['call_id'] == callId && a['items'] is List ? Map<String, Object?>.from(a) : null; }
  final _parkedLocal = <String>[];
  static const _spotType = 'com.amerteams.meeting.spotlight';
  String? pinnedId;                                                       // "Pin for me": only on this device
  /// "Spotlight for everyone" (host): the latest spotlight event of this call, or null when cleared.
  String? get spotlightId { final e = (_parkTl?.events ?? const <mx.Event>[]).where((e) => e.type == _spotType && e.content['call_id'] == callId).firstOrNull; final id = e?.content['identity']; return id is String && id.isNotEmpty ? id : null; }
  Future<void> _spotlight(String? identity) async { await room.sendEvent({'call_id': callId, 'identity': identity ?? '', 'body': identity == null ? 'Spotlight ended' : 'Spotlight on ${_nameOf(identity)}'}, type: _spotType); if (mounted) setState(() {}); }
  String _nameOf(String identity) { final p = _everyone.where((p) => p.identity == identity).firstOrNull; return p == null ? identity : (p.name.isEmpty ? p.identity : p.name); }
  List<Participant> get _everyone { final lk = call?.lk; if (lk == null) return const []; return [if (lk.localParticipant != null) lk.localParticipant!, ...lk.remoteParticipants.values]; }
  void _tileMenu(Participant p) => showModalBottomSheet(context: context, builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
    ListTile(title: Text(p is LocalParticipant ? 'You' : _nameOf(p.identity), style: Theme.of(context).textTheme.titleMedium)),
    ListTile(leading: Icon(pinnedId == p.identity ? Icons.push_pin : Icons.push_pin_outlined), title: Text(pinnedId == p.identity ? 'Unpin' : 'Pin for me'),
      onTap: () { Navigator.pop(s); setState(() => pinnedId = pinnedId == p.identity ? null : p.identity); }),
    if (isHost) ListTile(leading: const Icon(Icons.highlight), title: Text(spotlightId == p.identity ? 'Stop spotlighting' : 'Spotlight for everyone'),
      onTap: () { Navigator.pop(s); _spotlight(spotlightId == p.identity ? null : p.identity); }),
  ])));
  List<String> get parking { final fromTl = [for (final e in (_parkTl?.events ?? const <mx.Event>[]).where((e) => e.type == _parkType && e.content['call_id'] == callId).toList().reversed) '${e.content['text']}']; return [...fromTl, for (final t in _parkedLocal) if (!fromTl.contains(t)) t]; }
  mx.Timeline? _parkTl;
  Future<void> _setAgenda(List<(String, int)> items) => room.client.setRoomStateWithKey(room.id, _agState, '', {'call_id': callId,
      'items': [for (final (t, m) in items) {'t': t, 'min': m}], 'idx': 0, 'item_started_ms': DateTime.now().millisecondsSinceEpoch});
  Future<void> _moveAgenda(int d) async {
    final a = agenda; if (a == null) return;
    final n = (a['items'] as List).length, idx = ((a['idx'] as num).toInt() + d);
    if (idx >= n) { await room.client.setRoomStateWithKey(room.id, _agState, '', {...a, 'idx': n, 'done': true}); return; }
    await room.client.setRoomStateWithKey(room.id, _agState, '', {...a, 'idx': idx.clamp(0, n - 1), 'item_started_ms': DateTime.now().millisecondsSinceEpoch});
  }
  Future<void> _agendaDialog() async {
    final custom = TextEditingController();
    final pick = await showDialog<List<(String, int)>>(context: context, builder: (d) => SimpleDialog(title: const Text('Meeting agenda'), children: [
      for (final e in agendaTemplates.entries) SimpleDialogOption(onPressed: () => Navigator.pop(d, e.value),
        child: ListTile(title: Text(e.key), subtitle: Text(e.value.map((x) => '${x.$1} ${x.$2}′').join(' · ')))),
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: TextField(controller: custom, maxLines: 4, decoration: const InputDecoration(labelText: 'Or your own: one item per line, "Title, minutes"'))),
      Align(alignment: Alignment.centerRight, child: TextButton(onPressed: () {
        final items = [for (final l in custom.text.split('\n').where((l) => l.trim().isNotEmpty)) () {
          final i = l.lastIndexOf(','); final m = i > 0 ? int.tryParse(l.substring(i + 1).trim()) : null;
          return (m != null ? l.substring(0, i).trim() : l.trim(), m ?? 10); }()];
        Navigator.pop(d, items.isEmpty ? null : items); }, child: Text(L.t(context, 'Use my agenda')))),
    ]));
    if (pick != null) { await _setAgenda(pick); _snack('Agenda set: everyone sees the current item and time left'); }
  }
  Widget? _agendaBar(BuildContext c) {
    final a = agenda; if (a == null) return null;
    final items = (a['items'] as List).cast<Map>(); final idx = (a['idx'] as num).toInt();
    if (a['done'] == true || idx >= items.length) return MaterialBanner(leading: const Icon(Icons.flag), content: Text('Agenda complete${parking.isNotEmpty ? ' · ${parking.length} in the parking lot' : ''}'),
      actions: [if (isHost) TextButton(onPressed: () => _moveAgenda(-1), child: Text(L.t(context, 'Back'))), TextButton(onPressed: _showParking, child: Text(L.t(context, 'Parking lot')))]);
    final it = items[idx]; final total = Duration(minutes: (it['min'] as num).toInt());
    final used = DateTime.now().difference(DateTime.fromMillisecondsSinceEpoch((a['item_started_ms'] as num).toInt()));
    final left = total - used, frac = used.inSeconds / total.inSeconds.clamp(1, 1 << 30);
    final col = frac >= 1 ? Colors.red : frac >= .8 ? Colors.orange : Colors.green;
    String mmss(Duration d) => '${d.isNegative ? '+' : ''}${d.inMinutes.abs()}:${(d.inSeconds.abs() % 60).toString().padLeft(2, '0')}';
    return MaterialBanner(leading: Icon(Icons.timer_outlined, color: col),
      content: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
        Text('Item ${idx + 1} of ${items.length}: ${it['t']} · ${frac >= 1 ? 'over by ${mmss(left)}' : '${mmss(left)} left'}', style: TextStyle(fontWeight: FontWeight.w600, color: frac >= .8 ? col : null)),
        const SizedBox(height: 4), LinearProgressIndicator(value: frac.clamp(0, 1).toDouble(), color: col),
        if (idx + 1 < items.length) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Next: ${items[idx + 1]['t']}', style: const TextStyle(fontSize: 12))),
      ]),
      actions: [TextButton(onPressed: _showParking, child: Text('Parking lot (${parking.length})')), if (isHost) TextButton(onPressed: () => _moveAgenda(1), child: Text(idx + 1 < items.length ? 'Next item' : 'Finish'))]);
  }
  Future<void> _park(String text) async {
    final t = text.trim(); if (t.isEmpty) return;
    setState(() => _parkedLocal.add(t));
    await room.sendEvent({'call_id': callId, 'text': t, 'body': '🅿️ Parking lot: $t'}, type: _parkType);
    _snack('Added to the parking lot');
  }
  Future<void> _showParking() => showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => SafeArea(child: Padding(padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(s).bottom), child: ListView(shrinkWrap: true, children: [
    const ListTile(title: Text('Parking lot'), subtitle: Text('Topics raised off the agenda, to come back to later. Add one here or with /park in the meeting chat.')),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Builder(builder: (_) { final t = TextEditingController();
      return Row(children: [Expanded(child: TextField(controller: t, decoration: const InputDecoration(hintText: 'New topic for the parking lot'), onSubmitted: (v) { _park(v); Navigator.pop(s); })),
        TextButton(onPressed: () { _park(t.text); Navigator.pop(s); }, child: const Text('Add topic'))]); })),
    for (final p in parking) ListTile(leading: const Icon(Icons.local_parking), title: Text(p)),
    if (parking.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Empty'))]))));
  bool get aiOn { final s = room.getState(_aiState)?.content; return s?['enabled'] == true && s?['call_id'] == callId; }
  bool asking = false;
  Timer? tick; EventsListener<RoomEvent>? ev;
  final chatInput = TextEditingController();
  Future<mx.Timeline>? _chatTl;   // loaded once, updates itself
  StreamSubscription? _roomEvents;
  String get me => room.client.userID!;
  bool get isHost => room.getPowerLevelByUserId(me).level >= 50;     // organiser or co-organiser (co-organisers get power 50)
  /// Teams roles: presenters can also mute, remove and admit people, and change roles; only organisers and
  /// co-organisers change meeting options, run breakout rooms and end the meeting for everyone.
  bool get isPresenterRole { final o = meetingOptionsOf(room); return o['mode'] != 'webinar' && (o['who_presents'] ?? 'everyone') == 'everyone' || isPresenter(room, me); }
  /// Meeting option "Hide attendee names": attendees see other attendees as "Attendee"; organisers and presenters see names.
  bool _hideName(Participant p) {
    if (p is LocalParticipant || canModerate || meetingOptionsOf(room)['hide_names'] != true) return false;
    final o = meetingOptionsOf(room);
    return !(room.getPowerLevelByUserId(p.identity).level >= 50 || ((o['presenters'] as List?) ?? const []).contains(p.identity) || ((o['co_organisers'] as List?) ?? const []).contains(p.identity));
  }
  bool get canModerate => isHost || isPresenterRole;
  bool get canRecord { final w = meetingOptionsOf(room)['who_records'] ?? 'organisers_presenters'; return w == 'nobody' ? false : (isHost || (w == 'organisers_presenters' && isPresenterRole)); }
  bool get attendee => call?.role == 'attendee';
  String get callId => widget.meeting ? _meetId : (call?.callId ?? '');
  String get _meetId => widget.ambient ? 'meet-ambient-${widget.roomId}' : 'meet-${widget.roomId}';
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
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Open rooms')))])));
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
    if (e.roomId == widget.roomId && (e.type == _aiState || e.type == _agState || e.type == _parkType || e.type == _spotType)) { if (mounted) setState(() {}); return; }
    if (e.roomId != widget.roomId || e.type != 'com.amerteams.breakout' || e.senderId == me) return;
    final mine = ((e.content['rooms'] as List?) ?? []).cast<Map>().where((r) => (r['members'] as List).contains(me)).firstOrNull;
    if (mine == null || !mounted) return;
    final go = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Breakout room'),
      content: Text('The organiser has moved you to ${mine['title']}.'),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Stay'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Join')))]));
    if (go != true || !mounted) return;
    final child = room.client.getRoomById(mine['room_id'] as String);
    if (child != null && child.membership == mx.Membership.invite) await child.join();
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(roomId: mine['room_id'] as String, meeting: true, video: cam)));
    _snack('Back in the main meeting');
  }
  // The SDK briefly drops rooms while it re-syncs (e.g. after blocking someone): keep the last known room, never crash.
  mx.Room? _room;
  mx.Room get room => _room = context.read<MatrixService>().client.getRoomById(widget.roomId) ?? _room ?? (throw StateError('This chat is no longer available'));
  MeetingService get meetings => MeetingService(context.read<MatrixService>());

  PreJoinChoice? _pre;
  @override void initState() {
    super.initState(); cam = widget.video && !widget.ambient;
    if (widget.meeting && !widget.ambient) {
      // meetings: pre-join first (preview, devices), as in Teams and Zoom
      WidgetsBinding.instance.addPostFrameCallback((_) async {
        final ch = await showPreJoin(context, title: 'Join ${room.getLocalizedDisplayname()}', video: widget.video);
        if (!mounted) return;
        if (ch == null) { Navigator.of(context).maybePop(); return; }
        _pre = ch; cam = ch.cam; _start();
      });
    } else { _start(); }
    tick = Timer.periodic(const Duration(seconds: 1), (_) { if (mounted) setState(() {}); }); }

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
      final id = widget.meeting ? _meetId : widget.callId;   // same on every device
      call = widget.meeting ? await SecureCall.joinOrStart(api, room, id!, video: _pre?.cam ?? widget.video)
          : widget.callId == null ? await SecureCall.start(api, room, video: widget.video)
          : await SecureCall.join(api, room, widget.callId!, video: widget.video); Availability.instance.activity(widget.meeting ? 'meeting' : 'call');
      if (widget.meeting && meetingOptionsOf(room)['record_auto'] == true && canRecord && DeviceRecorder.supported) { Future.delayed(const Duration(seconds: 4), () { if (mounted && !rec.recording && rec.id == null) _askRecord(); }); }
      call!.lk.addListener(_refresh);
      ev = call!.lk.createListener()..on<DataReceivedEvent>(_onData)..on<RoomDisconnectedEvent>(_onDisconnected)..on<ParticipantConnectionQualityUpdatedEvent>(_onQuality);
      _roomEvents = room.client.onTimelineEvent.stream.listen(_onRoomEvent);
      _parkTl = await room.getTimeline(onUpdate: _refresh);
      cam = cam && call!.deviceWarnings.every((w) => !w.contains('camera'));
      mic = call!.deviceWarnings.every((w) => !w.contains('microphone'));
      for (final w in call!.deviceWarnings) { _snack(w); }
      await _applyPreJoin();
      if (widget.ambient) { mic = false; cam = false; await call!.lk.localParticipant?.setMicrophoneEnabled(false); await call!.lk.localParticipant?.setCameraEnabled(false); }
      if (A11y.instance.captionsByDefault && !captions) unawaited(_toggleCaptions());
      if (ctl == null) unawaited(Handoff.announce(room.client, roomId: widget.roomId, callId: widget.meeting ? null : call!.callId, meeting: widget.meeting));
      setState(() {});
    } catch (e) { setState(() => err = '$e'.replaceFirst('Bad state: ', '')); }
  }

  /// Devices and microphone choice from the pre-join screen (best effort: a device may have gone away).
  Future<void> _applyPreJoin() async {
    final p = _pre, lk = call?.lk; if (p == null || lk == null) return;
    try {
      if (p.micId != null) await lk.setAudioInputDevice(MediaDevice(p.micId!, '', 'audioinput', null));
      if (p.camId != null && p.cam) await lk.setVideoInputDevice(MediaDevice(p.camId!, '', 'videoinput', null));
      if (p.speakerId != null) await lk.setAudioOutputDevice(MediaDevice(p.speakerId!, '', 'audiooutput', null));
    } catch (_) {}
    if (!p.mic) { mic = false; await lk.localParticipant?.setMicrophoneEnabled(false); }
  }

  /// In-meeting audio and video settings.
  Future<void> _deviceSettings() async {
    final lk = call?.lk; if (lk == null) return;
    final d = await Hardware.instance.enumerateDevices();
    if (!mounted) return;
    Widget sec(String t, IconData i, String kind, Future<void> Function(MediaDevice) set) => ExpansionTile(leading: Icon(i), title: Text(t), children: [
      for (final x in d.where((x) => x.kind == kind)) ListTile(dense: true, title: Text(x.label.isEmpty ? t : x.label), onTap: () async { Navigator.pop(context); try { await set(x); _snack('$t: ${x.label}'); } catch (e) { _snack('Could not switch: $e'); } })]);
    await showModalBottomSheet(context: context, builder: (s) => SafeArea(child: ListView(shrinkWrap: true, children: [
      const ListTile(title: Text('Audio and video settings')),
      sec('Microphone', Icons.mic_none, 'audioinput', lk.setAudioInputDevice),
      sec('Camera', Icons.videocam_outlined, 'videoinput', lk.setVideoInputDevice),
      sec('Speaker', Icons.volume_up_outlined, 'audiooutput', lk.setAudioOutputDevice),
    ])));
  }
  void _refresh() { _recTick(); _guestTick(); if (mounted) setState(() {}); }

  void _onCtl() {
    final c = ctl!;
    if (call == null && c.state == CallState.connected && c.media != null) {
      call = c.media; call!.lk.addListener(_refresh); Availability.instance.activity('call');
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
        if (j['t'] == 'hand') { j['up'] == true ? hands.add(who) : hands.remove(who); if (j['up'] == true) _say('$who raised their hand'); }
        if (j['t'] == 'gk-hello' && (e.participant?.identity ?? '').startsWith('guest-') && j['pk'] is String) lobby[e.participant!.identity] = (j['pk'] as String, who);
        if (j['t'] == 'qa') _onQa(j, who);
        if (j['t'] == 'rec') _onRec(j, e.participant?.identity ?? '', who);
        if (j['t'] == 'react' && !A11y.instance.reduceMotion) floating.add((who, j['e'] as String, DateTime.now()));
        if (j['t'] == 'cap' && aiOn && j['x'] is String) { lines.add({'speaker': who, 'text': j['x'], 'ts': j['ts'] is int ? j['ts'] : DateTime.now().millisecondsSinceEpoch}); _translateLine(who, j['x']); }
      });
    } catch (_) {}
  }
  Future<void> _send(Map<String, dynamic> m) => call!.lk.localParticipant!.publishData(utf8.encode(jsonEncode(m)), reliable: true, topic: 'meeting');
  Future<void> _toggleHand() async {
    setState(() => myHand = !myHand);                       // immediate feedback, like Teams
    try { await _send({'t': 'hand', 'up': myHand}); }
    catch (e) { setState(() => myHand = !myHand); _snack('Could not raise your hand: check your connection'); }
  }
  Future<void> _react(String e) async { await _send({'t': 'react', 'e': e}); setState(() => floating.add(('You', e, DateTime.now()))); }

  Future<void> _toggleCaptions() async {
    if (!captions && await stt.initialize()) {
      stt.listen(onResult: (r) {
        setState(() => liveCaption = r.recognizedWords);
        if (!r.finalResult || r.recognizedWords.trim().isEmpty) return;
        transcript.writeln('Me: ${r.recognizedWords}');
        final ts = DateTime.now().millisecondsSinceEpoch;
        lines.add({'speaker': room.client.userID == null ? 'Me' : (room.unsafeGetUserFromMemoryOrFallback(me).calcDisplayname()), 'text': r.recognizedWords, 'ts': ts});
        if (aiOn && call != null) _send({'t': 'cap', 'x': r.recognizedWords, 'ts': ts}).catchError((_) {});   // shared only while Amer is on
        _translateLine('Me', r.recognizedWords);
      },
                 listenOptions: SpeechListenOptions(partialResults: true, onDevice: true));
      setState(() => captions = true);
    } else { await stt.stop(); setState(() => captions = false); }
  }

  // ---------- Amer in the meeting (ask-the-meeting agent) ----------
  Future<void> _toggleAi() async {
    final on = !aiOn;
    if (on && meetingOptionsOf(room)['ai_allowed'] == false) { _snack('The organiser has turned off Amer for meetings in this chat (Meeting options)'); return; }
    try {
      await room.client.setRoomStateWithKey(room.id, _aiState, '', {'enabled': on, 'call_id': callId, 'by': me});
      _snack(on ? 'Amer is on for this meeting. Everyone sees that AI is listening.' : 'Amer is off for this meeting');
      setState(() {});
    } catch (e) { _snack('Could not change Amer: $e'); }
  }
  Future<void> _askDialog([String? preset]) async {
    if (!aiOn) { _snack(isHost ? 'Switch Amer on for this meeting first (More → Amer in this meeting)' : 'The organiser has not switched Amer on for this meeting'); return; }
    final gate = aiFor(room); if (!gate.allowed) { _snack(gate.where); return; }
    final q = TextEditingController(text: preset);
    final question = preset ?? await showDialog<String>(context: context, builder: (d) => AlertDialog(
      title: const Text('Ask Amer about this meeting'),
      content: TextField(controller: q, autofocus: true, decoration: const InputDecoration(hintText: 'e.g. What did we decide about the budget?'), onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, q.text), child: Text(L.t(context, 'Ask')))]));
    if (question == null || question.trim().isEmpty || !mounted) return;
    setState(() => asking = true);
    String answer;
    try {
      final r = await context.read<ApiService>().askMeeting(callId, room.id, question.trim(), lines);
      answer = r['answer'] as String? ?? '';
    } catch (e) { answer = '$e'.replaceFirst('Exception: ', ''); }
    if (!mounted) return;
    setState(() => asking = false);
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => SafeArea(child: Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Row(children: [const Icon(Icons.auto_awesome), const SizedBox(width: 8), const Expanded(child: Text('Amer', style: TextStyle(fontWeight: FontWeight.w600))),
        Text('Only you can see this', style: TextStyle(fontSize: 12, color: Theme.of(s).colorScheme.outline))]),
      Text(gate.where, style: const TextStyle(fontSize: 11)),
      const SizedBox(height: 8), Text(question.trim(), style: const TextStyle(fontStyle: FontStyle.italic)),
      const SizedBox(height: 8), Flexible(child: SingleChildScrollView(child: SelectableText(answer))),
      const SizedBox(height: 12),
      Row(mainAxisAlignment: MainAxisAlignment.end, children: [
        TextButton(onPressed: () => Navigator.pop(s), child: Text(L.t(context, 'Close'))),
        FilledButton.icon(icon: const Icon(Icons.share, size: 18), label: Text(L.t(context, 'Share to everyone')), onPressed: () async {
          Navigator.pop(s); await room.sendTextEvent('🤖 Amer, asked by ${room.unsafeGetUserFromMemoryOrFallback(me).calcDisplayname()}: ${question.trim()}\n\n$answer'); }),
      ]),
    ]))));
  }

  /// Automatic follow-up (docs/MEETING_AGENDA.md): decisions become proposals to confirm, actions become tasks.
  Future<void> _followUp(ApiService api, String transcript) async {
    try {
      final people = room.getParticipants().where((u) => u.membership == mx.Membership.join).toList();
      final r = await api.ask('From this meeting, reply ONLY with JSON {"decisions":[{"text":str,"owner":name}],"actions":[{"title":str,"owner":name,"due_days":int}]}. Use only what was said. Names must be from: ${people.map((u) => u.calcDisplayname()).join(', ')}.',
          context: transcript, agent: 'assist', labels: [if (labelOf(room) != null) labelOf(room)!], encrypted: room.encrypted);
      final m = RegExp(r'\{.*\}', dotAll: true).firstMatch('${r['answer']}'); if (m == null) return;
      final j = jsonDecode(m.group(0)!) as Map;
      String? who(Object? n) => people.where((u) => u.calcDisplayname().toLowerCase() == '$n'.toLowerCase()).firstOrNull?.id;
      for (final d in ((j['decisions'] as List?) ?? const []).take(10)) {
        await proposeDecision(room, text: '${d['text']}', owner: who(d['owner']) ?? me);          // still needs the owner and one more to confirm
      }
      for (final a in ((j['actions'] as List?) ?? const []).take(20)) {
        final days = (a['due_days'] as num?)?.toInt();
        await saveTask(room, {'task_id': newId('task'), 'title': '${a['title']}', 'owner': who(a['owner']) ?? me, 'status': 'open',
            if (days != null) 'due': DateTime.now().add(Duration(days: days)).toIso8601String().substring(0, 10)});
      }
    } catch (_) {/* minutes are posted either way */}
  }

  Future<void> _switchCamera() async {
    final t = call!.lk.localParticipant?.videoTrackPublications.firstOrNull?.track;
    if (t is LocalVideoTrack) { front = !front; await t.setCameraPosition(front ? CameraPosition.front : CameraPosition.back); }
  }

  Future<void> _leave() async {
    unawaited(Handoff.clear(room.client));
    if (rec.recording && canRecord) await _stopRec('the person recording left');
    if (ctl != null) {                         // 1:1: signalling sends hangup + end and tears media down
      await stt.stop(); await ev?.dispose(); ev = null; await ctl!.hangup(); return;
    }
    cm?.inCall = false;
    tick?.cancel(); await stt.stop(); await ev?.dispose(); await call?.leave();
    if (amerNotes && (transcript.isNotEmpty || lines.isNotEmpty) && mounted) {
      final full = lines.isEmpty ? transcript.toString() : lines.map((l) => '${l['speaker']}: ${l['text']}').join('\n');
      final ag = agenda; final outline = ag == null ? '' : 'Agenda (use it as the outline): ${(ag['items'] as List).map((x) => x['t']).join('; ')}\nParking lot: ${parking.join('; ')}\n';
      final api = context.read<ApiService>();
      if (!aiFor(room).allowed) { if (mounted) Navigator.pop(context); return; }
      final label = labelOf(room);
      final r = await api.ask('Write minutes', context: '$outline$full', agent: 'minutes', labels: [if (label != null) label], encrypted: room.encrypted);
      await room.sendTextEvent('📝 Minutes by Amer\n\n${r['answer']}');
      if (r['error'] != true && r['blocked'] != true) await _followUp(api, '$outline$full');
    }
    if (mounted) Navigator.pop(context);
  }
  @override void dispose() { Availability.instance.activity(null); ctl?.removeListener(_onCtl); if (ctl != null && !ctl!.ended) ctl!.hangup(); if (widget.meeting) cm?.inCall = false; tick?.cancel(); ev?.dispose(); _roomEvents?.cancel(); _chatTl?.then((t) => t.cancelSubscriptions()); super.dispose(); }

  // ---------- impersonation protection (docs/IDENTITY_CHECK.md) ----------
  /// Media identities are Matrix user ids, admitted only with a token for a member of this encrypted chat. Whether
  /// that account's devices are verified tells you how sure you can be the account is really theirs.
  (IconData, Color, String) _idBadge(Participant p) {
    final id = p.identity;
    if (id.startsWith('guest-')) return (Icons.public, Colors.orange, 'Browser guest: not an Amer Teams account');
    final keys = room.client.userDeviceKeys[id]?.deviceKeys.values.toList() ?? const <mx.DeviceKeys>[];
    if (keys.isEmpty) return (Icons.help_outline, Colors.grey, 'Identity not checked: no device keys seen');
    final v = keys.where((d) => d.verified).length;
    return v == keys.length ? (Icons.verified_user, Colors.green, 'Verified: all of this person\'s devices are verified')
        : v > 0 ? (Icons.gpp_maybe, Colors.amber, 'Partly verified: $v of ${keys.length} devices verified')
        : (Icons.gpp_maybe, Colors.orange, 'Not verified: compare safety codes in their profile to verify');
  }
  static const _words = ['falcon', 'harbour', 'copper', 'saffron', 'meadow', 'lantern', 'orbit', 'pebble', 'cedar', 'violet', 'anchor', 'ember', 'glacier', 'marble', 'oasis', 'quartz',
    'ripple', 'sparrow', 'timber', 'walnut', 'zephyr', 'basalt', 'canyon', 'dune', 'fjord', 'garnet', 'ivory', 'juniper', 'kestrel', 'lagoon', 'nectar', 'opal'];
  /// Live check: a code sent end-to-end encrypted to the person's own account (their direct chat). Someone faking
  /// their face or voice in this call cannot see it, so cannot read it out.
  Future<void> _liveCheck(Participant p) async {
    final r = Random.secure(); final code = List.generate(3, (_) => _words[r.nextInt(_words.length)]).join(' ');
    try {
      final dm = await room.client.startDirectChat(p.identity, enableEncryption: true);
      final dmRoom = room.client.getRoomById(dm);
      if (dmRoom == null || !dmRoom.encrypted) { _snack('No encrypted direct chat with ${p.name}'); return; }
      await dmRoom.sendTextEvent('🛡️ Identity check from the meeting: please read these three words aloud in the call: "$code". If you are not in a meeting right now, someone may be impersonating you; tell your security team.');
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: Text('Live check: ${p.name}'),
        content: Text('A code was sent, end-to-end encrypted, to ${p.name}\'s own account. Ask them to read it aloud.\n\nThey should say:\n\n"$code"\n\nIf they cannot, the person in the video may not be who they appear to be. Synthetic video and voice cannot be ruled out by looking alone.'),
        actions: [TextButton(onPressed: () { Navigator.pop(d); _send({'t': 'idcheck', 'who': p.identity, 'ok': false}); _snack('Recorded: ${p.name} did not pass the check'); }, child: Text(L.t(context, 'They could not'))),
                  FilledButton(onPressed: () { Navigator.pop(d); _send({'t': 'idcheck', 'who': p.identity, 'ok': true}); setState(() => idChecked.add(p.identity)); }, child: Text(L.t(context, 'They read it correctly')))]));
    } catch (e) { _snack('Could not send the check: $e'); }
  }
  final idChecked = <String>{};

  // ---------- network-aware calls (docs/NETWORK_AWARE.md) ----------
  String net = 'normal';                 // normal | saver | audio
  bool netAuto = true, netAutoSwitched = false; DateTime? _poorSince, _goodSince; bool _camBeforeAudio = false;
  void _onQuality(ParticipantConnectionQualityUpdatedEvent e) {
    if (e.participant is! LocalParticipant) { if (mounted) setState(() {}); return; }   // others' quality is shown on their tile
    final q = e.connectionQuality; final now = DateTime.now();
    if (q == ConnectionQuality.poor || q == ConnectionQuality.lost) { _poorSince ??= now; _goodSince = null; }
    else if (q == ConnectionQuality.excellent || q == ConnectionQuality.good) { _goodSince ??= now; _poorSince = null; }
    if (!netAuto) return;
    final bad = _poorSince == null ? Duration.zero : now.difference(_poorSince!), ok = _goodSince == null ? Duration.zero : now.difference(_goodSince!);
    if (net == 'normal' && bad >= const Duration(seconds: 10)) { _setNet('saver', auto: true); }
    else if (net == 'saver' && (bad >= const Duration(seconds: 30) || q == ConnectionQuality.lost)) { _setNet('audio', auto: true); }
    else if (net != 'normal' && netAutoSwitched && ok >= const Duration(seconds: 30)) { _setNet('normal', auto: true); }
  }
  Future<void> _setNet(String mode, {bool auto = false}) async {
    final lk = call?.lk; if (lk == null) return;
    final prev = net; net = mode; netAutoSwitched = auto && mode != 'normal';
    for (final p in lk.remoteParticipants.values) {
      for (final pub in p.videoTrackPublications) {
        if (mode == 'audio' && pub.source != TrackSource.screenShareVideo) { await pub.disable(); }     // screen share stays: it is usually why you are there
        else { await pub.enable(); await pub.setVideoQuality(mode == 'saver' ? VideoQuality.LOW : VideoQuality.HIGH); }
      }
    }
    if (mode == 'audio' && prev != 'audio') { _camBeforeAudio = cam; if (cam) { cam = false; await lk.localParticipant?.setCameraEnabled(false); } }
    if (prev == 'audio' && mode != 'audio' && _camBeforeAudio && !attendee) { cam = true; await lk.localParticipant?.setCameraEnabled(true); }
    if (!mounted) return;
    setState(() {});
    final msg = {'saver': 'Weak network: video lowered to save bandwidth', 'audio': 'Weak network: switched to audio only (screen share kept)', 'normal': 'Network recovered: full video back'}[mode]!;
    if (prev != mode) { _snack(auto ? msg : 'Video: ${{'saver': 'data saver', 'audio': 'audio only', 'normal': 'full quality'}[mode]}'); _say(msg); }
  }
  Future<void> _netDialog() async {
    final v = await showDialog<String>(context: context, builder: (d) => SimpleDialog(title: const Text('Network and video'), children: [
      for (final (k, l, sub) in [('auto', 'Automatic', 'Lower video, then audio only, when your network is weak; back when it recovers'), ('normal', 'Full quality', ''), ('saver', 'Data saver', 'Others\' video in low quality'), ('audio', 'Audio only', 'No video except screen share')])
        SimpleDialogOption(onPressed: () => Navigator.pop(d, k), child: ListTile(title: Text(l), subtitle: sub.isEmpty ? null : Text(sub), trailing: (k == 'auto' ? netAuto : (!netAuto && net == k)) ? const Icon(Icons.check) : null)),
    ]));
    if (v == null) return;
    if (v == 'auto') { netAuto = true; setState(() {}); return; }
    netAuto = false; await _setNet(v);
  }
  Widget _qualityDot(Participant p) {
    final q = p.connectionQuality;
    final (c, t) = switch (q) { ConnectionQuality.excellent => (Colors.green, 'Excellent connection'), ConnectionQuality.good => (Colors.lightGreen, 'Good connection'),
      ConnectionQuality.poor => (Colors.orange, 'Poor connection'), ConnectionQuality.lost => (Colors.red, 'Connection lost'), _ => (Colors.grey, 'Connection unknown') };
    return Tooltip(message: t, child: Icon(Icons.signal_cellular_alt, size: 14, color: c, semanticLabel: t));
  }

  // ---------- multi-device handoff (docs/HANDOFF.md) ----------
  void _onDisconnected(RoomDisconnectedEvent e) {
    if (e.reason != DisconnectReason.duplicateIdentity || !mounted) return;
    _say('Call moved to your other device');
    ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('This call moved to your other device')));
    stt.stop(); tick?.cancel(); Navigator.of(context).maybePop();
  }

  // ---------- accessibility (docs/ACCESSIBILITY.md) ----------
  Widget _shortcuts(Widget child) => CallbackShortcuts(bindings: {
    const SingleActivator(LogicalKeyboardKey.keyD, control: true): () { if (attendee) return; mic = !mic; call?.lk.localParticipant?.setMicrophoneEnabled(mic); _say(mic ? 'Microphone on' : 'Muted'); setState(() {}); },
    const SingleActivator(LogicalKeyboardKey.keyE, control: true): () { if (attendee) return; cam = !cam; call?.lk.localParticipant?.setCameraEnabled(cam); _say(cam ? 'Camera on' : 'Camera off'); setState(() {}); },
    const SingleActivator(LogicalKeyboardKey.keyH, control: true, shift: true): () { _toggleHand(); _say(myHand ? 'Hand lowered' : 'Hand raised'); },
    const SingleActivator(LogicalKeyboardKey.keyC, control: true, shift: true): () { _toggleCaptions(); },
    const SingleActivator(LogicalKeyboardKey.keyL, control: true, shift: true): () { _leave(); },
  }, child: Focus(autofocus: true, child: child));
  /// Spoken by screen readers (TalkBack, VoiceOver, Narrator, Orca).
  void _say(String text) => SemanticsService.announce(text, Directionality.of(context));

  // ---------- live translated captions (docs/TRANSLATED_CAPTIONS.md) ----------
  // Interpreter (Teams parity): speak each translated caption aloud in the listener's language, on this device only.
  bool speakTr = false; final _tts = FlutterTts();
  static String _ttsCode(String l) => l.startsWith('English') ? 'en-GB' : l.contains('Arabic') ? 'ar' : l.contains('French') ? 'fr-FR' : l.contains('Hindi') ? 'hi-IN'
      : l.contains('Urdu') ? 'ur-PK' : l.contains('Bengali') ? 'bn-IN' : l.startsWith('Tagalog') ? 'fil-PH' : l.contains('Spanish') ? 'es-ES' : l.contains('Chinese') ? 'zh-CN' : 'en-GB';
  Future<void> _interpreter() async {
    if (capLang == null) { await _pickCapLang(); if (capLang == null) return; }
    setState(() => speakTr = !speakTr);
    if (speakTr) { try { await _tts.setLanguage(_ttsCode(capLang!)); await _tts.awaitSpeakCompletion(true); } catch (_) { setState(() => speakTr = false); _snack('This device has no voice for spoken interpretation; captions still show'); return; } }
    _snack(speakTr ? 'Interpreter on: others are spoken to you in $capLang' : 'Interpreter off');
  }
  String? capLang; final tCaps = <(String, String)>[]; final _tq = <(String, String)>[]; bool _tBusy = false;
  static const capLangs = ['English', 'العربية (Arabic)', 'Français (French)', 'हिन्दी (Hindi)', 'اردو (Urdu)', 'বাংলা (Bengali)', 'Tagalog', 'Español (Spanish)', '中文 (Chinese)', 'Русский (Russian)'];
  void _translateLine(String who, String text) {
    if (capLang == null || text.trim().isEmpty) return;
    _tq.add((who, text)); if (_tq.length > 6) _tq.removeAt(0);          // keep up with speech: drop the oldest if behind
    _pumpTranslations();
  }
  Future<void> _pumpTranslations() async {
    if (_tBusy) return; _tBusy = true;
    try {
      while (_tq.isNotEmpty && capLang != null && mounted) {
        final (who, text) = _tq.removeAt(0);
        final label = labelOf(room);
        final r = await context.read<ApiService>().ask('Translate this meeting caption to $capLang. Reply with the translation only.', context: text, agent: 'trans', labels: [if (label != null) label], encrypted: room.encrypted);
        if (!mounted) return;
        if (r['blocked'] == true) { setState(() { capLang = null; }); _snack('${r['answer']}'); return; }
        setState(() { tCaps.add((who, '${r['answer']}'.trim())); if (tCaps.length > 3) tCaps.removeAt(0); });
        if (speakTr && who != 'Me') { try { await _tts.speak('${r['answer']}'.trim()); } catch (_) {} }
      }
    } catch (e) { _snack('Translation stopped: $e'); } finally { _tBusy = false; }
  }
  Future<void> _pickCapLang() async {
    final gate = aiFor(room, small: true);
    if (!gate.allowed) { _snack(gate.where); return; }
    final v = await showDialog<String>(context: context, builder: (d) => SimpleDialog(title: const Text('Translated captions'), children: [
      Padding(padding: const EdgeInsets.symmetric(horizontal: 24), child: Text('Captions from everyone who shares them (Amer on in this meeting) are translated for you only. ${gate.where}.', style: const TextStyle(fontSize: 12))),
      for (final l in capLangs) SimpleDialogOption(onPressed: () => Navigator.pop(d, l), child: Text(l)),
      if (capLang != null) SimpleDialogOption(onPressed: () => Navigator.pop(d, ''), child: Text(L.t(context, 'Turn off'))),
    ]));
    if (v == null) return;
    setState(() { capLang = v.isEmpty ? null : v; tCaps.clear(); _tq.clear(); });
    if (capLang != null && !aiOn) _snack('Others\' captions are shared only while Amer is on in this meeting; your own speech is translated now');
  }

  // ---------- browser guests: lobby and key hand-over (docs/GUESTS.md) ----------
  final lobby = <String, (String, String)>{};      // identity -> (X25519 public key, display name), waiting
  final admitted = <String, (String, int)>{};     // identity -> (public key, key index last sent)
  bool _askedWho = false;
  void _guestTick() {
    if (!isHost || call == null) return;
    final here = call!.lk.remoteParticipants.keys.toSet();
    lobby.removeWhere((k, _) => !here.contains(k)); admitted.removeWhere((k, _) => !here.contains(k));
    if (!_askedWho && here.any((i) => i.startsWith('guest-'))) { _askedWho = true; _send({'t': 'gk-who'}); }
    for (final e in admitted.entries.toList()) { if (e.value.$2 != call!.keyIndex) _sendKey(e.key, e.value.$1); }   // the key rotated
  }
  Future<void> _sendKey(String ident, String pk) async {
    final k = call?.sharedKeyForGuests; if (k == null) return;
    admitted[ident] = (pk, call!.keyIndex);
    try { await _send(await GuestKeys.wrap(k, pk, call!.keyIndex, ident)); } catch (_) { admitted.remove(ident); }
  }
  Future<void> _admit(String ident) async { final g = lobby.remove(ident); if (g != null) { await _sendKey(ident, g.$1); setState(() {}); } }
  /// Phone dial-in (docs/PHONE_DIALIN.md): a separate, labelled bridge, since phones cannot join end-to-end encryption.
  Future<void> _dialIn() async {
    try {
      final r = await context.read<ApiService>().postMap('/v1/phone/dialin', {'room_id': widget.roomId});
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Phone dial-in'),
        content: SelectableText('Dial ${r['number']}\nPIN ${r['pin']}#\n\nPhone callers join a separate phone bridge for this meeting. ${r['security']}: people who want to talk with them join the bridge too.'),
        actions: [
          TextButton(onPressed: () async { Navigator.pop(d); await context.read<ApiService>().deletePath('/v1/phone/dialin/${Uri.encodeComponent(widget.roomId)}'); _snack('Dial-in closed'); }, child: Text(L.t(context, 'Close dial-in'))),
          TextButton(onPressed: () { Clipboard.setData(ClipboardData(text: 'Dial ${r['number']}, PIN ${r['pin']}#')); Navigator.pop(d); }, child: Text(L.t(context, 'Copy'))),
          FilledButton(onPressed: () { Navigator.pop(d); Navigator.push(context, MaterialPageRoute(builder: (_) => PhoneScreen(bridgeRoomId: widget.roomId))); }, child: Text(L.t(context, 'Join the phone bridge'))),
        ]));
    } catch (e) { _snack('$e'.replaceFirst('Exception: ', '')); }
  }

  Future<void> _guestLinkDialog({bool webinar = false}) async {
    final api = context.read<ApiService>();
    try {
      final Uri link; String extra = '';
      if (webinar) {
        final r = await api.createWebinar(widget.roomId, callId, room.getLocalizedDisplayname());
        link = api.publicUrl('/join?w=${r['slug']}'); extra = 'Registration page. Each person who registers gets a personal join link and joins as an attendee.';
      } else {
        final r = await api.guestLink(widget.roomId, callId);
        link = api.publicUrl('/join#${r['code']}'); extra = 'Works in a browser for 24 hours. Guests wait in the lobby until an organiser or presenter lets them in.';
      }
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: Text(webinar ? 'Webinar registration' : 'Guest link'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [SelectableText('$link'), const SizedBox(height: 8), Text(extra)]),
        actions: [TextButton(onPressed: () { Clipboard.setData(ClipboardData(text: '$link')); Navigator.pop(d); _snack('Link copied'); }, child: Text(L.t(context, 'Copy')))]));
    } catch (e) { _snack('$e'.replaceFirst('Exception: ', '')); }
  }

  // ---------- Q&A (webinars and town halls) ----------
  final qa = <String, Map<String, dynamic>>{}; final _qaTick = ValueNotifier(0);
  void _onQa(Map j, String who) {
    final id = j['id'] as String?; if (id == null) return;
    if (j['op'] == 'ask' && j['q'] is String) qa[id] = {'id': id, 'q': (j['q'] as String).substring(0, min((j['q'] as String).length, 300)), 'name': j['name'] ?? who, 'votes': 0, 'answered': false};
    if (j['op'] == 'vote') qa[id]?['votes'] = (qa[id]?['votes'] as int? ?? 0) + 1;
    if (j['op'] == 'answered') qa[id]?['answered'] = true;
    _qaTick.value++;
  }
  void _qaSheet() {
    final input = TextEditingController(); final voted = <String>{};
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (c) => Padding(padding: EdgeInsets.only(bottom: MediaQuery.of(c).viewInsets.bottom),
      child: SizedBox(height: 480, child: ValueListenableBuilder(valueListenable: _qaTick, builder: (c, _, __) {
        final list = qa.values.toList()..sort((a, b) => a['answered'] != b['answered'] ? (a['answered'] ? 1 : -1) : (b['votes'] as int).compareTo(a['votes'] as int));
        return Column(children: [
          const ListTile(title: Text('Questions'), subtitle: Text('Most votes first. Hosts mark questions answered.')),
          Expanded(child: list.isEmpty ? const Center(child: Text('No questions yet')) : ListView(children: [for (final q in list) ListTile(
            leading: Text('${q['votes']}'), title: Text(q['q'], style: TextStyle(decoration: q['answered'] ? TextDecoration.lineThrough : null)), subtitle: Text(q['name']),
            trailing: Row(mainAxisSize: MainAxisSize.min, children: [
              if (!q['answered'] && !voted.contains(q['id'])) IconButton(tooltip: 'Vote', icon: const Icon(Icons.arrow_upward), onPressed: () { voted.add(q['id']); _onQa({'op': 'vote', 'id': q['id']}, ''); _send({'t': 'qa', 'op': 'vote', 'id': q['id']}); }),
              if (isHost && !q['answered']) IconButton(tooltip: 'Mark answered', icon: const Icon(Icons.check), onPressed: () { _onQa({'op': 'answered', 'id': q['id']}, ''); _send({'t': 'qa', 'op': 'answered', 'id': q['id']}); }),
            ]))])),
          Padding(padding: const EdgeInsets.all(8), child: Row(children: [
            Expanded(child: TextField(controller: input, maxLength: 300, decoration: const InputDecoration(hintText: 'Ask a question', isDense: true, counterText: ''))),
            IconButton(tooltip: 'Ask', icon: const Icon(Icons.send), onPressed: () {
              final t = input.text.trim(); if (t.isEmpty) return; input.clear();
              final m = {'t': 'qa', 'op': 'ask', 'id': 'q-${DateTime.now().millisecondsSinceEpoch}-$me', 'q': t, 'name': room.unsafeGetUserFromMemoryOrFallback(me).calcDisplayname()};
              _onQa(m, 'You'); _send(m); }),
          ])),
        ]);
      }))));
  }

  // ---------- recordings with consent (docs/RECORDINGS.md) ----------
  final rec = RecordingConsent(); final recorder = DeviceRecorder(); final _asked = <String>{};
  bool _recPrompt = false;
  String get _myId => call?.lk.localParticipant?.identity ?? '';
  List<String> get _present => [_myId, ...?call?.lk.remoteParticipants.values.map((p) => p.identity)];
  void _audit(String e) { if (rec.id != null) context.read<ApiService>().recordingEvent(widget.roomId, callId, rec.id!, e).catchError((_) => <String, dynamic>{}); }

  Future<void> _askRecord() async {
    if (!DeviceRecorder.supported) { _snack('Recording is made on the organiser\'s phone or tablet: not available on this device'); return; }
    rec.reset(); rec.id = 'rec-${DateTime.now().millisecondsSinceEpoch}'; rec.agreed.add(_myId); _asked.clear();
    _audit('requested'); _audit('consent');
    await _send({'t': 'rec', 'op': 'ask', 'id': rec.id}); _asked.addAll(_present);
    setState(() {}); _snack('Asking everyone for consent to record');
    _recTick();
  }
  /// Host side: start when everyone present agreed; ask late joiners; stop if anyone present has not agreed.
  void _recTick() {
    if (!canRecord || rec.id == null || call == null) return;
    for (final p in _present.where((p) => !_asked.contains(p))) { _asked.add(p); _send({'t': 'rec', 'op': rec.recording ? 'ask-late' : 'ask', 'id': rec.id}); }
    if (!rec.recording && rec.allAgreed(_present)) { _startRec(); }
    else if (rec.recording && rec.declined.isNotEmpty) { _stopRec('${rec.declined.first} declined'); }
  }
  Future<void> _startRec() async {
    rec.recording = true; setState(() {});
    try {
      final cam = call!.lk.remoteParticipants.values.expand((p) => p.videoTrackPublications).map((p) => p.track).whereType<VideoTrack>().firstOrNull
          ?? call!.lk.localParticipant?.videoTrackPublications.map((p) => p.track).whereType<VideoTrack>().firstOrNull;
      await recorder.start(cam?.mediaStreamTrack);
      _audit('started'); await _send({'t': 'rec', 'op': 'started', 'id': rec.id});
    } catch (e) { rec.recording = false; setState(() {}); _snack('Could not start recording: $e'); }
  }
  Future<void> _stopRec(String why) async {
    if (!rec.recording) { rec.reset(); setState(() {}); return; }
    rec.recording = false; final id = rec.id; setState(() {});
    _audit('stopped'); await _send({'t': 'rec', 'op': 'stopped', 'id': id, 'why': why});
    final f = await recorder.stop(); rec.reset(); setState(() {});
    if (f == null) { _snack('The recording was empty'); return; }
    try {
      final recStart = recorder.started ?? DateTime.now();
      final evId = await room.sendFileEvent(mx.MatrixVideoFile(bytes: await f.readAsBytes(), name: 'Meeting recording ${DateTime.now().toIso8601String().substring(0, 16)}.mp4', mimeType: 'video/mp4'));
      await f.delete(); _snack('Recording shared in the chat, end-to-end encrypted ($why)');
      if (evId != null) unawaited(_recap(evId, recStart));
    } catch (e) { _snack('Could not share the recording: $e'); }
  }
  /// Video recap with chapters (docs/VIDEO_RECAP.md): from the meeting's captions during the recording, posted in the
  /// recording's thread. Needs captions (Amer on, or your own captions); otherwise there is nothing to chapter.
  Future<void> _recap(String recordingEvent, DateTime recStart) async {
    final span = lines.where((l) => (l['ts'] as int) >= recStart.millisecondsSinceEpoch).toList();
    if (span.length < 3 || !aiFor(room).allowed) return;
    String at(int ts) { final s = (ts - recStart.millisecondsSinceEpoch) ~/ 1000; return '${(s ~/ 60).toString().padLeft(2, '0')}:${(s % 60).toString().padLeft(2, '0')}'; }
    final text = span.map((l) => '[${at(l['ts'] as int)}] ${l['speaker']}: ${l['text']}').join('\n');
    try {
      final label = labelOf(room);
      final r = await context.read<ApiService>().ask('Make a video recap of this recorded meeting. Reply ONLY with JSON {"summary": str (3 sentences), "chapters": [{"at": "mm:ss", "title": str}]}. 3 to 10 chapters, at topic changes, using the [mm:ss] times given. British English.',
          context: text, agent: 'summ', labels: [if (label != null) label], encrypted: room.encrypted);
      final m = RegExp(r'\{.*\}', dotAll: true).firstMatch('${r['answer']}'); if (m == null) return;
      final j = jsonDecode(m.group(0)!) as Map;
      final ch = [for (final c in (j['chapters'] as List? ?? const [])) if (RegExp(r'^\d{1,3}:\d{2}$').hasMatch('${c['at']}')) '${c['at']}  ${c['title']}'];
      if (ch.isEmpty) return;
      await room.sendTextEvent('🎬 Recap\n${j['summary'] ?? ''}\n\nChapters\n${ch.join('\n')}', threadRootEventId: recordingEvent, threadLastEventId: recordingEvent);
    } catch (_) {}
  }

  void _onRec(Map j, String from, String who) {
    final id = j['id'] as String?; final op = j['op'];
    if (op == 'ask' || op == 'ask-late') { if (!_recPrompt) _consentDialog(id!, who, op == 'ask-late'); return; }
    if (op == 'started') { rec.id = id; rec.recording = true; _say('Recording started'); return; }
    if (op == 'stopped') { rec.reset(); _snack('Recording stopped${j['why'] != null ? ' (${j['why']})' : ''}'); return; }
    if (!canRecord || id != rec.id) return;
    if (op == 'yes') { rec.agreed.add(from); _recTick(); }
    if (op == 'no' || op == 'withdraw') { rec.agreed.remove(from); rec.declined.add(who); _recTick(); if (!rec.recording) { _snack('$who declined: not recording'); rec.reset(); } }
  }
  Future<void> _consentDialog(String id, String host, bool late) async {
    _recPrompt = true;
    final ok = await showDialog<bool>(context: context, barrierDismissible: false, builder: (d) => AlertDialog(
      title: const Text('Record this meeting?'),
      content: Text('$host wants to record${late ? ' (already recording)' : ''}. The recording includes video and audio of everyone and is shared in the meeting chat, end-to-end encrypted. It starts only if everyone agrees; you can withdraw at any time.'),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Decline'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'I agree')))]));
    _recPrompt = false;
    rec.id = id; if (ok == true) rec.agreed.add(_myId);
    final api = context.read<ApiService>(); api.recordingEvent(widget.roomId, callId, id, ok == true ? 'consent' : 'decline').catchError((_) => <String, dynamic>{});
    await _send({'t': 'rec', 'op': ok == true ? 'yes' : 'no', 'id': id});
    if (mounted) setState(() {});
  }
  Future<void> _withdraw() async {
    final id = rec.id; if (id == null) return;
    context.read<ApiService>().recordingEvent(widget.roomId, callId, id, 'withdrawn').catchError((_) => <String, dynamic>{});
    await _send({'t': 'rec', 'op': 'withdraw', 'id': id}); rec.agreed.remove(_myId); setState(() {});
  }

  // ---------- UI ----------
  bool bgBlur = false, lowLight = false;
  /// Background effects run on this device before encoding and encryption (docs/BACKGROUND_EFFECTS.md).
  Future<void> _effects({bool? blur, bool? low}) async {
    final pub = call?.lk.localParticipant?.videoTrackPublications.where((p) => p.source == TrackSource.camera).firstOrNull;
    final id = pub?.track?.mediaStreamTrack.id; if (id == null) return;
    final b = blur ?? bgBlur, l = low ?? lowLight;
    final ok = await AmerBackground.apply(id, blur: b ? 12 : 0, lowLight: l);
    if (!mounted) return;
    if (ok) { setState(() { bgBlur = b; lowLight = l; }); }
    else { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Background effects are not available on this device'))); }
  }

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    if (err != null) return Scaffold(appBar: AppBar(), body: Center(child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      Text('Could not join: $err', textAlign: TextAlign.center), const SizedBox(height: 16),
      FilledButton(onPressed: () => Navigator.of(c).maybePop(), child: Text(L.t(context, 'Back')))]))));
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
      if (hands.isNotEmpty || myHand) Positioned(left: 12, top: 12, child: Chip(avatar: const Text('✋'), label: Text([if (myHand) 'You', ...hands].join(', ')))),
      if (waiting.isNotEmpty) Positioned(left: 12, right: 12, top: 56, child: Card(color: cs.tertiaryContainer, child: Column(children: [
        for (final u in waiting) ListTile(leading: const Icon(Icons.hourglass_top), title: Text('${u.calcDisplayname()} is in the waiting room'),
          trailing: Wrap(spacing: 6, children: [
            TextButton(onPressed: () async { await meetings.decline(room, u.id); setState(() {}); }, child: Text(L.t(context, 'Decline'))),
            FilledButton(onPressed: () async { await meetings.admit(room, u.id); setState(() {}); }, child: Text(L.t(context, 'Admit')))])),
      ]))),
    ]);

    return _shortcuts(Scaffold(
      appBar: AppBar(
        title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(room.getLocalizedDisplayname(), overflow: TextOverflow.ellipsis),
          Row(children: [
            if (rec.recording) const Padding(padding: EdgeInsets.only(right: 6), child: Chip(visualDensity: VisualDensity.compact, avatar: Icon(Icons.fiber_manual_record, color: Colors.red, size: 14), label: Text('Recording'))),
            Icon(Icons.lock, size: 14, color: call!.encrypted ? Colors.green : cs.error), const SizedBox(width: 4),
            Flexible(child: Text('${call!.encrypted ? 'Encrypted · quantum-safe' : 'NOT ENCRYPTED'} · $timer · code ${call!.safetyCode}',
                style: Theme.of(c).textTheme.labelSmall, overflow: TextOverflow.ellipsis)),
          ]),
        ]),
        actions: [
          if (widget.meeting) Padding(padding: const EdgeInsets.only(right: 4), child: FilledButton.tonalIcon(onPressed: _shareLink, icon: const Icon(Icons.person_add_alt_1, size: 18), label: Text(L.t(context, 'Invite')))),
          if (mid != null) TextButton.icon(icon: const Icon(Icons.copy, size: 16), label: Text(MeetingService.format(mid)),
            onPressed: () { Clipboard.setData(ClipboardData(text: MeetingService.format(mid))); ScaffoldMessenger.of(c).showSnackBar(const SnackBar(content: Text('Meeting ID copied'))); }),
          IconButton(tooltip: grid ? 'Speaker view' : 'Grid view', icon: Icon(grid ? Icons.person : Icons.grid_view), onPressed: () => setState(() => grid = !grid)),
          IconButton(tooltip: 'Participants', icon: Badge(isLabelVisible: waiting.isNotEmpty, label: Text('${waiting.length}'), child: const Icon(Icons.people)),
              onPressed: () => setState(() => panel = panel == _Panel.people ? _Panel.none : _Panel.people)),
          IconButton(tooltip: 'Chat', icon: const Icon(Icons.chat), onPressed: () => setState(() => panel = panel == _Panel.chat ? _Panel.none : _Panel.chat)),
          PopupMenuButton<String>(tooltip: 'More', onSelected: (v) {
            switch (v) {
              case 'devices': _deviceSettings();
              case 'wb': Navigator.push(c, MaterialPageRoute(builder: (_) => WhiteboardScreen(roomId: widget.roomId)));
              case 'share': _shareLink();
              case 'breakout': _breakouts();
              case 'muteall': _host('mute_all');
              case 'lock': _toggleLock();
              case 'amer': _toggleAi();
              case 'agenda': _agendaDialog();
              case 'webinar': _setWebinar(!webinar);
              case 'rec': rec.recording ? _stopRec('stopped by the organiser') : _askRecord();
              case 'withdraw': _withdraw();
              case 'guest': _guestLinkDialog();
              case 'dialin': _dialIn();
              case 'webinarreg': _guestLinkDialog(webinar: true);
              case 'qa': _qaSheet();
              case 'tcap': _pickCapLang();
              case 'net': _netDialog();
              case 'end': _host('end');
              case 'interp': _interpreter();
              case 'options': Navigator.push(context, MaterialPageRoute(builder: (_) => MeetingOptionsScreen(roomId: widget.roomId))).then((_) => setState(() {}));
            }
          }, itemBuilder: (_) => [
            const PopupMenuItem(value: 'devices', child: ListTile(leading: Icon(Icons.settings_voice), title: Text('Audio and video settings'))),
            const PopupMenuItem(value: 'wb', child: ListTile(leading: Icon(Icons.draw), title: Text('Whiteboard'))),
            if (isHost) const PopupMenuItem(value: 'options', child: ListTile(leading: Icon(Icons.tune), title: Text('Meeting options'))),
            const PopupMenuItem(value: 'share', child: ListTile(leading: Icon(Icons.share), title: Text('Copy invitation'))),
            if (isHost && widget.meeting) const PopupMenuItem(value: 'breakout', child: ListTile(leading: Icon(Icons.call_split), title: Text('Breakout rooms'))),
            if (canModerate) const PopupMenuItem(value: 'muteall', child: ListTile(leading: Icon(Icons.mic_off), title: Text('Mute everyone'))),
            if (isHost && widget.meeting) PopupMenuItem(value: 'lock', child: ListTile(leading: Icon(locked ? Icons.lock_open : Icons.lock), title: Text(locked ? 'Unlock meeting' : 'Lock meeting'))),
            if (isHost && widget.meeting) PopupMenuItem(value: 'webinar', child: ListTile(leading: const Icon(Icons.campaign), title: Text(webinar ? 'Turn off webinar mode' : 'Webinar mode'))),
            if (isHost && widget.meeting) const PopupMenuItem(value: 'agenda', child: ListTile(leading: Icon(Icons.list_alt), title: Text('Agenda and timer'))),
            if (isHost && widget.meeting) PopupMenuItem(value: 'amer', child: ListTile(leading: const Icon(Icons.auto_awesome), title: Text(aiOn ? 'Turn off Amer in this meeting' : 'Amer in this meeting'))),
            if (canRecord && widget.meeting) PopupMenuItem(value: 'rec', child: ListTile(leading: Icon(rec.recording ? Icons.stop : Icons.fiber_manual_record, color: Colors.red), title: Text(rec.recording ? 'Stop recording' : 'Record (with consent)'))),
            if (!isHost && rec.recording) const PopupMenuItem(value: 'withdraw', child: ListTile(leading: Icon(Icons.do_not_disturb), title: Text('Withdraw consent'))),
            if (isHost && widget.meeting) const PopupMenuItem(value: 'dialin', child: ListTile(leading: Icon(Icons.dialpad), title: Text('Phone dial-in'))),
            if (isHost && widget.meeting) const PopupMenuItem(value: 'guest', child: ListTile(leading: Icon(Icons.public), title: Text('Guest link (browser)'))),
            if (isHost && widget.meeting) const PopupMenuItem(value: 'webinarreg', child: ListTile(leading: Icon(Icons.how_to_reg), title: Text('Webinar registration page'))),
            PopupMenuItem(value: 'net', child: ListTile(leading: Icon(net == 'normal' ? Icons.network_check : Icons.signal_cellular_connected_no_internet_4_bar), title: Text('Network: ${{'normal': 'full quality', 'saver': 'data saver', 'audio': 'audio only'}[net]}${netAutoSwitched ? ' (automatic)' : ''}'))),
            PopupMenuItem(value: 'tcap', child: ListTile(leading: const Icon(Icons.translate), title: Text(capLang == null ? 'Translated captions' : 'Captions in $capLang'))),
            PopupMenuItem(value: 'interp', child: ListTile(leading: const Icon(Icons.record_voice_over), title: Text(speakTr ? 'Interpreter: on' : 'Interpreter (hear others in your language)'))),
            if (widget.meeting && meetingOptionsOf(room)['qa'] != false) const PopupMenuItem(value: 'qa', child: ListTile(leading: Icon(Icons.question_answer), title: Text('Q&A'))),
            if (isHost) const PopupMenuItem(value: 'end', child: ListTile(leading: Icon(Icons.stop_circle, color: Colors.red), title: Text('End for everyone'))),
          ]),
        ]),
      body: Column(children: [
        if (canModerate && meetingOptionsOf(room)['who_admits'] != 'organisers' || isHost) for (final g in lobby.entries) MaterialBanner(leading: const Icon(Icons.public), content: Text('${g.value.$2} is waiting in the lobby (browser guest)'),
          actions: [TextButton(onPressed: () { lobby.remove(g.key); _host('remove', identity: g.key); setState(() {}); }, child: Text(L.t(context, 'Remove'))), FilledButton(onPressed: () => _admit(g.key), child: Text(L.t(context, 'Let in')))]),
        if (attendee) MaterialBanner(content: const Text('You are an attendee in this webinar. Raise your hand to ask to speak.'), actions: [TextButton(onPressed: _toggleHand, child: Text(myHand ? 'Lower hand' : 'Raise hand'))]),
        if (widget.meeting && call!.lk.remoteParticipants.isEmpty) MaterialBanner(leading: const Icon(Icons.groups_outlined),
          content: Text("You're the only one here.${mid != null ? ' Share meeting ID ${MeetingService.format(mid)} or invite people.' : ' Invite people to join.'}"),
          actions: [FilledButton.tonal(onPressed: _shareLink, child: Text(L.t(context, 'Invite people')))]),
        if (widget.meeting && _agendaBar(c) != null) _agendaBar(c)!,
        if (aiOn) MaterialBanner(leading: const Icon(Icons.hearing, color: Colors.deepPurple),
          content: Text(captions ? 'AI listening · Amer is on for this meeting. Your speech is transcribed on this device and shared encrypted with the meeting.'
                                 : 'AI listening · Amer is on for this meeting. Your speech is not shared until you turn on Captions.'),
          actions: [
            if (!captions) TextButton(onPressed: _toggleCaptions, child: Text(L.t(context, 'Share my speech'))),
            if (isHost) TextButton(onPressed: _toggleAi, child: Text(L.t(context, 'Turn off'))),
            FilledButton.tonal(onPressed: asking ? null : () => _askDialog(), child: Text(asking ? 'Asking…' : 'Ask Amer'))]),
        if (amerNotes) MaterialBanner(content: const Text('Amer is taking notes. The on-device transcript goes to the AI engine when you leave.'), actions: [TextButton(onPressed: () => setState(() => amerNotes = false), child: Text(L.t(context, 'Stop')))]),
        Expanded(child: wide || panel == _Panel.none
            ? Row(children: [Expanded(child: stage), if (panel != _Panel.none) SizedBox(width: 340, child: _panel(people, waiting))])
            : _panel(people, waiting)),
        if (captions) Container(width: double.infinity, padding: const EdgeInsets.all(12), color: cs.surfaceContainerHighest, child: Text(liveCaption.isEmpty ? 'Listening on this device…' : liveCaption)),
        if (capLang != null) Container(width: double.infinity, padding: const EdgeInsets.all(12), color: cs.secondaryContainer, child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
          Text('Translated to $capLang', style: Theme.of(context).textTheme.labelSmall),
          if (tCaps.isEmpty) const Text('Waiting for speech…'),
          for (final (w, t) in tCaps) Text('$w: $t', textDirection: RegExp(r'[\u0600-\u06FF]').hasMatch(t) ? TextDirection.rtl : TextDirection.ltr)])),
        // Teams-style meeting bar: the controls you use all the time in the middle; the rest under "More effects";
        // Leave on the far right, away from the others, so it is not pressed by mistake.
        SafeArea(top: false, child: Padding(padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 12), child: Row(children: [
          const Spacer(),
          Flexible(flex: 8, child: Wrap(alignment: WrapAlignment.center, spacing: 10, runSpacing: 8, children: [
          if (!attendee) _btn(mic ? Icons.mic : Icons.mic_off, mic ? 'Mute' : 'Unmute', () { if (!mic && !optAllowMic(room, me)) { _snack('The organiser has turned off mics for attendees'); return; } mic = !mic; lk.localParticipant?.setMicrophoneEnabled(mic); setState(() {}); }, off: !mic),
          if (!attendee) _btn(cam ? Icons.videocam : Icons.videocam_off, cam ? 'Stop video' : 'Start video', () { if (!cam && !optAllowCamera(room, me)) { _snack('The organiser has turned off cameras for attendees'); return; } cam = !cam; lk.localParticipant?.setCameraEnabled(cam); setState(() {}); }, off: !cam),
          if (!attendee) _btn(Icons.screen_share, sharing ? 'Stop sharing' : 'Share screen', () { sharing = !sharing; lk.localParticipant?.setScreenShareEnabled(sharing); Availability.instance.activity(sharing ? 'presenting' : (widget.meeting ? 'meeting' : 'call')); setState(() {}); }, off: sharing),
          _btn(Icons.back_hand, myHand ? 'Lower hand' : 'Raise hand', _toggleHand, off: myHand),
          if (optReactions(room)) PopupMenuButton<String>(tooltip: 'React', onSelected: _react, icon: const CircleAvatar(child: Text('😀')),
            itemBuilder: (_) => [for (final e in ['👍', '👏', '❤️', '😂', '😮', '🎉']) PopupMenuItem(value: e, child: Text(e, style: const TextStyle(fontSize: 22)))]),
          if (aiOn) _btn(Icons.question_answer_outlined, 'Ask Amer', () => _askDialog()),
          SizedBox(width: 76, child: Column(mainAxisSize: MainAxisSize.min, children: [
            PopupMenuButton<String>(tooltip: 'More effects', icon: const Icon(Icons.more_horiz),
              style: IconButton.styleFrom(backgroundColor: cs.secondaryContainer),
              onSelected: (v) { switch (v) { case 'cap': _toggleCaptions(); case 'min': setState(() => amerNotes = !amerNotes); case 'blur': _effects(blur: !bgBlur); case 'low': _effects(low: !lowLight); case 'sw': _switchCamera(); } },
              itemBuilder: (_) => [
                CheckedPopupMenuItem(value: 'cap', checked: captions, child: const Text('Captions')),
                CheckedPopupMenuItem(value: 'min', checked: amerNotes, child: const Text('Amer minutes')),
                if (!attendee && cam && AmerBackground.supported) CheckedPopupMenuItem(value: 'blur', checked: bgBlur, child: const Text('Blur background')),
                if (!attendee && cam && AmerBackground.supported) CheckedPopupMenuItem(value: 'low', checked: lowLight, child: const Text('Low light')),
                if (cam && !attendee) const PopupMenuItem(value: 'sw', child: Text('Switch camera')),
              ]),
            ExcludeSemantics(child: Text('More', maxLines: 1, style: Theme.of(context).textTheme.labelSmall)),
          ])),
          ])),
          const Spacer(),
          FilledButton.icon(style: FilledButton.styleFrom(backgroundColor: Colors.red, minimumSize: const Size(110, 48)), onPressed: _leave, icon: const Icon(Icons.call_end), label: Text(L.t(context, 'Leave'))),
        ]))),
      ]),
    ));
  }

  /// Control with a text label under the icon (Teams/Zoom style); tooltip kept for accessibility.
  Widget _btn(IconData i, String tip, VoidCallback f, {bool off = false}) => SizedBox(width: 76, child: Column(mainAxisSize: MainAxisSize.min, children: [
    IconButton.filledTonal(tooltip: tip, onPressed: f,
      style: off ? IconButton.styleFrom(backgroundColor: Theme.of(context).colorScheme.secondaryContainer) : null, icon: Icon(i)),
    ExcludeSemantics(child: Text(tip, maxLines: 1, overflow: TextOverflow.ellipsis, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelSmall))]));   // the tooltip already gives the spoken label

  Widget _tile(Participant p) {
    final vt = p.videoTrackPublications.where((x) => !x.muted).map((x) => x.track).whereType<VideoTrack>().firstOrNull;
    final cs = Theme.of(context).colorScheme;
    return GestureDetector(onLongPress: () => _tileMenu(p), onSecondaryTap: () => _tileMenu(p), child: AnimatedContainer(duration: const Duration(milliseconds: 200),
      decoration: BoxDecoration(color: cs.surfaceContainerHighest, borderRadius: BorderRadius.circular(14),
          border: Border.all(color: p.isSpeaking ? cs.primary : Colors.transparent, width: 3)),
      clipBehavior: Clip.antiAlias,
      child: Stack(fit: StackFit.expand, children: [
        if (vt != null) VideoTrackRenderer(vt) else Center(child: CircleAvatar(radius: 36, child: Text(_initials(p.name.isEmpty ? p.identity : p.name), style: const TextStyle(fontSize: 22)))),
        Positioned(left: 8, bottom: 8, child: Container(padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: cs.surface.withValues(alpha: .85), borderRadius: BorderRadius.circular(8)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            _qualityDot(p), const SizedBox(width: 2),
            if (p is! LocalParticipant) () { final (ic, col, tip) = _idBadge(p); return Tooltip(message: idChecked.contains(p.identity) ? 'Passed a live check in this call' : tip, child: Icon(idChecked.contains(p.identity) ? Icons.how_to_reg : ic, size: 14, color: idChecked.contains(p.identity) ? Colors.green : col, semanticLabel: tip)); }(),
            const SizedBox(width: 4),
            if (p.isMuted) const Icon(Icons.mic_off, size: 14), const SizedBox(width: 4),
            Text(p is LocalParticipant ? 'You' : _hideName(p) ? 'Attendee' : (p.name.isEmpty ? p.identity : p.name)),
            if (spotlightId == p.identity) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.highlight, size: 14)),
            if (pinnedId == p.identity) const Padding(padding: EdgeInsets.only(left: 4), child: Icon(Icons.push_pin, size: 14)),
          ]))),
        Positioned(right: 4, top: 4, child: IconButton(tooltip: 'Participant options', iconSize: 18, visualDensity: VisualDensity.compact,
          style: IconButton.styleFrom(backgroundColor: cs.surface.withValues(alpha: .7)), icon: const Icon(Icons.more_horiz), onPressed: () => _tileMenu(p))),
      ])));
  }
  static String _initials(String n) => n.replaceAll('@', '').split(RegExp(r'[\s:._]')).where((s) => s.isNotEmpty).take(2).map((s) => s[0].toUpperCase()).join();

  Widget _videos(List<Participant> people, bool wide) {
    final focus = people.where((p) => p.identity == (spotlightId ?? pinnedId)).firstOrNull;
    if ((!grid || focus != null) && people.length > 1) {
      final main = focus ?? people.firstWhere((p) => p is! LocalParticipant && p.isSpeaking, orElse: () => people.firstWhere((p) => p is! LocalParticipant, orElse: () => people.first));
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
          trailing: FilledButton(onPressed: () async { await meetings.admit(room, u.id); setState(() {}); }, child: Text(L.t(context, 'Admit'))))],
        for (final p in people) ListTile(leading: CircleAvatar(child: Text(_hideName(p) ? 'A' : _initials(p.name.isEmpty ? p.identity : p.name))),
          title: Text(p is LocalParticipant ? 'You' : _hideName(p) ? 'Attendee' : (p.name.isEmpty ? p.identity : p.name)),
          subtitle: p is LocalParticipant ? null : Text(idChecked.contains(p.identity) ? 'Passed a live check' : _idBadge(p).$3, style: const TextStyle(fontSize: 11)),
          trailing: Row(mainAxisSize: MainAxisSize.min, children: [
            if (p is! LocalParticipant && !p.identity.startsWith('guest-')) IconButton(tooltip: 'Live identity check', icon: const Icon(Icons.shield_outlined, size: 18), onPressed: () => _liveCheck(p)),
            if (hands.contains(p.name)) const Text('✋ '),
            Icon(p.isMuted ? Icons.mic_off : Icons.mic, size: 18), const SizedBox(width: 6),
            Icon(p.isCameraEnabled() ? Icons.videocam : Icons.videocam_off, size: 18),
            if (canModerate && p is! LocalParticipant) PopupMenuButton<String>(onSelected: (a) => a == 'presenter' ? _makePresenter(p.identity) : _host(a, identity: p.identity),
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
      if (!optChat(room, me)) const SafeArea(top: false, child: Padding(padding: EdgeInsets.all(12), child: Text('The organiser has limited the meeting chat.', style: TextStyle(fontSize: 12))))
      else SafeArea(top: false, child: Padding(padding: const EdgeInsets.all(8), child: Row(children: [
        Expanded(child: TextField(controller: chatInput, decoration: const InputDecoration(hintText: 'Message everyone (encrypted)', border: OutlineInputBorder(), isDense: true),
          onSubmitted: (_) => _sendChat())),
        IconButton(icon: const Icon(Icons.send), onPressed: _sendChat)]))),
    ]));
  }
  Future<void> _sendChat() async {
    final t = chatInput.text.trim(); if (t.isEmpty) return; chatInput.clear();
    if (t.toLowerCase().startsWith('/ask')) { final q = t.substring(4).trim(); return _askDialog(q.isEmpty ? null : q); }   // private: never posted
    if (t.toLowerCase().startsWith('/park ')) { await _park(t.substring(6)); return; }
    await room.sendTextEvent(t);
  }
}
