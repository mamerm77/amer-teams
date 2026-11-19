import '../services/hijri.dart';
import '../services/locale.dart';
import 'rooms_screen.dart';
import 'in_person_screen.dart';
import 'focus_screen.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';
import 'call_screen.dart';
import '../services/meeting_service.dart';
import 'find_time_screen.dart';
import '../services/feature_flags.dart';

/// Meetings are encrypted events inside chats. The Scheduler agent turns plain language into a meeting.
class CalendarScreen extends StatefulWidget { const CalendarScreen({super.key}); @override State<CalendarScreen> createState() => _S(); }
class _S extends State<CalendarScreen> {
  Future<List<Meeting>>? f;
  @override void initState() { super.initState(); f = context.read<MatrixService>().meetings(); CalendarPrefs.publish(context.read<MatrixService>(), context.read<ApiService>()).catchError((_) {}); }
  void _reload() => setState(() => f = context.read<MatrixService>().meetings());

  Future<void> _new() async {
    final m = context.read<MatrixService>(); final rooms = m.chats; if (rooms.isEmpty) return;
    final req = TextEditingController(); var room = rooms.first;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
      title: const Text('Schedule with Amer'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButton<String>(isExpanded: true, value: room.id, items: [for (final r in rooms) DropdownMenuItem(value: r.id, child: Text(r.getLocalizedDisplayname()))],
          onChanged: (v) => set(() => room = rooms.firstWhere((r) => r.id == v))),
        TextField(controller: req, decoration: const InputDecoration(hintText: 'e.g. 30 min Ciena review Thursday 11am')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Schedule')))])));
    if (ok != true || req.text.trim().isEmpty) return;
    try {
      final r = await context.read<ApiService>().schedule(req.text.trim());
      final mt = r['meeting'] as Map;
      await m.sendMeeting(room, title: mt['title'], start: DateTime.parse(mt['start']), minutes: (mt['duration_min'] as num).toInt());
      _reload();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not schedule: $e'))); }
  }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(L.t(context, 'Calendar')), actions: [
      if (Flags.instance.on('find_time')) TextButton.icon(icon: const Icon(Icons.manage_search), label: Text(L.t(context, 'Find a time')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const FindTimeScreen()))),
      TextButton.icon(icon: const Icon(Icons.meeting_room_outlined), label: Text(L.t(context, 'Rooms')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const RoomsScreen()))),
      TextButton.icon(icon: const Icon(Icons.record_voice_over), label: Text(L.t(context, 'In-person notes')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const InPersonScreen()))),
      TextButton.icon(icon: const Icon(Icons.headphones), label: Text(L.t(context, 'Focus')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const FocusScreen()))),
      IconButton(tooltip: 'Out of office', icon: const Icon(Icons.beach_access_outlined), onPressed: () => showOutOfOffice(c)),
      IconButton(tooltip: 'Working hours and prayer times', icon: const Icon(Icons.schedule), onPressed: () => showCalendarSettings(c)),
      IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)]),
    floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.auto_awesome), label: Text(L.t(context, 'Schedule with Amer')), onPressed: _new),
    body: FutureBuilder<List<Meeting>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      final up = s.data!.where((m) => m.start.add(Duration(minutes: m.minutes)).isAfter(DateTime.now())).toList();
      final ar = Localizations.localeOf(c).languageCode == 'ar';
      final today = ListTile(dense: true, leading: const Icon(Icons.nights_stay_outlined), title: Text(Hijri.of(DateTime.now()).format(arabic: ar)), subtitle: Text(DateFormat('EEEE d MMMM y').format(DateTime.now())));
      if (up.isEmpty) return ListView(children: [today, const Center(child: Text('No upcoming meetings.'))]);
      return ListView(children: [today, for (final m in up) ListTile(
        leading: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(DateFormat('EEE').format(m.start)), Text(DateFormat('d MMM').format(m.start), style: Theme.of(c).textTheme.labelSmall), Text('${Hijri.of(m.start).day} ${(ar ? Hijri.monthsAr : Hijri.monthsEn)[Hijri.of(m.start).month - 1]}', style: const TextStyle(fontSize: 9))]),
        title: Text(m.title), subtitle: Text('${DateFormat('HH:mm').format(m.start)} · ${m.minutes} min · ${m.room.getLocalizedDisplayname()}'),
        trailing: FilledButton.tonal(child: Text(L.t(context, 'Join')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: m.room.id,
          meeting: MeetingService(context.read<MatrixService>()).meetingIdOf(m.room) != null)))))]);
    }));
}
