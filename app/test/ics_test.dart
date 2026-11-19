import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/ics.dart';

const feed = 'BEGIN:VCALENDAR\r\nVERSION:2.0\r\n'
  'BEGIN:VEVENT\r\nUID:1\r\nDTSTART:20261123T060000Z\r\nDTEND:20261123T070000Z\r\nSUMMARY:Stand-up\\, team\r\nRRULE:FREQ=WEEKLY;BYDAY=MO,WE;COUNT=4\r\nEXDATE:20261125T060000Z\r\n'
  'BEGIN:VALARM\r\nTRIGGER:-PT15M\r\nEND:VALARM\r\nEND:VEVENT\r\n'
  'BEGIN:VEVENT\r\nUID:2\r\nDTSTART;TZID=Asia/Dubai:20261124T140000\r\nDURATION:PT90M\r\nSUMMARY:Vendor review with a very long title that is\r\n  folded\r\nEND:VEVENT\r\n'
  'BEGIN:VEVENT\r\nUID:3\r\nDTSTART;VALUE=DATE:20261201\r\nDTEND;VALUE=DATE:20261204\r\nSUMMARY:Annual leave\r\nTRANSP:TRANSPARENT\r\nEND:VEVENT\r\n'
  'BEGIN:VEVENT\r\nUID:4\r\nDTSTART:20261126T100000Z\r\nDTEND:20261126T110000Z\r\nSTATUS:CANCELLED\r\nSUMMARY:Gone\r\nEND:VEVENT\r\n'
  'BEGIN:VEVENT\r\nUID:5\r\nDTSTART:20261127T100000Z\r\nDTEND:20261127T110000Z\r\nX-MICROSOFT-CDO-BUSYSTATUS:OOF\r\nSUMMARY:Away\r\nEND:VEVENT\r\n'
  'BEGIN:VEVENT\r\nUID:6\r\nDTSTART:20261101T080000Z\r\nDTEND:20261101T083000Z\r\nRRULE:FREQ=DAILY;INTERVAL=2;UNTIL=20261130T000000Z\r\nSUMMARY:Gym\r\nEND:VEVENT\r\n'
  'END:VCALENDAR\r\n';

void main() {
  final ev = Ics.parse(feed, DateTime.utc(2026, 11, 22), DateTime.utc(2026, 12, 10));
  test('weekly BYDAY with COUNT and EXDATE', () {
    final s = ev.where((e) => e.summary == 'Stand-up, team').map((e) => e.start).toList();
    expect(s, [DateTime.utc(2026, 11, 23, 6), DateTime.utc(2026, 11, 30, 6), DateTime.utc(2026, 12, 2, 6)]);   // 25 Nov excluded; COUNT=4 counts it
  });
  test('TZID with DURATION, and line folding', () {
    final v = ev.firstWhere((e) => e.summary.startsWith('Vendor'));
    expect(v.summary, 'Vendor review with a very long title that is folded');
    expect(v.start, DateTime.utc(2026, 11, 24, 10)); expect(v.end, DateTime.utc(2026, 11, 24, 11, 30));
  });
  test('all-day leave is out of office and not busy; cancelled is dropped; OOF status', () {
    final l = ev.firstWhere((e) => e.summary == 'Annual leave');
    expect(l.allDay && l.oof && !l.busy, isTrue); expect(l.end.difference(l.start).inDays, 3);
    expect(ev.any((e) => e.summary == 'Gone'), isFalse);
    expect(ev.firstWhere((e) => e.summary == 'Away').oof, isTrue);
  });
  test('daily interval until', () {
    final g = ev.where((e) => e.summary == 'Gym').map((e) => e.start.day).toList();
    expect(g, [23, 25, 27, 29]);
  });
}
