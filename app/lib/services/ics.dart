/// iCalendar (RFC 5545) reader for calendar connectors (docs/CONNECTORS.md). Handles line folding, UTC / floating /
/// TZID times (TZID resolved by fixed offset of known zones, else treated as device local), all-day events, and the
/// recurrence rules calendars actually emit: FREQ=DAILY|WEEKLY|MONTHLY|YEARLY with INTERVAL, COUNT, UNTIL, BYDAY
/// (weekly), plus EXDATE and cancelled events. Busy status: TRANSP:TRANSPARENT and free/busy FREE are not busy.
class IcsEvent {
  IcsEvent(this.start, this.end, {this.summary = '', this.allDay = false, this.busy = true, this.oof = false});
  final DateTime start, end; final String summary; final bool allDay, busy, oof;
  @override String toString() => '$summary ${start.toIso8601String()}–${end.toIso8601String()}';
}

class Ics {
  static const _zoneOffsets = {'Asia/Dubai': 240, 'Arabian Standard Time': 240, 'Asia/Riyadh': 180, 'Arab Standard Time': 180, 'Asia/Qatar': 180,
    'Asia/Kuwait': 180, 'Asia/Bahrain': 180, 'Asia/Muscat': 240, 'Africa/Cairo': 120, 'Egypt Standard Time': 120, 'UTC': 0, 'Etc/UTC': 0, 'GMT Standard Time': 0, 'Asia/Kolkata': 330, 'India Standard Time': 330};
  static final _oofWords = RegExp(r'out of (the )?office|\booo\b|annual leave|\bvacation\b|\bholiday\b|\bon leave\b|إجازة|خارج المكتب', caseSensitive: false);

  static List<String> _unfold(String s) {
    final out = <String>[];
    for (final l in s.replaceAll('\r\n', '\n').split('\n')) {
      if ((l.startsWith(' ') || l.startsWith('\t')) && out.isNotEmpty) { out[out.length - 1] += l.substring(1); } else if (l.isNotEmpty) { out.add(l); }
    }
    return out;
  }

  /// (value, params) for "NAME;P=1;Q=2:value".
  static (String, Map<String, String>) _split(String line) {
    final i = line.indexOf(':'); final head = i < 0 ? line : line.substring(0, i);
    final params = <String, String>{};
    for (final p in head.split(';').skip(1)) { final j = p.indexOf('='); if (j > 0) params[p.substring(0, j).toUpperCase()] = p.substring(j + 1).replaceAll('"', ''); }
    return (i < 0 ? '' : line.substring(i + 1), params);
  }

  static DateTime? _time(String v, Map<String, String> p) {
    final m = RegExp(r'^(\d{4})(\d{2})(\d{2})(?:T(\d{2})(\d{2})(\d{2})?(Z)?)?$').firstMatch(v.trim()); if (m == null) return null;
    final y = int.parse(m[1]!), mo = int.parse(m[2]!), d = int.parse(m[3]!);
    if (m[4] == null) return DateTime(y, mo, d);                                    // all-day: device-local midnight
    final h = int.parse(m[4]!), mi = int.parse(m[5]!), s = int.parse(m[6] ?? '0');
    if (m[7] == 'Z') return DateTime.utc(y, mo, d, h, mi, s);
    final off = _zoneOffsets[p['TZID']];
    if (off != null) return DateTime.utc(y, mo, d, h, mi, s).subtract(Duration(minutes: off));
    return DateTime(y, mo, d, h, mi, s);                                            // floating or unknown zone: local
  }

  static Duration? _duration(String v) {
    final m = RegExp(r'^([+-])?P(?:(\d+)W)?(?:(\d+)D)?(?:T(?:(\d+)H)?(?:(\d+)M)?(?:(\d+)S)?)?$').firstMatch(v.trim()); if (m == null) return null;
    int g(int i) => int.tryParse(m[i] ?? '') ?? 0;
    return Duration(days: g(2) * 7 + g(3), hours: g(4), minutes: g(5), seconds: g(6));
  }

