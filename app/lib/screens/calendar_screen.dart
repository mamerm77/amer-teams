import 'package:matrix/matrix.dart' show Membership;
import 'chat_screen.dart';
import '../services/hijri.dart';
import '../services/locale.dart';
import 'meeting_rooms_screen.dart';
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
      TextButton.icon(icon: const Icon(Icons.meeting_room_outlined), label: Text(L.t(context, 'Rooms')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const MeetingRoomsScreen()))),
      TextButton.icon(icon: const Icon(Icons.record_voice_over), label: Text(L.t(context, 'In-person notes')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const InPersonScreen()))),
      TextButton.icon(icon: const Icon(Icons.headphones), label: Text(L.t(context, 'Focus')), onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const FocusScreen()))),
      IconButton(tooltip: 'Out of office', icon: const Icon(Icons.beach_access_outlined), onPressed: () => showOutOfOffice(c)),
      IconButton(tooltip: 'Working hours and prayer times', icon: const Icon(Icons.schedule), onPressed: () => showCalendarSettings(c)),
      IconButton(icon: const Icon(Icons.refresh), onPressed: _reload)]),
    floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.auto_awesome), label: Text(L.t(context, 'Schedule with Amer')), onPressed: _new),
    body: FutureBuilder<List<Meeting>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      return Column(children: [_toolbar(c), const Divider(height: 1), Expanded(child: switch (view) {
        CalView.list => _list(c, s.data!),
        CalView.month => _month(c, s.data!),
        _ => _grid(c, s.data!),
      })]);
    }));

  // ---- Teams-style views: Day, Work week, Week, Month, and the upcoming list ----
  CalView view = CalView.workWeek; DateTime anchor = DateTime.now();
  DateTime _d(DateTime t) => DateTime(t.year, t.month, t.day);
  List<DateTime> get _days {
    final a = _d(anchor);
    switch (view) {
      case CalView.day: return [a];
      case CalView.workWeek:                 // UAE working week: Monday to Friday
        final mon = a.subtract(Duration(days: a.weekday - 1)); return [for (var i = 0; i < 5; i++) mon.add(Duration(days: i))];
      default:
        final mon = a.subtract(Duration(days: a.weekday - 1)); return [for (var i = 0; i < 7; i++) mon.add(Duration(days: i))];
    }
  }
  void _step(int dir) => setState(() {
    anchor = switch (view) {
      CalView.day => anchor.add(Duration(days: dir)),
      CalView.month => DateTime(anchor.year, anchor.month + dir, 1),
      CalView.list => anchor,
      _ => anchor.add(Duration(days: 7 * dir)),
    };
  });
  String get _range {
    final d = _days;
    return switch (view) {
      CalView.day => DateFormat('EEEE d MMMM y').format(anchor),
      CalView.month => DateFormat('MMMM y').format(anchor),
      CalView.list => 'Upcoming',
      _ => '${DateFormat('d MMM').format(d.first)} – ${DateFormat('d MMM y').format(d.last)}',
    };
  }

  Widget _toolbar(BuildContext c) => Padding(padding: const EdgeInsets.fromLTRB(12, 8, 12, 8), child: Wrap(crossAxisAlignment: WrapCrossAlignment.center, spacing: 8, runSpacing: 6, children: [
    OutlinedButton(onPressed: () => setState(() => anchor = DateTime.now()), child: Text(L.t(context, 'Today'))),
    IconButton(tooltip: 'Previous', icon: const Icon(Icons.chevron_left), onPressed: () => _step(-1)),
    IconButton(tooltip: 'Next', icon: const Icon(Icons.chevron_right), onPressed: () => _step(1)),
    Text(_range, style: Theme.of(c).textTheme.titleMedium),
    const SizedBox(width: 12),
    SegmentedButton<CalView>(showSelectedIcon: false, segments: const [
      ButtonSegment(value: CalView.day, label: Text('Day')), ButtonSegment(value: CalView.workWeek, label: Text('Work week')),
      ButtonSegment(value: CalView.week, label: Text('Week')), ButtonSegment(value: CalView.month, label: Text('Month')),
      ButtonSegment(value: CalView.list, label: Text('List'))],
      selected: {view}, onSelectionChanged: (v) => setState(() => view = v.first)),
    FilledButton.icon(icon: const Icon(Icons.add), label: Text(L.t(context, 'New meeting')), onPressed: () => _newManual()),
  ]));

  List<Meeting> _on(List<Meeting> all, DateTime day) => all.where((m) => _d(m.start) == day).toList()..sort((a, b) => a.start.compareTo(b.start));

  static const _hour = 56.0;
  Widget _grid(BuildContext c, List<Meeting> all) {
    final days = _days, now = DateTime.now(), cs = Theme.of(c).colorScheme;
    return Column(children: [
      Row(children: [const SizedBox(width: 52), for (final d in days) Expanded(child: InkWell(
        onTap: () => setState(() { anchor = d; view = CalView.day; }),
        child: Padding(padding: const EdgeInsets.symmetric(vertical: 6), child: Column(children: [
          Text(DateFormat('EEE').format(d), style: TextStyle(fontSize: 12, color: _d(now) == d ? cs.primary : null)),
          Text('${d.day}', style: TextStyle(fontSize: 20, fontWeight: _d(now) == d ? FontWeight.bold : FontWeight.normal, color: _d(now) == d ? cs.primary : null)),
        ]))))]),
      const Divider(height: 1),
      Expanded(child: SingleChildScrollView(controller: ScrollController(initialScrollOffset: _hour * 7), child: SizedBox(height: _hour * 24, child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
        SizedBox(width: 52, child: Stack(children: [for (var h = 1; h < 24; h++) Positioned(top: h * _hour - 7, right: 6, child: Text('${h.toString().padLeft(2, '0')}:00', style: const TextStyle(fontSize: 10)))])),
        for (final d in days) Expanded(child: GestureDetector(
          onTapUp: (e) => _newManual(at: d.add(Duration(minutes: ((e.localPosition.dy / _hour) * 2).floor() * 30))),
          child: Container(decoration: BoxDecoration(border: Border(left: BorderSide(color: cs.outlineVariant))), child: Stack(children: [
            for (var h = 0; h < 24; h++) Positioned(top: h * _hour, left: 0, right: 0, child: Divider(height: 1, color: cs.outlineVariant.withValues(alpha: .5))),
            if (_d(now) == d) Positioned(top: (now.hour + now.minute / 60) * _hour, left: 0, right: 0, child: Container(height: 2, color: Colors.red)),
            for (final m in _on(all, d)) Positioned(
              top: (m.start.hour + m.start.minute / 60) * _hour + 1, left: 2, right: 2, height: (m.minutes / 60 * _hour).clamp(22, _hour * 24) - 2,
              child: _block(c, m)),
          ])))),
      ])))),
    ]);
  }

  Widget _block(BuildContext c, Meeting m) {
    final cs = Theme.of(c).colorScheme;
    final declined = m.myResponse == 'no', tentative = m.myResponse == 'maybe' || m.showAs == 'tentative';
    return Opacity(opacity: declined ? .45 : 1, child: Material(color: tentative ? cs.primaryContainer.withValues(alpha: .45) : m.showAs == 'free' ? cs.surfaceContainerHigh : cs.primaryContainer, borderRadius: BorderRadius.circular(6), child: InkWell(borderRadius: BorderRadius.circular(6), onTap: () => _details(c, m),
      child: Container(padding: const EdgeInsets.fromLTRB(6, 3, 4, 2), decoration: BoxDecoration(border: Border(left: BorderSide(color: cs.primary, width: 3))),
        child: Text('${m.title}\n${DateFormat('HH:mm').format(m.start)} · ${m.room.getLocalizedDisplayname()}', overflow: TextOverflow.fade, style: TextStyle(fontSize: 11, color: cs.onPrimaryContainer, decoration: declined ? TextDecoration.lineThrough : null))))));
  }

  Widget _month(BuildContext c, List<Meeting> all) {
    final first = DateTime(anchor.year, anchor.month, 1), start = first.subtract(Duration(days: first.weekday - 1));
    return Column(children: [
      Row(children: [for (final n in const ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun']) Expanded(child: Center(child: Padding(padding: const EdgeInsets.all(4), child: Text(n, style: const TextStyle(fontSize: 12)))))]),
      Expanded(child: Column(children: [for (var w = 0; w < 6; w++) Expanded(child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [for (var i = 0; i < 7; i++) _cell(c, start.add(Duration(days: w * 7 + i)), all)]))]))]);
  }
  Widget _cell(BuildContext c, DateTime d, List<Meeting> all) {
    final cs = Theme.of(c).colorScheme, today = _d(DateTime.now());
        final ms = _on(all, d);
        return Expanded(child: InkWell(onTap: () => setState(() { anchor = d; view = CalView.day; }), child: Container(
          decoration: BoxDecoration(border: Border.all(color: cs.outlineVariant, width: .5), color: d.month == anchor.month ? null : cs.surfaceContainerHighest.withValues(alpha: .4)),
          padding: const EdgeInsets.all(3),
          child: SingleChildScrollView(physics: const NeverScrollableScrollPhysics(), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('${d.day}', style: TextStyle(fontSize: 12, fontWeight: d == today ? FontWeight.bold : null, color: d == today ? cs.primary : null)),
            for (final m in ms.take(3)) Text('${DateFormat('HH:mm').format(m.start)} ${m.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 10)),
            if (ms.length > 3) Text('+${ms.length - 3} more', style: const TextStyle(fontSize: 10)),
          ])))));
  }

  Widget _list(BuildContext c, List<Meeting> all) {
    final up = all.where((m) => m.start.add(Duration(minutes: m.minutes)).isAfter(DateTime.now())).toList()..sort((a, b) => a.start.compareTo(b.start));
    final ar = Localizations.localeOf(c).languageCode == 'ar';
    final today = ListTile(dense: true, leading: const Icon(Icons.nights_stay_outlined), title: Text(Hijri.of(DateTime.now()).format(arabic: ar)), subtitle: Text(DateFormat('EEEE d MMMM y').format(DateTime.now())));
    if (up.isEmpty) return ListView(children: [today, const Center(child: Text('No upcoming meetings.'))]);
    return ListView(children: [today, for (final m in up) ListTile(
      leading: Column(mainAxisAlignment: MainAxisAlignment.center, children: [Text(DateFormat('EEE').format(m.start)), Text(DateFormat('d MMM').format(m.start), style: Theme.of(c).textTheme.labelSmall), Text('${Hijri.of(m.start).day} ${(ar ? Hijri.monthsAr : Hijri.monthsEn)[Hijri.of(m.start).month - 1]}', style: const TextStyle(fontSize: 9))]),
      title: Text(m.title), subtitle: Text('${DateFormat('HH:mm').format(m.start)} · ${m.minutes} min · ${m.room.getLocalizedDisplayname()}'),
      onTap: () => _details(c, m),
      trailing: FilledButton.tonal(child: Text(L.t(context, 'Join')), onPressed: () => _join(c, m)))]);
  }

  void _join(BuildContext c, Meeting m) => Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: m.room.id,
    meeting: MeetingService(context.read<MatrixService>()).meetingIdOf(m.room) != null)));

  void _details(BuildContext c, Meeting m) {
    final mx = context.read<MatrixService>(); final me = mx.userId; final org = m.isOrganiser(me);
    String name(String u) => m.room.unsafeGetUserFromMemoryOrFallback(u).calcDisplayname();
    final count = {for (final k in ['yes', 'maybe', 'no']) k: m.responses.values.where((v) => v == k).length};
    showModalBottomSheet(context: c, isScrollControlled: true, showDragHandle: true, builder: (s) => SafeArea(child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text(m.title, style: Theme.of(c).textTheme.titleLarge), const SizedBox(height: 6),
      Text('${DateFormat('EEEE d MMMM y').format(m.start)} · ${DateFormat('HH:mm').format(m.start)}–${DateFormat('HH:mm').format(m.start.add(Duration(minutes: m.minutes)))}${m.repeats ? ' · repeats ${m.recurrence}' : ''}${m.changed ? ' · this occurrence was changed' : ''}'),
      Text('In ${m.room.getLocalizedDisplayname()} · organiser ${org ? 'you' : name(m.organiser)} · shows as ${m.showAs}'),
      if (m.optional.isNotEmpty) Text('Optional: ${m.optional.map(name).join(', ')}'),
      if (m.description.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 8), child: Text(m.description)),
      const SizedBox(height: 8),
      Text('Accepted ${count['yes']} · Tentative ${count['maybe']} · Declined ${count['no']} · No response ${(m.room.summary.mJoinedMemberCount ?? 1) - m.responses.length}', style: Theme.of(c).textTheme.bodySmall),
      for (final e in m.responses.entries) Text('  ${name(e.key)}: ${{'yes': 'accepted', 'maybe': 'tentative', 'no': 'declined'}[e.value]}', style: Theme.of(c).textTheme.bodySmall),
      const SizedBox(height: 14),
      Wrap(spacing: 8, runSpacing: 8, children: [
        FilledButton.icon(icon: const Icon(Icons.videocam), label: Text(L.t(context, 'Join')), onPressed: () { Navigator.pop(s); _join(c, m); }),
        OutlinedButton.icon(icon: const Icon(Icons.chat_bubble_outline), label: const Text('Chat with participants'), onPressed: () { Navigator.pop(s); Navigator.push(c, MaterialPageRoute(builder: (_) => ChatScreen(roomId: m.room.id))); }),
        if (org) OutlinedButton.icon(icon: const Icon(Icons.edit_calendar), label: const Text('Edit'), onPressed: () { Navigator.pop(s); _edit(c, m); }),
        if (org) OutlinedButton.icon(icon: const Icon(Icons.event_busy, color: Colors.red), label: const Text('Cancel meeting'), onPressed: () { Navigator.pop(s); _cancel(c, m); }),
      ]),
      if (!org) ...[
        const SizedBox(height: 12), Text('Your response${m.myResponse != null ? ': ${{'yes': 'accepted', 'maybe': 'tentative', 'no': 'declined'}[m.myResponse]}' : ''}', style: Theme.of(c).textTheme.titleSmall),
        Wrap(spacing: 8, children: [
          for (final (k, l, i) in const [('yes', 'Accept', Icons.check), ('maybe', 'Tentative', Icons.help_outline), ('no', 'Decline', Icons.close)])
            ChoiceChip(avatar: Icon(i, size: 16), label: Text(l), selected: m.myResponse == k, onSelected: (_) { Navigator.pop(s); _respond(c, m, k); }),
        ]),
      ],
    ]))));
  }

  Future<bool?> _scope(BuildContext c, Meeting m, String verb) async => !m.repeats ? false : showDialog<bool>(context: c, builder: (d) => SimpleDialog(title: Text('$verb which?'), children: [
    SimpleDialogOption(onPressed: () => Navigator.pop(d, false), child: const Text('This occurrence')),
    SimpleDialogOption(onPressed: () => Navigator.pop(d, true), child: const Text('The whole series'))]));

  Future<void> _respond(BuildContext c, Meeting m, String k) async {
    final series = await _scope(c, m, k == 'no' ? 'Decline' : 'Respond to'); if (series == null && m.repeats) return;
    final note = TextEditingController();
    if (!c.mounted) return;
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text({'yes': 'Accept', 'maybe': 'Tentative', 'no': 'Decline'}[k]!),
      content: TextField(controller: note, decoration: const InputDecoration(labelText: 'Add a note for the organiser (optional)')),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send'))]));
    if (ok != true) return;
    await context.read<MatrixService>().rsvp(m.room, m.id, k, occurrence: series == true ? null : m.occurrence, note: note.text.trim());
    _reload();
  }

  Future<void> _cancel(BuildContext c, Meeting m) async {
    final series = await _scope(c, m, 'Cancel'); if (series == null && m.repeats) return;
    final msg = TextEditingController();
    if (!c.mounted) return;
    final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: Text('Cancel ${series == true ? 'the series' : 'this meeting'}?'),
      content: TextField(controller: msg, decoration: const InputDecoration(labelText: 'Message to attendees (optional)')),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Keep it')), FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(d, true), child: const Text('Cancel meeting'))]));
    if (ok != true) return;
    final mx = context.read<MatrixService>();
    await mx.updateMeeting(m.room, m.id, occurrence: series == true ? null : m.occurrence, cancel: true);
    await m.room.sendTextEvent('🚫 Cancelled: ${m.title} on ${DateFormat('EEE d MMM, HH:mm').format(m.start)}${msg.text.trim().isEmpty ? '' : ' — ${msg.text.trim()}'}');
    _reload();
  }

  Future<void> _edit(BuildContext c, Meeting m) async {
    final series = await _scope(c, m, 'Edit'); if (series == null && m.repeats) return;
    final title = TextEditingController(text: m.title.replaceAll(' ↻', '')); var start = m.start; var minutes = m.minutes;
    if (!c.mounted) return;
    final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text('Edit ${series == true ? 'series' : 'meeting'}'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, decoration: const InputDecoration(labelText: 'Title')), const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.event), label: Text(DateFormat('EEE d MMM').format(start)), onPressed: () async {
            final p = await showDatePicker(context: d, initialDate: start, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
            if (p != null) set(() => start = DateTime(p.year, p.month, p.day, start.hour, start.minute)); })),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.schedule), label: Text(DateFormat('HH:mm').format(start)), onPressed: () async {
            final p = await showTimePicker(context: d, initialTime: TimeOfDay.fromDateTime(start));
            if (p != null) set(() => start = DateTime(start.year, start.month, start.day, p.hour, p.minute)); })),
        ]),
        DropdownButtonFormField<int>(value: const [15, 30, 45, 60, 90, 120].contains(minutes) ? minutes : 30, decoration: const InputDecoration(labelText: 'Duration'),
          items: [for (final n in const [15, 30, 45, 60, 90, 120]) DropdownMenuItem(value: n, child: Text('$n min'))], onChanged: (v) => set(() => minutes = v ?? 30)),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send update'))])));
    if (ok != true) return;
    final mx = context.read<MatrixService>();
    final moved = start != m.start;
    await mx.updateMeeting(m.room, m.id, occurrence: series == true ? null : m.occurrence, title: title.text.trim(), minutes: minutes,
      start: moved ? (series == true ? start : start) : null);
    await m.room.sendTextEvent('✏️ Updated: ${title.text.trim()} — ${DateFormat('EEE d MMM, HH:mm').format(start)} · $minutes min');
    _reload();
  }

  /// Teams' "New meeting" form: title, chat (attendees), date, start, duration. Sent as an encrypted meeting event.
  Future<void> _newManual({DateTime? at}) async {
    final mx = context.read<MatrixService>(); final rooms = mx.chats; if (rooms.isEmpty) return;
    final title = TextEditingController(); var room = rooms.first;
    var start = at ?? DateTime.now().add(Duration(minutes: 30 - DateTime.now().minute % 30)); var minutes = 30;
    var repeat = 'none', showAs = 'busy'; final optional = <String>{}; final desc = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
      title: const Text('New meeting'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Add title')),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(isExpanded: true, value: room.id, decoration: const InputDecoration(labelText: 'Attendees (chat)'),
          items: [for (final r in rooms) DropdownMenuItem(value: r.id, child: Text(r.getLocalizedDisplayname()))], onChanged: (v) => set(() => room = rooms.firstWhere((r) => r.id == v))),
        const SizedBox(height: 8),
        Row(children: [
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.event), label: Text(DateFormat('EEE d MMM').format(start)), onPressed: () async {
            final p = await showDatePicker(context: d, initialDate: start, firstDate: DateTime.now().subtract(const Duration(days: 1)), lastDate: DateTime.now().add(const Duration(days: 730)));
            if (p != null) set(() => start = DateTime(p.year, p.month, p.day, start.hour, start.minute)); })),
          const SizedBox(width: 8),
          Expanded(child: OutlinedButton.icon(icon: const Icon(Icons.schedule), label: Text(DateFormat('HH:mm').format(start)), onPressed: () async {
            final p = await showTimePicker(context: d, initialTime: TimeOfDay.fromDateTime(start));
            if (p != null) set(() => start = DateTime(start.year, start.month, start.day, p.hour, p.minute)); })),
        ]),
        const SizedBox(height: 8),
        DropdownButtonFormField<int>(value: minutes, decoration: const InputDecoration(labelText: 'Duration'),
          items: [for (final n in const [15, 30, 45, 60, 90, 120]) DropdownMenuItem(value: n, child: Text('$n min'))], onChanged: (v) => set(() => minutes = v ?? 30)),
        DropdownButtonFormField<String>(value: repeat, decoration: const InputDecoration(labelText: 'Repeat'), items: const [
          DropdownMenuItem(value: 'none', child: Text('Does not repeat')), DropdownMenuItem(value: 'daily', child: Text('Every day')),
          DropdownMenuItem(value: 'weekdays', child: Text('Every weekday (Mon–Fri)')), DropdownMenuItem(value: 'weekly', child: Text('Every week')),
          DropdownMenuItem(value: 'monthly', child: Text('Every month'))], onChanged: (v) => set(() => repeat = v ?? 'none')),
        DropdownButtonFormField<String>(value: showAs, decoration: const InputDecoration(labelText: 'Show as'), items: const [
          DropdownMenuItem(value: 'busy', child: Text('Busy')), DropdownMenuItem(value: 'tentative', child: Text('Tentative')), DropdownMenuItem(value: 'free', child: Text('Free'))],
          onChanged: (v) => set(() => showAs = v ?? 'busy')),
        Align(alignment: Alignment.centerLeft, child: Wrap(spacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Optional:'),
          for (final u in room.getParticipants().where((u) => u.id != mx.userId && u.membership == Membership.join))
            FilterChip(label: Text(u.calcDisplayname()), selected: optional.contains(u.id), onSelected: (v) => set(() => v ? optional.add(u.id) : optional.remove(u.id))),
        ])),
        TextField(controller: desc, maxLines: 3, decoration: const InputDecoration(labelText: 'Details (agenda, links)')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(context, 'Cancel'))), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send'))])));
    if (ok != true || title.text.trim().isEmpty) return;
    await mx.sendMeeting(room, title: title.text.trim(), start: start, minutes: minutes, recurrence: repeat, optional: optional.toList(), showAs: showAs, description: desc.text.trim());
    _reload();
  }
}

enum CalView { day, workWeek, week, month, list }
