import '../ui/depth.dart';
import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/calendar_connector.dart';
import '../services/focus.dart';
import '../services/matrix_service.dart';
import '../services/search_index.dart';
import '../services/wellbeing.dart';

/// Focus and wellbeing (docs/FOCUS.md, docs/WELLBEING.md).
class FocusScreen extends StatefulWidget {
  const FocusScreen({super.key});
  @override State<FocusScreen> createState() => _S();
}
class _S extends State<FocusScreen> {
  final f = FocusGuard.instance; WeekSignals? week; String? summary;
  @override void initState() { super.initState(); _week(); }
  Future<void> _week() async {
    final m = context.read<MatrixService>(); final now = DateTime.now(), from = now.subtract(const Duration(days: 7));
    final spans = <Span>[
      for (final e in CalendarConnector.instance.events.where((e) => e.busy && !e.allDay && e.start.isAfter(from) && e.start.isBefore(now))) Span(e.start.toLocal(), e.end.toLocal()),
      for (final x in (await m.meetings()).where((x) => x.start.isAfter(from) && x.start.isBefore(now))) Span(x.start, x.start.add(Duration(minutes: x.minutes))),
    ];
    final sent = await SearchIndex.instance.sentTimes(m.client.userID ?? '', from);
    final focus = [for (final h in f.history.where((h) => h.$1.isAfter(from))) Span(h.$1, h.$2)];
    if (mounted) setState(() => week = computeWeek(spans, sent, focus: focus));
  }
  Future<void> _start(int min) async { await f.start(context.read<ApiService>(), min); if (mounted) setState(() => summary = null); }
  Future<void> _stop() async { final s = await f.stop(context.read<ApiService>()); if (mounted) setState(() => summary = s.text); _week(); }
  Widget _row(String k, String v) => ListTile(dense: true, title: Text(k), trailing: Text(v, style: const TextStyle(fontWeight: FontWeight.w600)));
  @override
  Widget build(BuildContext c) {
    final u = f.until; final w = week;
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Focus and wellbeing'))), body: ListView(padding: const EdgeInsets.all(12), children: [
      DepthCard(child: Padding(padding: const EdgeInsets.all(16), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(u == null ? 'Focus session' : 'Focusing until ${TimeOfDay.fromDateTime(u).format(c)}', style: Theme.of(c).textTheme.titleLarge),
        const SizedBox(height: 6),
        const Text('Notifications wait (even mentions) except from your priority senders; your status shows you are focusing; direct messages get one automatic reply; find-a-time sees you as busy.'),
        const SizedBox(height: 12),
        if (u == null) Wrap(spacing: 8, children: [for (final m in [30, 60, 90, 120]) FilledButton.tonal(onPressed: () => _start(m), child: Text(m < 60 ? '$m min' : '${m ~/ 60}${m % 60 == 0 ? '' : '.5'} h'))])
        else FilledButton.icon(onPressed: _stop, icon: const Icon(Icons.stop), label: Text(L.t(context, 'End focus now'))),
        if (summary != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(summary!)),
      ]))),
      DepthCard(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        const ListTile(title: Text('Your last 7 days'), subtitle: Text('Worked out on this device from your calendar and the messages you sent. Nobody else can see this, your manager included.')),
        if (w == null) const Padding(padding: EdgeInsets.all(16), child: LinearProgressIndicator()) else ...[
          _row('Meeting hours', w.meetingHours.toStringAsFixed(1)), _row('Back-to-back meetings', '${w.backToBack}'),
          _row('Longest run of meetings', '${(w.longestMeetingRun.inMinutes / 60).toStringAsFixed(1)} h'), _row('Working days with no lunch gap', '${w.daysWithoutBreak}'),
          _row('Messages you sent', '${w.messagesSent}'), _row('…outside working hours', '${w.afterHoursMessages}'), _row('…at the weekend', '${w.weekendMessages}'),
          _row('Focus time', '${w.focusHours.toStringAsFixed(1)} h'),
          for (final n in w.nudges()) ListTile(leading: const Icon(Icons.lightbulb_outline), title: Text(n)),
          if (w.nudges().isEmpty) const ListTile(leading: Icon(Icons.check_circle_outline), title: Text('A balanced week. Nothing to flag.')),
        ],
      ])),
    ]));
  }
}
