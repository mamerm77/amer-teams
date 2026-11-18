import 'package:flutter_test/flutter_test.dart';
import 'package:amer_teams/services/call_signaling.dart';

class Clock { DateTime t = DateTime.utc(2026, 11, 18, 9); DateTime now() => t; void adv(int s) => t = t.add(Duration(seconds: s)); }

void main() {
  late Clock clk; late List<(String, Map<String, Object?>)> sentA, sentB;
  CallSignaling caller() => CallSignaling(role: CallRole.caller, callId: 'c1', myUser: '@a:x', myDevice: 'A1', video: false,
      send: (t, c) => sentA.add((t, c)), clock: clk.now);
  CallSignaling callee({String dev = 'B1', DateTime? ts}) => CallSignaling(role: CallRole.callee, callId: 'c1', myUser: '@b:x', myDevice: dev,
      send: (t, c) => sentB.add((t, c)), clock: clk.now, inviteTs: ts ?? clk.now());
  setUp(() { clk = Clock(); sentA = []; sentB = []; });
  void deliver(CallSignaling to, List<(String, Map<String, Object?>)> from, String user) { for (final e in from) to.onSignal(e.$1, e.$2, senderUser: user); }

  test('answer flow: calling → ringing → connecting → connected, timer starts at media', () {
    final a = caller()..startCall(); expect(a.state, CallState.calling); expect(sentA.first.$1, kInvite);
    final b = callee(); expect(b.receiveInvite(busy: false), true); expect(b.state, CallState.ringing);
    deliver(a, sentB, '@b:x'); expect(a.state, CallState.ringing); expect(a.label, 'Ringing…');
    sentB.clear(); clk.adv(5); b.accept(); deliver(a, sentB, '@b:x');
    expect(a.state, CallState.connecting); expect(a.duration, Duration.zero);
    clk.adv(2); a.mediaConnected(); b.mediaConnected(); expect(a.state, CallState.connected);
    clk.adv(65); expect(a.label, '01:05');
    a.hangup(); expect(a.outcome, CallOutcome.completed); expect(sentA.last.$2['duration_s'], 65);
    deliver(b, sentA, '@a:x'); expect(b.state, CallState.ended); expect(b.outcome, CallOutcome.remoteHangup);
  });

  test('offline callee: stays Calling, shows not reachable, ends No answer at 45 s', () {
    final a = caller()..startCall(); clk.adv(7); expect(a.label, 'Calling… (not reachable yet)');
    clk.adv(38); a.tick(); expect(a.outcome, CallOutcome.noAnswer);
    expect(sentA.map((e) => e.$1), containsAll([kHangup, kEnd])); expect(sentA.last.$2['outcome'], 'missed');
  });

  test('late invite after lifetime never rings; shows missed', () {
    final ts = clk.now(); clk.adv(60);
    final b = callee(ts: ts); expect(b.receiveInvite(busy: false), false); expect(b.outcome, CallOutcome.missed); expect(sentB, isEmpty);
  });

  test('decline', () {
    final a = caller()..startCall(); final b = callee()..receiveInvite(busy: false); b.decline();
    deliver(a, sentB, '@b:x'); expect(a.outcome, CallOutcome.declined); expect(a.label, 'Declined');
  });

  test('busy auto-reject', () {
    final a = caller()..startCall(); final b = callee(); expect(b.receiveInvite(busy: true), false);
    deliver(a, sentB, '@b:x'); expect(a.outcome, CallOutcome.busy);
  });

  test('caller cancels while ringing → callee missed', () {
    final a = caller()..startCall(); final b = callee()..receiveInvite(busy: false); deliver(a, sentB, '@b:x');
    a.hangup(); expect(a.outcome, CallOutcome.cancelled); deliver(b, sentA, '@a:x'); expect(b.outcome, CallOutcome.missed);
  });

  test('answered on another device stops ringing', () {
    final a = caller()..startCall(); final b1 = callee(dev: 'B1')..receiveInvite(busy: false);
    final b2 = callee(dev: 'B2')..receiveInvite(busy: false); sentB.clear();
    b2.accept(); deliver(b1, sentB, '@b:x'); deliver(a, sentB, '@b:x');
    expect(b1.outcome, CallOutcome.answeredElsewhere); expect(a.remoteParty, 'B2'); expect(a.state, CallState.connecting);
  });

  test('callee ringing times out on its own', () {
    final b = callee()..receiveInvite(busy: false); clk.adv(46); b.tick(); expect(b.outcome, CallOutcome.missed);
  });

  test('media never connects → failed after 20 s', () {
    final a = caller()..startCall(); final b = callee()..receiveInvite(busy: false); b.accept(); deliver(a, sentB, '@b:x');
    clk.adv(21); a.tick(); expect(a.outcome, CallOutcome.failed); expect(a.label, 'Could not connect');
  });

  test('own echoed events and other call ids are ignored; ended is terminal', () {
    final a = caller()..startCall(); deliver(a, sentA, '@a:x'); expect(a.state, CallState.calling);
    a.onSignal(kAnswer, {'call_id': 'other', 'party_id': 'B1'}, senderUser: '@b:x'); expect(a.state, CallState.calling);
    a.hangup(); a.onSignal(kAnswer, {'call_id': 'c1', 'party_id': 'B1'}, senderUser: '@b:x'); expect(a.state, CallState.ended);
  });

  test('glare: smaller call id wins', () {
    expect(CallSignaling.winsGlare('a-1', 'b-1'), true); expect(CallSignaling.winsGlare('b-1', 'a-1'), false);
  });
}
