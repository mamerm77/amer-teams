import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';

/// Working hours, time zone and prayer/Ramadan settings, kept on this device and published with free/busy.
class CalendarPrefs {
  static const cities = {'Abu Dhabi': (24.4539, 54.3773), 'Dubai': (25.2048, 55.2708), 'Sharjah': (25.3463, 55.4209), 'Al Ain': (24.2075, 55.7447),
    'Riyadh': (24.7136, 46.6753), 'Jeddah': (21.4858, 39.1925), 'Doha': (25.2854, 51.5310), 'Kuwait': (29.3759, 47.9774), 'Muscat': (23.5880, 58.3829),
    'Manama': (26.2235, 50.5876), 'Cairo': (30.0444, 31.2357)};
  Map<String, dynamic> v = {'days': [0, 1, 2, 3, 4], 'start': '08:00', 'end': '17:00', 'city': null, 'method': 'mwl', 'ramadan': false};
  static Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/calendar_prefs.json');
  static Future<CalendarPrefs> load() async {
    final p = CalendarPrefs();
    try { final f = await _f(); if (await f.exists()) p.v = {...p.v, ...jsonDecode(await f.readAsString()) as Map<String, dynamic>}; } catch (_) {}
    return p;
  }
  Future<void> save() async { try { await (await _f()).writeAsString(jsonEncode(v)); } catch (_) {} }

  /// Publishes free/busy: start and end of each meeting only, never titles or chats.
  static Future<void> publish(MatrixService m, ApiService api) async {
    final p = await load();
    final ms = await m.meetings();
    final now = DateTime.now();
    final busy = [for (final x in ms.where((x) => x.start.add(Duration(minutes: x.minutes)).isAfter(now) && x.start.isBefore(now.add(const Duration(days: 45)))))
      {'start': x.start.toUtc().toIso8601String(), 'end': x.start.add(Duration(minutes: x.minutes)).toUtc().toIso8601String()}];
    final city = p.v['city'] as String?; final ll = city == null ? null : cities[city];
    await api.putFreeBusy({'busy': busy, 'tz': await _tz(), 'work': {'days': p.v['days'], 'start': p.v['start'], 'end': p.v['end']},
        'prayer': ll == null ? null : {'lat': ll.$1, 'lon': ll.$2, 'method': p.v['method']}, 'ramadan_hours': p.v['ramadan'] == true});
  }
  /// The device's IANA zone name when known; Gulf offsets map to their zone, otherwise UTC±hh via Etc/GMT.
  static Future<String> _tz() async {
    final o = DateTime.now().timeZoneOffset.inMinutes;
    const byOffset = {240: 'Asia/Dubai', 180: 'Asia/Riyadh', 120: 'Africa/Cairo', 0: 'UTC', 330: 'Asia/Kolkata', 60: 'Europe/London'};
    if (byOffset.containsKey(o)) return byOffset[o]!;
    return o % 60 == 0 ? 'Etc/GMT${o > 0 ? '-' : '+'}${(o.abs() ~/ 60)}' : 'UTC';
  }
}

/// Find a time: pick people, a duration and the next days; Amer proposes the 3 best slots everyone is free.
class FindTimeScreen extends StatefulWidget {
  const FindTimeScreen({super.key, this.room});
  final Room? room;
  @override State<FindTimeScreen> createState() => _S();
}

class _S extends State<FindTimeScreen> {
  Room? room; int minutes = 30, days = 5; List<dynamic>? slots; List<dynamic> missing = []; String? err; bool busy = false;
  final title = TextEditingController(text: 'Meeting');
  @override void initState() { super.initState(); room = widget.room; }
  List<String> get people => room == null ? [] : room!.getParticipants().where((u) => u.membership == Membership.join && u.id != room!.client.userID && !u.id.startsWith('@amer')).map((u) => u.id).toList();

  Future<void> _find() async {
    if (room == null) return;
    setState(() { busy = true; err = null; slots = null; });
    try {
      final m = context.read<MatrixService>(), api = context.read<ApiService>();
      await CalendarPrefs.publish(m, api);
      final r = await api.findTime(people, minutes, DateTime.now().add(const Duration(minutes: 30)), DateTime.now().add(Duration(days: days)));
      slots = r['slots'] as List; missing = r['no_calendar'] as List;
    } catch (e) { err = '$e'.replaceFirst('Exception: ', ''); }
    if (mounted) setState(() => busy = false);
  }
  Future<void> _book(Map s) async {
    final st = DateTime.parse('${s['start']}').toLocal();
    await context.read<MatrixService>().sendMeeting(room!, title: title.text.trim().isEmpty ? 'Meeting' : title.text.trim(), start: st, minutes: minutes);
    if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Booked ${DateFormat('EEE d MMM HH:mm').format(st)} in ${room!.getLocalizedDisplayname()}'))); Navigator.pop(context); }
  }

