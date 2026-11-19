import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/premortem.dart';

void main() {
  test('parses fenced JSON, drops empty risks, ranks by likelihood x impact', () {
    final p = PreMortem.parse('```json\n{"summary":"Vendor slips","risks":[{"risk":"Low thing","likelihood":"low","impact":"low","mitigation":"m"},'
        '{"risk":"","likelihood":"high"},{"risk":"Fibre permits late","why_it_fails":"municipality","likelihood":"high","impact":"high","early_warning":"no permit by week 4","mitigation":"file early"}]}\n```');
    expect(p.risks.map((r) => r['risk']), ['Fibre permits late', 'Low thing']);
    expect(p.toMessage(), contains('Watch for: no permit by week 4'));
  });
  test('refuses an answer with no risks', () {
    expect(() => PreMortem.parse('Sorry, I cannot.'), throwsFormatException);
  });
}
