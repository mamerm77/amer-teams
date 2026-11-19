/// Wellbeing signals (docs/WELLBEING.md): computed on this device from your own calendar and the messages you sent.
/// Nothing here is sent anywhere, and nobody else, your manager included, can see it.
class Span { Span(this.start, this.end); final DateTime start, end; Duration get length => end.difference(start); }

class WeekSignals {
  WeekSignals({required this.meetingHours, required this.backToBack, required this.afterHoursMessages, required this.weekendMessages,
    required this.daysWithoutBreak, required this.longestMeetingRun, required this.focusHours, required this.messagesSent});
  final double meetingHours, focusHours; final int backToBack, afterHoursMessages, weekendMessages, daysWithoutBreak, messagesSent; final Duration longestMeetingRun;

  /// Plain-language nudges, only for signals that crossed a line.
  List<String> nudges() => [
    if (meetingHours > 20) 'Meetings took ${meetingHours.toStringAsFixed(0)} hours this week. Could some be a written update instead?',
    if (backToBack >= 5) '$backToBack meetings started straight after another. A 5-minute gap between meetings helps.',
    if (longestMeetingRun.inMinutes >= 180) 'Your longest run of meetings without a break was ${(longestMeetingRun.inMinutes / 60).toStringAsFixed(1)} hours.',
    if (daysWithoutBreak >= 2) 'On $daysWithoutBreak working days there was no 30-minute gap between 12:00 and 14:00 for lunch.',
    if (afterHoursMessages >= 10) 'You sent $afterHoursMessages messages outside your working hours. Scheduled send can hold them until the morning.',
    if (weekendMessages >= 5) 'You sent $weekendMessages messages at the weekend.',
    if (focusHours < 4 && meetingHours > 10) 'Less than 4 hours of focus time this week. Try a focus session tomorrow morning.',
  ];
}

/// [meetings] in the week; [sent] times of messages you sent; working [days] (Monday = 1) and hours.
WeekSignals computeWeek(List<Span> meetings, List<DateTime> sent, {Set<int> days = const {1, 2, 3, 4, 5}, int startHour = 8, int endHour = 17, List<Span> focus = const []}) {
  final m = [...meetings]..sort((a, b) => a.start.compareTo(b.start));
  var b2b = 0; var longest = Duration.zero; DateTime? runStart; DateTime? runEnd;
  for (var i = 0; i < m.length; i++) {
    if (i > 0 && m[i].start.difference(m[i - 1].end).inMinutes.abs() < 5 && m[i].start.day == m[i - 1].start.day) b2b++;
    if (runEnd != null && m[i].start.difference(runEnd).inMinutes < 10 && m[i].start.day == runEnd.day) { if (m[i].end.isAfter(runEnd)) runEnd = m[i].end; }
    else { runStart = m[i].start; runEnd = m[i].end; }
    final run = runEnd.difference(runStart!); if (run > longest) longest = run;
  }
  final byDay = <DateTime, List<Span>>{};
  for (final s in m) { byDay.putIfAbsent(DateTime(s.start.year, s.start.month, s.start.day), () => []).add(s); }
  var noLunch = 0;
  for (final e in byDay.entries) {
    if (!days.contains(e.key.weekday)) continue;
    final ws = e.key.add(const Duration(hours: 12)), we = e.key.add(const Duration(hours: 14));
    var t = ws, gap = Duration.zero;
    for (final s in e.value.where((s) => s.end.isAfter(ws) && s.start.isBefore(we))) {
      if (s.start.isAfter(t)) { final g = s.start.difference(t); if (g > gap) gap = g; }
      if (s.end.isAfter(t)) t = s.end;
    }
    if (we.isAfter(t) && we.difference(t) > gap) gap = we.difference(t);
    if (gap.inMinutes < 30) noLunch++;
  }
  bool after(DateTime t) => days.contains(t.weekday) && (t.hour < startHour || t.hour >= endHour);
  return WeekSignals(
    meetingHours: m.fold<int>(0, (s, x) => s + x.length.inMinutes) / 60, backToBack: b2b,
    afterHoursMessages: sent.where(after).length, weekendMessages: sent.where((t) => !days.contains(t.weekday)).length,
    daysWithoutBreak: noLunch, longestMeetingRun: longest, focusHours: focus.fold<int>(0, (s, x) => s + x.length.inMinutes) / 60, messagesSent: sent.length);
}
