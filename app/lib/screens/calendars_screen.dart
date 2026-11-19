import '../services/locale.dart';
import 'package:flutter/material.dart';
import '../services/calendar_connector.dart';

/// Connected calendars (docs/CONNECTORS.md).
class CalendarsScreen extends StatefulWidget {
  const CalendarsScreen({super.key});
  @override State<CalendarsScreen> createState() => _S();
}
class _S extends State<CalendarsScreen> {
  final cc = CalendarConnector.instance; bool busy = false;
  @override void initState() { super.initState(); cc.load().then((_) { if (mounted) setState(() {}); }); }
  Future<void> _add() async {
    final name = TextEditingController(), url = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Connect a calendar'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        const Text('Paste your calendar\'s iCal address.\nOutlook: Settings → Calendar → Shared calendars → Publish → ICS.\nGoogle: Settings → your calendar → Secret address in iCal format.\nThe address stays on this device; only busy times are shared.'),
        TextField(controller: name, decoration: const InputDecoration(labelText: 'Name, e.g. Work Outlook')),
        TextField(controller: url, decoration: const InputDecoration(labelText: 'https://… or webcal://…')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(context, 'Connect')))]));
    if (ok != true) return;
    setState(() => busy = true);
    try { final e = await cc.add(name.text, url.text); if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(e == null ? 'Connected' : 'Saved, but it could not be read: $e'))); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('FormatException: ', '')))); }
    if (mounted) setState(() => busy = false);
  }
  @override
  Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(L.t(context, 'Connected calendars')), actions: [IconButton(tooltip: 'Sync now', icon: const Icon(Icons.sync), onPressed: busy ? null : () async { setState(() => busy = true); await cc.sync(); if (mounted) setState(() => busy = false); })]),
    floatingActionButton: FloatingActionButton.extended(onPressed: busy ? null : _add, icon: const Icon(Icons.add), label: Text(L.t(context, 'Connect calendar'))),
    body: ListView(children: [
      if (busy) const LinearProgressIndicator(),
      if (cc.feeds.isEmpty) const ListTile(title: Text('No calendars connected'), subtitle: Text('Connect Outlook, Google or any iCal calendar: find-a-time uses your busy times, and "out of office" or leave events set your status.')),
      for (final f in cc.feeds) ListTile(leading: Icon(f['error'] != null ? Icons.error_outline : Icons.event_available),
        title: Text('${f['name']}'),
        subtitle: Text(f['error'] != null ? 'Could not sync: ${f['error']}' : f['last_sync'] != null ? '${f['events']} events in the next 45 days · synced ${'${f['last_sync']}'.substring(11, 16)}' : 'Not synced yet'),
        trailing: IconButton(tooltip: 'Disconnect', icon: const Icon(Icons.link_off), onPressed: () async { await cc.remove(f['url']); setState(() {}); })),
      if (cc.events.isNotEmpty) const ListTile(dense: true, title: Text('Coming up (only on this device)')),
      for (final e in cc.events.where((e) => e.end.isAfter(DateTime.now())).take(15)) ListTile(dense: true,
        leading: Icon(e.oof ? Icons.flight_takeoff : Icons.event), title: Text(e.summary.isEmpty ? '(no title)' : e.summary),
        subtitle: Text(e.allDay ? '${e.start.toLocal().toString().substring(0, 10)} · all day' : '${e.start.toLocal().toString().substring(0, 16)} – ${e.end.toLocal().toString().substring(11, 16)}${e.busy ? '' : ' · free'}')),
    ]));
}
