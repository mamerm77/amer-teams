import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/workflow_engine.dart';

/// Same cases as services/orchestrator/tests/test_workflows.py, so device and server agree.
void main() {
  final ctx = <String, Object?>{'s1': {'amount_aed': '600000', 'vendor': 'Ciena'}, 'trigger': {'sender': '@sara:amer.test'}, 's3': {'decision': 'approved'}};
  test('conditions', () {
    expect(wfEvaluate(r'$s1.amount_aed > 500000', ctx), isTrue);
    expect(wfEvaluate(r'$s1.amount_aed <= 500000', ctx), isFalse);
    expect(wfEvaluate(r"$s1.vendor == 'Ciena'", ctx), isTrue);
    expect(wfEvaluate(r'$s1.vendor contains cie', ctx), isTrue);
    expect(wfEvaluate(r"$s3.decision == 'approved'", ctx), isTrue);
    expect(wfEvaluate(r'$s1.missing > 3', ctx), isFalse);
    expect(wfEvaluate('nonsense', ctx), isFalse);
  });
  test('templates and people', () {
    expect(wfRender('From {{s1.vendor}} by {{trigger.sender}}{{nope}}', ctx), 'From Ciena by @sara:amer.test');
    expect(wfPeople([r'$trigger.sender', '@cfo:amer.test', 'role:x'], ctx), ['@sara:amer.test', '@cfo:amer.test']);
  });
  test('next step follows branches and end', () {
    final steps = <Map<String, Object?>>[
      {'id': 's1', 'type': 'ask_form'}, {'id': 's2', 'type': 'condition', 'if': r'$s1.amount_aed > 500000', 'then': 's3', 'else': 's4'},
      {'id': 's3', 'type': 'approval', 'next': 'end'}, {'id': 's4', 'type': 'post'}];
    expect(wfNext(steps, 's1', ctx), 's2');
    expect(wfNext(steps, 's2', ctx), 's3');
    expect(wfNext(steps, 's2', {'s1': {'amount_aed': 10}}), 's4');
    expect(wfNext(steps, 's3', ctx), isNull);
    expect(wfNext(steps, 's4', ctx), isNull);
  });
  test('message trigger matching', () {
    final t = {'type': 'message', 'room': '!rfp', 'match': {'has_file': true, 'keywords': ['quote']}};
    expect(wfMatches(t, roomId: '!rfp', body: 'New Quote attached', hasFile: true, sender: '@a'), isTrue);
    expect(wfMatches(t, roomId: '!rfp', body: 'New Quote attached', hasFile: false, sender: '@a'), isFalse);
    expect(wfMatches(t, roomId: '!rfp', body: 'invoice', hasFile: true, sender: '@a'), isFalse);
    expect(wfMatches(t, roomId: '!other', body: 'quote', hasFile: true, sender: '@a'), isFalse);
  });
  test('cron', () {
    final mon9 = DateTime(2026, 11, 23, 9, 0);          // a Monday
    expect(wfCronDue('0 9 * * 1', mon9), isTrue);
    expect(wfCronDue('0 9 * * 1-5', mon9), isTrue);
    expect(wfCronDue('0 9 * * 0,6', mon9), isFalse);
    expect(wfCronDue('*/15 * * * *', DateTime(2026, 11, 23, 9, 30)), isTrue);
    expect(wfCronDue('*/15 * * * *', DateTime(2026, 11, 23, 9, 31)), isFalse);
    expect(wfCronDue('0 9 * * 7', DateTime(2026, 11, 22, 9, 0)), isTrue);   // Sunday as 7
    expect(wfCronDue('bad', mon9), isFalse);
  });
}
