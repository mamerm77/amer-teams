import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';
import 'package:livekit_client/livekit_client.dart' hide Room;
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/call_service.dart';

/// Frontline shifts for a team chat (docs/FRONTLINE.md).
class ShiftsScreen extends StatefulWidget {
  const ShiftsScreen({super.key, required this.room});
  final Room room;
  @override State<ShiftsScreen> createState() => _Shifts();
}
class _Shifts extends State<ShiftsScreen> {
  List<dynamic>? rows; String? err;
  bool get manager => widget.room.getPowerLevelByUserId(widget.room.client.userID!).level >= 50;
  String get me => widget.room.client.userID!;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try { final r = await context.read<ApiService>().listGet('/v1/shifts?room_id=${Uri.encodeQueryComponent(widget.room.id)}'); if (mounted) setState(() { rows = r; err = null; }); }
    catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Future<void> _do(Future Function() f) async { try { await f(); } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); } _load(); }
  String _name(String id) => widget.room.unsafeGetUserFromMemoryOrFallback(id).calcDisplayname();
  String _t(String iso) { final d = DateTime.parse(iso).toLocal(); return '${['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'][d.weekday - 1]} ${d.day}/${d.month} ${d.hour.toString().padLeft(2, '0')}:${d.minute.toString().padLeft(2, '0')}'; }

  Future<void> _add() async {
    final people = widget.room.getParticipants().where((u) => u.membership == Membership.join).toList();
    String who = me; DateTime day = DateTime.now(); TimeOfDay from = const TimeOfDay(hour: 7, minute: 0), to = const TimeOfDay(hour: 15, minute: 0); final role = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('New shift'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      DropdownButtonFormField<String>(value: who, isExpanded: true, decoration: const InputDecoration(labelText: 'Who'), items: [for (final u in people) DropdownMenuItem(value: u.id, child: Text(u.calcDisplayname()))], onChanged: (v) => set(() => who = v!)),
      ListTile(contentPadding: EdgeInsets.zero, title: Text('${day.day}/${day.month}/${day.year}'), trailing: const Icon(Icons.calendar_today), onTap: () async { final v = await showDatePicker(context: d, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 120)), initialDate: day); if (v != null) set(() => day = v); }),
      Row(children: [
        Expanded(child: TextButton(onPressed: () async { final v = await showTimePicker(context: d, initialTime: from); if (v != null) set(() => from = v); }, child: Text('From ${from.format(d)}'))),
        Expanded(child: TextButton(onPressed: () async { final v = await showTimePicker(context: d, initialTime: to); if (v != null) set(() => to = v); }, child: Text('To ${to.format(d)}'))),
      ]),
      TextField(controller: role, decoration: const InputDecoration(labelText: 'Role or site (optional)')),
    ]), actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Publish'))])));
    if (ok != true || !mounted) return;
    final s = DateTime(day.year, day.month, day.day, from.hour, from.minute); var e = DateTime(day.year, day.month, day.day, to.hour, to.minute);
    if (!e.isAfter(s)) e = e.add(const Duration(days: 1));                              // night shift past midnight
    await _do(() => context.read<ApiService>().postMap('/v1/shifts', {'room_id': widget.room.id, 'user_id': who, 'start': s.toUtc().toIso8601String(), 'end': e.toUtc().toIso8601String(), 'role': role.text}));
  }

  @override
  Widget build(BuildContext c) {
    final api = context.read<ApiService>();
    return Scaffold(appBar: AppBar(title: Text('Shifts · ${widget.room.getLocalizedDisplayname()}')),
      floatingActionButton: manager ? FloatingActionButton.extended(onPressed: _add, icon: const Icon(Icons.add), label: const Text('Shift')) : null,
      body: err != null ? Center(child: Text(err!)) : rows == null ? const Center(child: CircularProgressIndicator()) : RefreshIndicator(onRefresh: _load, child: ListView(children: [
        if (rows!.isEmpty) const ListTile(title: Text('No shifts this week'), subtitle: Text('Team managers (chat hosts) publish shifts.')),
        for (final s in rows!) () {
          final mine = s['user_id'] == me;
          return ListTile(
            leading: Icon(s['clock_out'] != null ? Icons.check_circle : s['clock_in'] != null ? Icons.timelapse : Icons.schedule, color: mine ? Theme.of(c).colorScheme.primary : null),
            title: Text('${_t(s['start'])} – ${_t(s['end']).split(' ').last}  ${_name(s['user_id'])}${mine ? ' (you)' : ''}'),
            subtitle: Text([if ('${s['role']}'.isNotEmpty) s['role'], if (s['clock_in'] != null) 'in ${_t(s['clock_in']).split(' ').last}', if (s['clock_out'] != null) 'out ${_t(s['clock_out']).split(' ').last}',
              if (s['swap_state'] == 'offered') 'offered for swap', if (s['swap_state'] == 'claimed') 'claimed by ${_name(s['swap_to'])}, waiting for a manager'].join(' · ')),
            trailing: Wrap(spacing: 4, children: [
              if (mine && s['clock_in'] == null) TextButton(onPressed: () => _do(() => api.postMap('/v1/shifts/${s['id']}/clock', {'action': 'in'})), child: const Text('Clock in')),
              if (mine && s['clock_in'] != null && s['clock_out'] == null) TextButton(onPressed: () => _do(() => api.postMap('/v1/shifts/${s['id']}/clock', {'action': 'out'})), child: const Text('Clock out')),
              if (mine && s['clock_in'] == null && s['swap_state'] == 'none') IconButton(tooltip: 'Offer for swap', icon: const Icon(Icons.swap_horiz), onPressed: () => _do(() => api.postMap('/v1/shifts/${s['id']}/offer', {}))),
              if (!mine && s['swap_state'] == 'offered') FilledButton.tonal(onPressed: () => _do(() => api.postMap('/v1/shifts/${s['id']}/claim', {})), child: const Text('Take it')),
              if (manager && s['swap_state'] == 'claimed') ...[
                IconButton(tooltip: 'Approve swap', icon: const Icon(Icons.check), onPressed: () => _do(() => api.postMap('/v1/shifts/${s['id']}/decide', {'approve': true}))),
                IconButton(tooltip: 'Decline swap', icon: const Icon(Icons.close), onPressed: () => _do(() => api.postMap('/v1/shifts/${s['id']}/decide', {'approve': false})))],
            ]));
        }(),
      ])));
  }
}

