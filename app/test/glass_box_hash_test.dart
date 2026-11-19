import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/glass_box.dart';

/// Vectors computed by the server (services/orchestrator/app/agentops/personal.py phash). If these fail, the
/// app's hash of what it sends would never match what the owner approved.
void main() {
  test('message payload with Arabic, a dash, a newline and quotes', () {
    expect(payloadHash({'text': 'Ciena is 10% cheaper — قرار يوم الأحد\nline 2 "q"', 'room_id': '!abc:amer.test'}),
        '7e636ad4c854811be8bafda35b0e7927bd65fcb9c528f3cb49e6eb0d83f1acae');
  });
  test('meeting payload with an integer', () {
    expect(payloadHash({'room_id': '!r', 'title': 'Vendor review', 'start': '2026-11-22T09:00', 'duration_min': 30}),
        'dd99661a72f28c2249e24db237b8f542f082ef9fab96bb66fa1f38bfa899dfff');
  });
}
