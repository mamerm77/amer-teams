import '../services/locale.dart';
import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:http/http.dart' as http;
import 'package:path_provider/path_provider.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../services/api_service.dart';

/// Meeting rooms: find and book (docs/ROOMS.md).
class MeetingRoomsScreen extends StatefulWidget {
  const MeetingRoomsScreen({super.key});
  @override State<MeetingRoomsScreen> createState() => _S();
}
class _S extends State<MeetingRoomsScreen> {
  DateTime start = DateTime.now().add(const Duration(minutes: 15)); int minutes = 60, people = 2; List<dynamic>? rooms; String? err;
  @override void initState() { super.initState(); _load(); }
  String _q(DateTime t) => Uri.encodeQueryComponent(t.toUtc().toIso8601String());
  Future<void> _load() async {
    try { final r = await context.read<ApiService>().listGet('/v1/rooms?start=${_q(start)}&end=${_q(start.add(Duration(minutes: minutes)))}&capacity=$people'); if (mounted) setState(() { rooms = r; err = null; }); }
    catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Future<void> _book(Map r) async {
    final title = TextEditingController(); var show = false;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text('Book ${r['name']}'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        Text('${TimeOfDay.fromDateTime(start).format(d)} for $minutes min'),
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Title (optional)')),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Show the title on the room display'), value: show, onChanged: (v) => set(() => show = v)),
        const Text('Check in at the room or here within 10 minutes of the start, or the room is released.', style: TextStyle(fontSize: 12)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Book')))])));
    if (ok != true || !mounted) return;
    try {
      await context.read<ApiService>().postMap('/v1/rooms/bookings', {'room_id': r['id'], 'start': start.toUtc().toIso8601String(), 'end': start.add(Duration(minutes: minutes)).toUtc().toIso8601String(), 'title': title.text, 'show_title': show});
      if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${r['name']} booked')));
      _load();
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); }
  }
  @override
  Widget build(BuildContext c) {
    final me = context.read<ApiService>().me;
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Meeting rooms'))), body: Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
        OutlinedButton.icon(icon: const Icon(Icons.schedule), label: Text('${start.toString().substring(0, 10)} ${TimeOfDay.fromDateTime(start).format(c)}'), onPressed: () async {
          final d = await showDatePicker(context: c, firstDate: DateTime.now(), lastDate: DateTime.now().add(const Duration(days: 90)), initialDate: start);
          if (d == null || !c.mounted) return;
          final t = await showTimePicker(context: c, initialTime: TimeOfDay.fromDateTime(start)); if (t == null) return;
          setState(() => start = DateTime(d.year, d.month, d.day, t.hour, t.minute)); _load(); }),
        DropdownButton<int>(value: minutes, items: [for (final m in [15, 30, 45, 60, 90, 120, 240]) DropdownMenuItem(value: m, child: Text('$m min'))], onChanged: (v) { setState(() => minutes = v!); _load(); }),
        DropdownButton<int>(value: people, items: [for (final p in [1, 2, 4, 6, 8, 12, 20, 50]) DropdownMenuItem(value: p, child: Text('$p+ people'))], onChanged: (v) { setState(() => people = v!); _load(); }),
      ])),
      Expanded(child: err != null ? Center(child: Text(err!)) : rooms == null ? const Center(child: CircularProgressIndicator()) : ListView(children: [
        if (rooms!.isEmpty) const ListTile(title: Text('No rooms that size'), subtitle: Text('An administrator adds rooms (POST /v1/rooms).')),
        for (final r in rooms!) ListTile(
          leading: Icon(r['free'] ? Icons.meeting_room : Icons.no_meeting_room, color: r['free'] ? Colors.green : Colors.orange),
          title: Text('${r['name']} · ${r['capacity']} people'), subtitle: Text([if ('${r['site']}'.isNotEmpty) r['site'], if ((r['equipment'] as List).isNotEmpty) (r['equipment'] as List).join(', '),
            for (final b in r['bookings'] as List) '${b['start'].toString().substring(11, 16)}–${b['end'].toString().substring(11, 16)} UTC ${b['title']}${b['organiser'] == me ? ' (yours)' : ''}'].join('\n')),
          isThreeLine: true,
          trailing: r['free'] ? FilledButton.tonal(onPressed: () => _book(r), child: Text(L.t(context, 'Book'))) : Wrap(children: [
            for (final b in (r['bookings'] as List).where((b) => b['organiser'] == me)) ...[
              IconButton(tooltip: 'Check in', icon: const Icon(Icons.how_to_reg), onPressed: () async { try { await context.read<ApiService>().postMap('/v1/rooms/bookings/${b['id']}/check-in', {}); _load(); } catch (e) { if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); } }),
              IconButton(tooltip: 'Cancel booking', icon: const Icon(Icons.event_busy), onPressed: () async { await context.read<ApiService>().deletePath('/v1/rooms/bookings/${b['id']}'); _load(); }),
            ]])),
      ])),
    ]));
  }
}

