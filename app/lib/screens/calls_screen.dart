import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/call_manager.dart';
import '../services/matrix_service.dart';
import '../services/meeting_service.dart';
import 'call_screen.dart';
import 'chat_screen.dart';
import 'people_picker.dart';
import 'phone_screen.dart';

/// Calls hub: new call, meet now, join by ID, schedule, phone, and call history.
class CallsScreen extends StatefulWidget { const CallsScreen({super.key}); @override State<CallsScreen> createState() => _S(); }
class _S extends State<CallsScreen> {
  Future<List<CallRecord>>? hist;
  @override void initState() { super.initState(); _load(); }
  void _load() => setState(() { hist = context.read<CallManager>().history(); });
  MatrixService get m => context.read<MatrixService>();
  MeetingService get meet => MeetingService(m);
  void _err(Object e) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', ''))));

  Future<void> _newCall() async {
    final who = await pickPeople(context, title: 'Call someone'); if (who == null || who.isEmpty || !mounted) return;
    final video = await showModalBottomSheet<bool>(context: context, builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
      ListTile(leading: const Icon(Icons.call), title: Text('Voice call ${who.first.displayName ?? who.first.userId}'), onTap: () => Navigator.pop(s, false)),
      ListTile(leading: const Icon(Icons.videocam), title: Text('Video call ${who.first.displayName ?? who.first.userId}'), onTap: () => Navigator.pop(s, true))])));
    if (video == null || !mounted) return;
    try {
      final roomId = await m.createRoom(name: '', invite: [who.first.userId], direct: true);
      await m.client.waitForRoomInSync(roomId, join: true).timeout(const Duration(seconds: 10), onTimeout: () => throw Exception('Chat not ready'));
      if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(roomId: roomId, video: video)));
      _load();
    } catch (e) { _err(e); }
  }

  bool _creating = false;
  Future<void> _meetNow() async {
    if (_creating) return; _creating = true;
    showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [
      CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('Creating an encrypted meeting…'))])));
    try {
      final (String, String) r;
      try { r = await meet.create('').timeout(const Duration(seconds: 45)); }
      finally { if (mounted) Navigator.of(context, rootNavigator: true).pop(); _creating = false; }
      final (roomId, id) = r;
      if (!mounted) return;
      await showDialog(context: context, builder: (d) => AlertDialog(title: const Text('Meeting ready'),
        content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Share this meeting ID. People who join wait in the waiting room until you admit them.'),
          const SizedBox(height: 12), SelectableText(MeetingService.format(id), style: Theme.of(context).textTheme.headlineSmall)]),
        actions: [FilledButton(onPressed: () => Navigator.pop(d), child: const Text('Start meeting'))]));
      if (mounted) await Navigator.push(context, MaterialPageRoute(builder: (_) => CallScreen(roomId: roomId, meeting: true)));
    } catch (e) { _err(e); }
  }

  Future<void> _join() async {
    final ctl = TextEditingController(); var video = true;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Join a meeting'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: ctl, autofocus: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Meeting ID', hintText: '123 456 789')),
        SwitchListTile(contentPadding: EdgeInsets.zero, value: video, onChanged: (v) => set(() => video = v), title: const Text('Join with video'))]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Join'))])));
    if (ok != true || !mounted) return;
    final nav = Navigator.of(context);
    showDialog(context: context, barrierDismissible: false, builder: (_) => const AlertDialog(content: Row(children: [
      CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('Waiting for the host to let you in…'))])));
    try {
      final roomId = await meet.joinById(ctl.text);
      nav.pop();
      await nav.push(MaterialPageRoute(builder: (_) => CallScreen(roomId: roomId, meeting: true, video: video)));
    } catch (e) { nav.pop(); _err(e); }
  }

  Future<void> _schedule() async {
    final title = TextEditingController(); var date = DateTime.now().add(const Duration(hours: 1)); var minutes = 30; var invite = <String, String>{}; var repeat = 'none';
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Schedule a meeting'),
      content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
        ListTile(contentPadding: EdgeInsets.zero, leading: const Icon(Icons.event), title: Text(DateFormat('EEE d MMM yyyy, HH:mm').format(date)), onTap: () async {
          final dd = await showDatePicker(context: d, initialDate: date, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 365)));
          if (dd == null || !d.mounted) return;
          final tt = await showTimePicker(context: d, initialTime: TimeOfDay.fromDateTime(date));
          if (tt != null) set(() => date = DateTime(dd.year, dd.month, dd.day, tt.hour, tt.minute));
        }),
        DropdownButtonFormField<int>(value: minutes, decoration: const InputDecoration(labelText: 'Duration'),
          items: [for (final v in [15, 30, 45, 60, 90, 120]) DropdownMenuItem(value: v, child: Text('$v minutes'))], onChanged: (v) => set(() => minutes = v!)),
        DropdownButtonFormField<String>(value: repeat, decoration: const InputDecoration(labelText: 'Repeats'),
          items: const [DropdownMenuItem(value: 'none', child: Text('Does not repeat')), DropdownMenuItem(value: 'daily', child: Text('Every day')),
            DropdownMenuItem(value: 'weekly', child: Text('Every week')), DropdownMenuItem(value: 'monthly', child: Text('Every month'))],
          onChanged: (v) => set(() => repeat = v!)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, children: [for (final e in invite.entries) Chip(label: Text(e.value), onDeleted: () => set(() => invite.remove(e.key)))]),
        TextButton.icon(icon: const Icon(Icons.person_add), label: const Text('Add people'), onPressed: () async {
          final p = await pickPeople(d, multiple: true, title: 'Invite to meeting');
          if (p != null) set(() { for (final x in p) { invite[x.userId] = x.displayName ?? x.userId; } });
        }),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Schedule'))])));
    if (ok != true) return;
    try {
      final (_, id) = await meet.create(title.text.trim().isEmpty ? 'Meeting' : title.text.trim(), invite: invite.keys.toList(), start: date, minutes: minutes, recurrence: repeat);
      _err('Scheduled. Invites sent. Meeting ID ${MeetingService.format(id)} — it is in your Calendar.');
    } catch (e) { _err(e); }
  }

  Widget _action(IconData i, String label, VoidCallback f) => SizedBox(width: 96, child: InkWell(borderRadius: BorderRadius.circular(12), onTap: f,
    child: Padding(padding: const EdgeInsets.symmetric(vertical: 4), child: Column(children: [
      IconButton.filledTonal(tooltip: label, iconSize: 28, style: IconButton.styleFrom(minimumSize: const Size(60, 60)), onPressed: f, icon: Icon(i)),
      const SizedBox(height: 4), Text(label, textAlign: TextAlign.center, style: Theme.of(context).textTheme.labelMedium)]))));

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Calls & meetings'), actions: [IconButton(icon: const Icon(Icons.refresh), onPressed: _load)]),
    body: ListView(children: [
      Padding(padding: const EdgeInsets.symmetric(vertical: 16), child: Wrap(alignment: WrapAlignment.spaceEvenly, runSpacing: 12, children: [
        _action(Icons.add_call, 'New call', _newCall),
        _action(Icons.video_call, 'Meet now', _meetNow),
        _action(Icons.login, 'Join with ID', _join),
        _action(Icons.edit_calendar, 'Schedule', _schedule),
        _action(Icons.dialpad, 'Phone', () => Navigator.push(c, MaterialPageRoute(builder: (_) => const PhoneScreen()))),
      ])),
      const Divider(height: 1),
      Padding(padding: const EdgeInsets.fromLTRB(16, 12, 16, 4), child: Text('Recent', style: Theme.of(c).textTheme.titleSmall)),
      FutureBuilder<List<CallRecord>>(future: hist, builder: (_, s) {
        if (!s.hasData) return const Padding(padding: EdgeInsets.all(24), child: Center(child: CircularProgressIndicator()));
        if (s.data!.isEmpty) return const Padding(padding: EdgeInsets.all(24), child: Text('No calls yet. Start one above.'));
        final cs = Theme.of(c).colorScheme; final now = DateTime.now();
        String day(DateTime t) {
          final d = DateTime(t.year, t.month, t.day), today = DateTime(now.year, now.month, now.day);
          if (d == today) return 'Today';
          if (d == today.subtract(const Duration(days: 1))) return 'Yesterday';
          return DateFormat(now.difference(t).inDays < 7 ? 'EEEE' : 'd MMMM yyyy').format(t);
        }
        String initials(String n) { final p = n.trim().split(RegExp(r'\s+')).where((x) => x.isNotEmpty).toList(); return p.isEmpty ? '?' : (p.first[0] + (p.length > 1 ? p.last[0] : '')).toUpperCase(); }
        final rows = <Widget>[]; String? last;
        for (final r in s.data!) {
          final d = day(r.at);
          if (d != last) { rows.add(Padding(padding: const EdgeInsets.fromLTRB(16, 14, 16, 2), child: Text(d, style: Theme.of(c).textTheme.labelMedium?.copyWith(color: cs.primary)))); last = d; }
          final failedOut = r.outgoing && const {'missed', 'declined', 'busy', 'failed', 'cancelled'}.contains(r.outcome);
          final tone = r.missed ? cs.error : failedOut ? Colors.orange.shade800 : null;
          final label = r.outcome != null ? CallSummary(r.outcome!, r.durationS, r.answered).label(r.outgoing, r.video) : r.missed ? 'Missed' : r.outgoing ? 'Outgoing' : 'Incoming';
          rows.add(ListTile(
            onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: r.room.id))).then((_) => _load()),
            leading: Stack(clipBehavior: Clip.none, children: [
              CircleAvatar(backgroundColor: r.missed ? cs.errorContainer : cs.primaryContainer, child: Text(initials(r.peer), style: TextStyle(color: r.missed ? cs.onErrorContainer : cs.onPrimaryContainer))),
              Positioned(right: -4, bottom: -4, child: CircleAvatar(radius: 10, backgroundColor: cs.surface, child: Icon(r.video ? Icons.videocam : Icons.call, size: 13, color: tone ?? cs.primary)))]),
            title: Text(r.peer, style: TextStyle(color: r.missed ? cs.error : null, fontWeight: r.missed ? FontWeight.w600 : null)),
            subtitle: Row(children: [
              Icon(r.missed ? Icons.call_missed : r.outgoing ? Icons.call_made : Icons.call_received, size: 14, color: tone), const SizedBox(width: 4),
              Flexible(child: Text('$label · ${DateFormat('HH:mm').format(r.at)}', style: TextStyle(color: tone), overflow: TextOverflow.ellipsis))]),
            trailing: IconButton(tooltip: r.video ? 'Video call back' : 'Call back', icon: Icon(r.video ? Icons.videocam_outlined : Icons.call_outlined, color: cs.primary),
              onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: r.room.id, video: r.video))).then((_) => _load()))));
        }
        return Column(crossAxisAlignment: CrossAxisAlignment.start, children: rows);
      }),
    ]));
}
