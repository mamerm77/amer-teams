import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/hijri.dart';
// Same values as the server's calendar_time.hijri (tabular calendar).
void main() {
  test('tabular Hijri dates', () {
    final a = Hijri.of(DateTime(2026, 11, 19)); expect([a.year, a.month, a.day], [1448, 6, 8]);
    final b = Hijri.of(DateTime(2026, 2, 18)); expect([b.year, b.month, b.day], [1447, 9, 1]);     // 1 Ramadan 1447
    expect(Hijri.of(DateTime(2025, 3, 1)).format(), '1 Ramadan 1446 AH');
    expect(Hijri.of(DateTime(2025, 3, 1)).format(arabic: true), '1 رمضان 1446 هـ');
  });
}