/// The room's own tablet (docs/ROOMS.md): paired with a one-time code, no account. Shows free/busy in large type.
class RoomDisplayScreen extends StatefulWidget {
  const RoomDisplayScreen({super.key});
  @override State<RoomDisplayScreen> createState() => _D();
}
class _D extends State<RoomDisplayScreen> {
  String? server, code; Map<String, dynamic>? d; String? err; Timer? t;
  final s = TextEditingController(), k = TextEditingController();
  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/room_display.json');
  @override void initState() { super.initState(); _f().then((f) async { if (await f.exists()) { final j = jsonDecode(await f.readAsString()); setState(() { server = j['server']; code = j['code']; }); _load(); } }); t = Timer.periodic(const Duration(seconds: 30), (_) => _load()); }
  @override void dispose() { t?.cancel(); super.dispose(); }
  Uri _u(String p) => Uri.parse(server!).replace(path: '$kApiPath$p');
  Map<String, String> get _h => {'X-Room-Device': code!, 'Content-Type': 'application/json'};
  Future<void> _load() async {
    if (server == null || code == null) return;
    try { final r = await http.get(_u('/v1/room-device/today'), headers: _h); if (r.statusCode != 200) throw Exception(jsonDecode(r.body)['detail']); if (mounted) setState(() { d = jsonDecode(r.body); err = null; }); }
    catch (e) { if (mounted) setState(() => err = '$e'); }
  }
  Future<void> _post(String p, [Map? body]) async { final r = await http.post(_u(p), headers: _h, body: jsonEncode(body ?? {})); if (r.statusCode >= 300 && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${jsonDecode(r.body)['detail']}'))); _load(); }
  String _hm(String iso) => TimeOfDay.fromDateTime(DateTime.parse(iso).toLocal()).format(context);
  @override
  Widget build(BuildContext c) {
    if (server == null || code == null) {
      return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Set up as a room display'))), body: Padding(padding: const EdgeInsets.all(24), child: Column(children: [
        TextField(controller: s, decoration: const InputDecoration(labelText: 'Server, e.g. https://teams.example.ae')),
        TextField(controller: k, decoration: const InputDecoration(labelText: 'Room code from your administrator')),
        const SizedBox(height: 16),
        FilledButton(onPressed: () async { server = s.text.trim(); code = k.text.trim(); await (await _f()).writeAsString(jsonEncode({'server': server, 'code': code})); setState(() {}); _load(); }, child: Text(L.t(context, 'Pair this display'))),
      ])));
    }
    final x = d; final free = x?['free'] == true; final cur = x?['current'];
    return Scaffold(backgroundColor: free ? const Color(0xFF0B6B2E) : const Color(0xFF8A1220), body: SafeArea(child: Padding(padding: const EdgeInsets.all(32), child: x == null
      ? Center(child: Text(err ?? 'Connecting…', style: const TextStyle(color: Colors.white)))
      : DefaultTextStyle(style: const TextStyle(color: Colors.white), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('${x['room']['name']}', style: const TextStyle(fontSize: 40, fontWeight: FontWeight.bold, color: Colors.white)),
          Text('${x['room']['site']} · ${x['room']['capacity']} people', style: const TextStyle(fontSize: 18, color: Colors.white70)),
          const Spacer(),
          Text(free ? 'Free' : 'In use', style: const TextStyle(fontSize: 72, fontWeight: FontWeight.w300, color: Colors.white)),
          if (cur != null) Text('${cur['title']} until ${_hm(cur['end'])}${cur['checked_in'] ? '' : ' · not checked in'}', style: const TextStyle(fontSize: 22, color: Colors.white)),
          if (x['next'] != null) Text('Next: ${_hm(x['next']['start'])} ${x['next']['title']}', style: const TextStyle(fontSize: 20, color: Colors.white70)),
          const SizedBox(height: 24),
          Wrap(spacing: 12, runSpacing: 12, children: [
            if (cur != null && cur['checked_in'] != true) FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size(180, 64)), onPressed: () => _post('/v1/room-device/check-in/${cur['id']}'), child: const Text('Check in', style: TextStyle(fontSize: 20))),
            if (free) for (final m in [15, 30, 60]) FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.white, foregroundColor: Colors.black, minimumSize: const Size(160, 64)), onPressed: () => _post('/v1/room-device/book-now', {'minutes': m}), child: Text('Book $m min', style: const TextStyle(fontSize: 20))),
          ]),
          const Spacer(),
          for (final i in (x['today'] as List)) Text('${_hm(i['start'])}–${_hm(i['end'])}  ${i['title']}', style: const TextStyle(fontSize: 16, color: Colors.white70)),
        ])))));
  }
}