  @override Widget build(BuildContext c) {
    final rooms = context.read<MatrixService>().client.rooms.where((r) => r.membership == Membership.join && !r.isSpace).toList();
    return Scaffold(appBar: AppBar(title: const Text('Find a time')), body: ListView(padding: const EdgeInsets.all(16), children: [
      DropdownButtonFormField<String>(value: room?.id, decoration: const InputDecoration(labelText: 'With the members of'),
        items: [for (final r in rooms) DropdownMenuItem(value: r.id, child: Text(r.getLocalizedDisplayname(), overflow: TextOverflow.ellipsis))],
        onChanged: (v) => setState(() { room = rooms.firstWhere((r) => r.id == v); slots = null; })),
      const SizedBox(height: 8),
      TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')),
      const SizedBox(height: 8),
      Row(children: [const Text('Duration'), const SizedBox(width: 12), SegmentedButton<int>(segments: const [ButtonSegment(value: 15, label: Text('15')), ButtonSegment(value: 30, label: Text('30')),
          ButtonSegment(value: 60, label: Text('60')), ButtonSegment(value: 90, label: Text('90'))], selected: {minutes}, onSelectionChanged: (v) => setState(() => minutes = v.first)), const Text(' min')]),
      const SizedBox(height: 8),
      Row(children: [const Text('Within'), const SizedBox(width: 12), DropdownButton<int>(value: days, items: const [DropdownMenuItem(value: 2, child: Text('2 days')), DropdownMenuItem(value: 5, child: Text('5 days')),
          DropdownMenuItem(value: 10, child: Text('10 days')), DropdownMenuItem(value: 30, child: Text('30 days'))], onChanged: (v) => setState(() => days = v!))]),
      const SizedBox(height: 12),
      FilledButton.icon(onPressed: room == null || busy ? null : _find, icon: const Icon(Icons.manage_search), label: const Text('Find the best times')),
      if (busy) const Padding(padding: EdgeInsets.only(top: 12), child: LinearProgressIndicator()),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
      if (slots != null) ...[
        const SizedBox(height: 16),
        Text(slots!.isEmpty ? 'No time when everyone is free in this window' : 'Everyone is free at:', style: Theme.of(c).textTheme.titleSmall),
        for (final s in slots!) Card(child: ListTile(leading: const Icon(Icons.event_available),
          title: Text(DateFormat('EEEE d MMM, HH:mm').format(DateTime.parse('${s['start']}').toLocal())), subtitle: Text('$minutes min · your time'),
          trailing: FilledButton(onPressed: () => _book(s as Map), child: const Text('Book')))),
        if (missing.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(
          'Not checked (they have not opened Amer Teams\' calendar yet): ${missing.map((u) => room!.unsafeGetUserFromMemoryOrFallback('$u').calcDisplayname()).join(', ')}',
          style: TextStyle(fontSize: 12, color: Theme.of(c).colorScheme.outline))),
      ],
      const SizedBox(height: 16),
      Text('Only busy times are shared, never meeting titles or chats. Working hours, prayer times and Ramadan hours come from each person\'s calendar settings.',
          style: TextStyle(fontSize: 12, color: Theme.of(c).colorScheme.outline)),
    ]));
  }
}

/// Calendar settings: working days and hours, prayer times (city and method), Ramadan hours.
Future<void> showCalendarSettings(BuildContext context) async {
  final p = await CalendarPrefs.load();
  if (!context.mounted) return;
  const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
  await showDialog(context: context, builder: (d) => StatefulBuilder(builder: (d, set) {
    final days = (p.v['days'] as List).cast<int>().toSet();
    return AlertDialog(title: const Text('Working hours and prayer times'), content: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Wrap(spacing: 4, children: [for (var i = 0; i < 7; i++) FilterChip(label: Text(names[i]), selected: days.contains(i),
        onSelected: (v) => set(() { v ? days.add(i) : days.remove(i); p.v['days'] = days.toList()..sort(); }))]),
      Row(children: [
        TextButton(onPressed: () async { final t = await showTimePicker(context: d, initialTime: TimeOfDay(hour: int.parse('${p.v['start']}'.split(':')[0]), minute: 0));
          if (t != null) set(() => p.v['start'] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'); }, child: Text('From ${p.v['start']}')),
        TextButton(onPressed: () async { final t = await showTimePicker(context: d, initialTime: TimeOfDay(hour: int.parse('${p.v['end']}'.split(':')[0]), minute: 0));
          if (t != null) set(() => p.v['end'] = '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'); }, child: Text('To ${p.v['end']}')),
      ]),
      DropdownButtonFormField<String?>(value: p.v['city'] as String?, decoration: const InputDecoration(labelText: 'Keep prayer times free (city)'),
        items: [const DropdownMenuItem(value: null, child: Text('Off')), for (final c in CalendarPrefs.cities.keys) DropdownMenuItem(value: c, child: Text(c))],
        onChanged: (v) => set(() => p.v['city'] = v)),
      if (p.v['city'] != null) DropdownButtonFormField<String>(value: p.v['method'] as String, decoration: const InputDecoration(labelText: 'Calculation method'),
        items: const [DropdownMenuItem(value: 'mwl', child: Text('Muslim World League')), DropdownMenuItem(value: 'uae', child: Text('UAE (18.2°)')),
          DropdownMenuItem(value: 'umm_al_qura', child: Text('Umm al-Qura')), DropdownMenuItem(value: 'egypt', child: Text('Egyptian authority'))], onChanged: (v) => set(() => p.v['method'] = v)),
      SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Ramadan working hours'), subtitle: const Text('Two hours shorter working day in Ramadan'),
        value: p.v['ramadan'] == true, onChanged: (v) => set(() => p.v['ramadan'] = v)),
    ])), actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () async { await p.save(); if (d.mounted) Navigator.pop(d); }, child: const Text('Save'))]);
  }));
  if (context.mounted) await CalendarPrefs.publish(context.read<MatrixService>(), context.read<ApiService>()).catchError((_) {});
}
