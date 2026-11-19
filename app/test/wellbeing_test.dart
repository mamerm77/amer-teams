import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/wellbeing.dart';

DateTime d(int day, int h, [int m = 0]) => DateTime(2026, 11, day, h, m);   // 16 Nov 2026 is a Monday
void main() {
  test('back-to-back, longest run, no lunch, after-hours and weekend messages', () {
    final meetings = [Span(d(16, 9), d(16, 10)), Span(d(16, 10), d(16, 11)), Span(d(16, 11, 2), d(16, 12, 30)), Span(d(16, 12, 30), d(16, 14)),
                      Span(d(17, 12), d(17, 12, 30))];
    final w = computeWeek(meetings, [d(16, 7), d(16, 20), d(17, 10), d(21, 11), d(22, 9)]);
    expect(w.backToBack, 3);                                        // 10:00, 11:02, 12:30 start right after the previous one
    expect(w.longestMeetingRun, const Duration(hours: 5));          // 09:00 – 14:00 on Monday
    expect(w.daysWithoutBreak, 1);                                  // Monday has no lunch gap; Tuesday has 12:30–14:00
    expect(w.afterHoursMessages, 2); expect(w.weekendMessages, 2); expect(w.meetingHours, closeTo(5.47, 0.01));
    expect(w.nudges().any((n) => n.contains('longest run')), isTrue);
  });
}