  /// Events overlapping [from, to), recurrences expanded.
  static List<IcsEvent> parse(String text, DateTime from, DateTime to) {
    final out = <IcsEvent>[]; Map<String, (String, Map<String, String>)>? cur; final exdates = <DateTime>[]; var depth = 0;
    for (final line in _unfold(text)) {
      final u = line.toUpperCase();
      if (u == 'BEGIN:VEVENT') { cur = {}; exdates.clear(); depth = 0; continue; }
      if (cur == null) continue;
      if (u.startsWith('BEGIN:')) { depth++; continue; }                             // VALARM inside an event
      if (u.startsWith('END:') && depth > 0) { depth--; continue; }
      if (u == 'END:VEVENT') { _emit(cur, exdates, from, to, out); cur = null; continue; }
      if (depth > 0) continue;
      final name = line.split(RegExp('[;:]')).first.toUpperCase();
      final sp = _split(line);
      if (name == 'EXDATE') { for (final v in sp.$1.split(',')) { final t = _time(v, sp.$2); if (t != null) exdates.add(t); } }
      else { cur[name] = sp; }
    }
    out.sort((a, b) => a.start.compareTo(b.start));
    return out;
  }

  static void _emit(Map<String, (String, Map<String, String>)> e, List<DateTime> ex, DateTime from, DateTime to, List<IcsEvent> out) {
    if ((e['STATUS']?.$1 ?? '').toUpperCase() == 'CANCELLED') return;
    final ds = e['DTSTART']; if (ds == null) return;
    final start = _time(ds.$1, ds.$2); if (start == null) return;
    final allDay = !ds.$1.contains('T');
    var end = e['DTEND'] != null ? _time(e['DTEND']!.$1, e['DTEND']!.$2) : null;
    end ??= e['DURATION'] != null ? start.add(_duration(e['DURATION']!.$1) ?? Duration.zero) : start.add(allDay ? const Duration(days: 1) : Duration.zero);
    final len = end.difference(start);
    final summary = (e['SUMMARY']?.$1 ?? '').replaceAll(r'\,', ',').replaceAll(r'\;', ';').replaceAll(r'\n', ' ');
    final busyStatus = (e['X-MICROSOFT-CDO-BUSYSTATUS']?.$1 ?? '').toUpperCase();
    final busy = (e['TRANSP']?.$1 ?? '').toUpperCase() != 'TRANSPARENT' && busyStatus != 'FREE';
    final oof = busyStatus == 'OOF' || _oofWords.hasMatch(summary);
    void add(DateTime s) {
      if (ex.any((x) => x.isAtSameMomentAs(s))) return;
      final en = s.add(len);
      if (en.isAfter(from) && s.isBefore(to)) out.add(IcsEvent(s, en, summary: summary, allDay: allDay, busy: busy, oof: oof));
    }
    final rr = e['RRULE']?.$1;
    if (rr == null) { add(start); return; }
    final r = {for (final kv in rr.split(';')) if (kv.contains('=')) kv.split('=')[0].toUpperCase(): kv.split('=')[1]};
    final freq = r['FREQ'] ?? ''; final interval = int.tryParse(r['INTERVAL'] ?? '') ?? 1;
    final count = int.tryParse(r['COUNT'] ?? ''); final until = r['UNTIL'] != null ? _time(r['UNTIL']!, const {}) : null;
    const days = {'MO': 1, 'TU': 2, 'WE': 3, 'TH': 4, 'FR': 5, 'SA': 6, 'SU': 7};
    final byday = (r['BYDAY'] ?? '').split(',').map((d) => days[d.replaceAll(RegExp(r'[^A-Z]'), '')]).whereType<int>().toSet();
    var n = 0;
    bool more(DateTime s) => (count == null || n < count) && (until == null || !s.isAfter(until)) && s.isBefore(to) && n < 5000;
    DateTime shift(DateTime s, {int days = 0, int months = 0}) => s.isUtc
        ? DateTime.utc(s.year, s.month + months, s.day + days, s.hour, s.minute, s.second)
        : DateTime(s.year, s.month + months, s.day + days, s.hour, s.minute, s.second);
    switch (freq) {
      case 'DAILY': for (var s = start; more(s); s = shift(s, days: interval)) { n++; add(s); }
      case 'WEEKLY':
        final want = byday.isEmpty ? {start.weekday} : byday;
        var week = shift(start, days: -(start.weekday - 1));                         // Monday of the first week
        weeks: while (week.isBefore(to)) {
          for (var d = 0; d < 7; d++) {
            final s = shift(week, days: d);
            if (!want.contains(s.weekday) || s.isBefore(start)) continue;
            if (!more(s)) break weeks;
            n++; add(s);
          }
          week = shift(week, days: 7 * interval);
        }
      case 'MONTHLY': for (var s = start; more(s); s = shift(s, months: interval)) { n++; add(s); }
      case 'YEARLY': for (var s = start; more(s); s = shift(s, months: 12 * interval)) { n++; add(s); }
      default: add(start);
    }
  }
}