/// Walkie-talkie (docs/FRONTLINE.md): push to talk in a team chat, end-to-end encrypted like any call. One person
/// talks at a time: pressing asks for the floor over the data channel; if someone else holds it you hear a busy tone
/// message instead. Audio only; it stays connected with the microphone off until you press.
class WalkieTalkieScreen extends StatefulWidget {
  const WalkieTalkieScreen({super.key, required this.room});
  final Room room;
  @override State<WalkieTalkieScreen> createState() => _Ptt();
}
class _Ptt extends State<WalkieTalkieScreen> {
  SecureCall? call; String? err; String? talker; bool talking = false; Timer? _stale; EventsListener<RoomEvent>? ev; final log = <String>[];
  @override void initState() { super.initState(); _join(); }
  @override void dispose() { _release(); ev?.dispose(); call?.leave(sendEnd: false); _stale?.cancel(); super.dispose(); }
  Future<void> _join() async {
    try {
      final c = await SecureCall.joinOrStart(context.read<ApiService>(), widget.room, 'meet-ptt-${widget.room.id}', video: false);
      await c.lk.localParticipant?.setMicrophoneEnabled(false);
      ev = c.lk.createListener()..on<DataReceivedEvent>(_onData)..on<ParticipantConnectedEvent>((_) { if (mounted) setState(() {}); })..on<ParticipantDisconnectedEvent>((_) { if (mounted) setState(() {}); });
      if (mounted) setState(() => call = c);
    } catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  void _onData(DataReceivedEvent e) {
    if (e.topic != 'ptt') return;
    final j = jsonDecode(utf8.decode(e.data)); final who = e.participant?.name ?? 'Someone';
    if (j['t'] == 'floor') { setState(() { talker = who; log.insert(0, '${TimeOfDay.now().format(context)}  $who'); if (log.length > 30) log.removeLast(); });
      SemanticsService.announce('$who is talking', TextDirection.ltr); _stale?.cancel(); _stale = Timer(const Duration(seconds: 65), () => setState(() => talker = null)); }
    if (j['t'] == 'release' && talker == who) setState(() => talker = null);
  }
  Future<void> _send(Map m) => call!.lk.localParticipant!.publishData(utf8.encode(jsonEncode(m)), reliable: true, topic: 'ptt');
  Future<void> _press() async {
    if (call == null || talking) return;
    if (talker != null) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(seconds: 1), content: Text('$talker is talking'))); return; }
    talking = true; setState(() {});
    await _send({'t': 'floor'}); await call!.lk.localParticipant?.setMicrophoneEnabled(true);
    _stale?.cancel(); _stale = Timer(const Duration(seconds: 60), _release);                // nobody holds the floor for more than a minute
  }
  Future<void> _release() async {
    if (!talking) return; talking = false;
    try { await call?.lk.localParticipant?.setMicrophoneEnabled(false); await _send({'t': 'release'}); } catch (_) {}
    if (mounted) setState(() {});
  }
  @override
  Widget build(BuildContext c) {
    final n = (call?.lk.remoteParticipants.length ?? 0) + (call == null ? 0 : 1);
    return Scaffold(appBar: AppBar(title: Text('Walkie-talkie · ${widget.room.getLocalizedDisplayname()}')), body: err != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(err!)))
      : call == null ? const Center(child: CircularProgressIndicator()) : Column(children: [
        ListTile(leading: const Icon(Icons.lock), title: Text('$n on the channel · end-to-end encrypted'), subtitle: Text(talking ? 'You are talking' : talker != null ? '$talker is talking' : 'Channel clear')),
        Expanded(child: Center(child: Semantics(button: true, label: 'Hold to talk', child: GestureDetector(
          onTapDown: (_) => _press(), onTapUp: (_) => _release(), onTapCancel: _release,
          child: AnimatedContainer(duration: const Duration(milliseconds: 120), width: 220, height: 220,
            decoration: BoxDecoration(shape: BoxShape.circle, color: talking ? Colors.red : talker != null ? Colors.grey : Theme.of(c).colorScheme.primary),
            child: Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(talking ? Icons.mic : Icons.mic_none, size: 64, color: Colors.white),
              Text(talking ? 'Release to stop' : 'Hold to talk', style: const TextStyle(color: Colors.white, fontSize: 18))]))))))),
        SizedBox(height: 140, child: ListView(children: [for (final l in log) ListTile(dense: true, title: Text(l))])),
      ]));
  }
}
