// In-use test: drives the real Amer Teams app against a real server, with a real end-to-end encrypted peer
// (tests/ui_peer.py, "Bob"). Every step taps the UI the way a user does and takes a screenshot.
// Results: $SHOTS/results.json and $SHOTS/NN-name.png.
import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:amer_teams/main.dart' as app;

final shots = Platform.environment['SHOTS'] ?? '/tmp/shots';
final results = <Map<String, Object?>>[];
var n = 0;

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('Amer Teams in use', (t) async {
    Directory(shots).createSync(recursive: true);
    Future<void> wait(double secs) async { for (var i = 0; i < secs * 10; i++) { await t.pump(const Duration(milliseconds: 100)); } }
    Future<bool> waitFor(Finder f, {double secs = 20}) async {
      for (var i = 0; i < secs * 10; i++) { await t.pump(const Duration(milliseconds: 100)); if (f.evaluate().isNotEmpty) return true; }
      return false;
    }
    Future<void> shot(String name) async {
      await wait(.5);
      final f = '$shots/${(++n).toString().padLeft(2, '0')}-$name.png';
      await Process.run('import', ['-window', 'root', f]);
    }
    Future<void> step(String name, Future<void> Function() body) async {
      final sw = Stopwatch()..start(); String? err;
      try { await body(); } catch (e) { err = '$e'.split('\n').first; }
      await shot(name.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), '-'));
      results.add({'step': name, 'pass': err == null, 'error': err, 'ms': sw.elapsedMilliseconds, 'shot': n});
      // ignore: avoid_print
      print('${err == null ? 'PASS' : 'FAIL'}  $name${err != null ? '  — $err' : ''}');
      File('$shots/results.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(results));
      // close anything a failed step left open
      if (err != null) { for (var i = 0; i < 3 && find.byType(BottomSheet).evaluate().isNotEmpty || find.byType(Dialog).evaluate().isNotEmpty; i++) { await t.tapAt(const Offset(5, 5)); await wait(.5); } }
    }
    void expectFound(bool ok, String what) { if (!ok) throw StateError('Not shown on screen: $what'); }
    Future<void> tap(Finder f, String what) async { expectFound(await waitFor(f), what); await t.tap(f.first); await wait(.6); }
    Future<void> type(Finder f, String text, String what) async { expectFound(await waitFor(f), what); await t.enterText(f.first, text); await wait(.3); }
    Finder field(String label) => find.byWidgetPredicate((w) => w is TextField && (w.decoration?.labelText == label || w.decoration?.hintText == label));
    Future<void> sendText(String s) async {
      await type(field('Message'), s, 'message box');
      await tap(find.byTooltip('Send (long-press to schedule)'), 'send button');
    }
    Future<void> openChat() async {
      if (find.byTooltip('Send (long-press to schedule)').evaluate().isNotEmpty || field('Message').evaluate().isNotEmpty) return;
      while (find.byType(BackButton).evaluate().isNotEmpty) { await t.tap(find.byType(BackButton).first); await wait(.5); }
      await tap(find.text('Chat'), 'Chat tab');
      await tap(find.text('Bob Tester'), 'chat with Bob in the list');
    }

    app.main();
    await wait(3);

    // ---------------- sign in ----------------
    await step('Sign-in screen', () async { expectFound(await waitFor(field('Server')), 'Server field'); });
    await step('Sign in as moh', () async {
      await type(field('Server'), 'http://localhost', 'Server field');
      await type(field('Username'), 'moh', 'Username field');
      await type(field('Password'), 'Moh-Pass-123!', 'Password field');
      await tap(find.widgetWithText(FilledButton, 'Sign in'), 'Sign in button');
      expectFound(await waitFor(find.text('Chat'), secs: 60), 'home screen');
    });
    await step('About shows build number', () async { expectFound(await waitFor(find.textContaining(RegExp(r'^b(\d+|dev)$'))), 'build label'); });

    // ---------------- chat ----------------
    await step('Chat list shows Bob', () async { await tap(find.text('Chat'), 'Chat tab'); expectFound(await waitFor(find.text('Bob Tester'), secs: 40), 'Bob Tester'); });
    await step('Open chat with Bob (encrypted)', () async { await openChat(); expectFound(await waitFor(find.textContaining('encrypted')), 'encryption notice'); });
    await step('Send message and get reply', () async {
      await sendText('ping');
      expectFound(await waitFor(find.text('pong from Bob'), secs: 45), 'Bob\'s reply (decrypted)');
    });
    await step('Read receipt ticks (✓✓)', () async { expectFound(await waitFor(find.byIcon(Icons.done_all), secs: 20), 'double tick'); });
    await step('Message options visible on each message', () async { expectFound(await waitFor(find.byTooltip('Reply, react, forward, edit, delete…')), 'options button'); });
    await step('React to Bob\'s message', () async {
      await tap(find.byTooltip('Reply, react, forward, edit, delete…'), 'options');
      await tap(find.text('👍'), 'thumbs-up reaction');
      expectFound(await waitFor(find.textContaining('👍 1')), 'reaction count');
    });
    await step('Reply to a message', () async {
      await tap(find.byTooltip('Reply, react, forward, edit, delete…'), 'options');
      await tap(find.text('Reply'), 'Reply');
      await sendText('this is a reply');
      expectFound(await waitFor(find.text('this is a reply')), 'reply');
    });
    await step('Edit my message', () async {
      await tap(find.byTooltip('Reply, react, forward, edit, delete…'), 'options');
      await tap(find.text('Edit'), 'Edit');
      await type(field('Message'), 'this is an edited reply', 'message box');
      await tap(find.byIcon(Icons.check), 'confirm edit');
      expectFound(await waitFor(find.textContaining('edited')), 'edited label');
    });
    await step('Delete my message', () async {
      await sendText('message to delete');
      await waitFor(find.text('message to delete'));
      await tap(find.byTooltip('Reply, react, forward, edit, delete…'), 'options');
      await tap(find.text('Delete for everyone'), 'Delete for everyone');
      if (find.widgetWithText(FilledButton, 'Delete').evaluate().isNotEmpty) await tap(find.widgetWithText(FilledButton, 'Delete'), 'confirm');
      await wait(3);
      if (find.text('message to delete').evaluate().isNotEmpty) throw StateError('message still shown after delete');
    });
    await step('Save (star) a message', () async {
      await tap(find.byTooltip('Reply, react, forward, edit, delete…'), 'options');
      await tap(find.text('Save'), 'Save');
    });
    await step('Create a poll', () async {
      await tap(find.byTooltip('Photo, file, poll or checklist'), 'attach menu');
      await tap(find.text('Poll'), 'Poll');
      await type(field('Question'), 'Lunch at 1pm?', 'question');
      await type(field('Option 1'), 'Yes', 'option 1'); await type(field('Option 2'), 'No', 'option 2');
      await tap(find.text('Send poll'), 'Send poll');
      expectFound(await waitFor(find.text('Lunch at 1pm?')), 'poll card');
    });
    await step('Create a checklist', () async {
      await tap(find.byTooltip('Photo, file, poll or checklist'), 'attach menu');
      await tap(find.text('Checklist'), 'Checklist');
      await type(field('Title'), 'Release tasks', 'title');
      await type(field('Task 1'), 'Build', 'task 1'); await type(field('Task 2'), 'Test', 'task 2');
      await tap(find.widgetWithText(FilledButton, 'Send'), 'Send');
      expectFound(await waitFor(find.text('Release tasks')), 'checklist card');
    });
    await step('Search in chat', () async {
      await tap(find.byTooltip('Search'), 'Search');
      await t.enterText(find.byType(TextField).first, 'pong'); await wait(1);
      expectFound(await waitFor(find.text('pong from Bob')), 'search result');
      await tap(find.byTooltip('Close search'), 'close search');
    });
    await step('Chat info', () async {
      await tap(find.byType(PopupMenuButton<String>).last, 'chat menu');
      await tap(find.text('Chat info'), 'Chat info');
      await wait(2); await t.pageBack(); await wait(1);
    });

    // ---------------- calls (protocol v2) ----------------
    await step('Voice call: Calling then Ringing', () async {
      await openChat();
      await tap(find.byTooltip('Voice call'), 'Voice call button');
      expectFound(await waitFor(find.textContaining(RegExp(r'Calling…|Ringing…')), secs: 15), 'Calling…/Ringing…');
      expectFound(await waitFor(find.text('Ringing…'), secs: 20), 'Ringing… (Bob\'s device confirmed)');
    });
    await step('Voice call: answered and connected (timer runs)', () async {
      expectFound(await waitFor(find.textContaining(RegExp(r'Encrypted · quantum-safe · 00:0[1-9]')), secs: 40), 'connected, encrypted, timer running');
      await wait(4);
    });
    await step('Voice call: hang up, chat shows duration', () async {
      await tap(find.text('Leave'), 'Leave');
      expectFound(await waitFor(find.textContaining('Outgoing voice call'), secs: 20), 'call card with duration');
    });
    await step('Call declined', () async {
      await openChat(); await sendText('bob: decline next'); await wait(2);
      await tap(find.byTooltip('Voice call'), 'Voice call');
      expectFound(await waitFor(find.text('Declined'), secs: 30), 'Declined');
      await wait(4);
    });
    await step('Callee busy', () async {
      await openChat(); await sendText('bob: busy next'); await wait(2);
      await tap(find.byTooltip('Voice call'), 'Voice call');
      expectFound(await waitFor(find.text('Busy'), secs: 30), 'Busy');
      await wait(4);
    });
    await step('Cancel while ringing', () async {
      await openChat(); await sendText('bob: ignore next'); await wait(2);
      await tap(find.byTooltip('Voice call'), 'Voice call');
      expectFound(await waitFor(find.textContaining('Calling…'), secs: 15), 'Calling…');
      await tap(find.byIcon(Icons.call_end), 'end');
      expectFound(await waitFor(find.text('Call cancelled'), secs: 10), 'Call cancelled');
      await wait(4);
    });
    await step('Incoming call rings and can be answered', () async {
      await openChat(); await sendText('bob: call me');
      expectFound(await waitFor(find.text('Accept'), secs: 30), 'incoming call dialog');
      await shot('incoming-call-dialog');
      await tap(find.text('Accept'), 'Accept');
      expectFound(await waitFor(find.textContaining(RegExp(r'Encrypted · quantum-safe · 00:0[1-9]')), secs: 40), 'connected');
      await wait(3);
      await tap(find.text('Leave'), 'Leave'); await wait(4);
    });
    await step('Call history in Calls tab', () async {
      while (find.byType(BackButton).evaluate().isNotEmpty) { await t.tap(find.byType(BackButton).first); await wait(.5); }
      await tap(find.text('Calls'), 'Calls tab');
      expectFound(await waitFor(find.text('Recent')), 'Recent calls');
    });

    // ---------------- meetings ----------------
    await step('Meet now', () async {
      await tap(find.text('Meet now'), 'Meet now');
      if (await waitFor(find.text('Start meeting'), secs: 15)) await tap(find.text('Start meeting'), 'Start meeting');
      expectFound(await waitFor(find.text('Leave'), secs: 40), 'meeting screen');
    });
    await step('Meeting: raise hand', () async { await tap(find.byTooltip('Raise hand'), 'Raise hand'); expectFound(await waitFor(find.byTooltip('Lower hand')), 'hand raised'); });
    await step('Meeting: participants panel', () async { await tap(find.byTooltip('Participants'), 'Participants'); expectFound(await waitFor(find.textContaining('Participants (')), 'participants list'); });
    await step('Meeting: chat panel', () async { await tap(find.byTooltip('Chat'), 'Chat'); expectFound(await waitFor(field('Message everyone (encrypted)')), 'meeting chat'); });
    await step('Meeting: whiteboard', () async {
      await tap(find.byTooltip('More'), 'More');
      await tap(find.text('Whiteboard'), 'Whiteboard'); await wait(3);
      await t.pageBack(); await wait(1);
    });
    await step('Meeting: leave', () async { await tap(find.text('Leave'), 'Leave'); await wait(3); });

    // ---------------- other areas ----------------
    for (final tab in ['Activity', 'Teams', 'Calendar', 'Amer', 'Control', 'Health', 'Security']) {
      await step('$tab screen', () async { await tap(find.text(tab), '$tab tab'); await wait(3); });
    }
    await step('Users (admin)', () async { await tap(find.text('Users'), 'Users tab'); expectFound(await waitFor(find.text('New invite code')), 'admin tools'); });
    await step('Admin: create invite code', () async { await tap(find.text('New invite code'), 'New invite code'); expectFound(await waitFor(find.text('Invite code created')), 'invite code'); await tap(find.text('Done'), 'Done'); });
    await step('Admin: call trace list', () async { await tap(find.text('Call trace'), 'Call trace'); expectFound(await waitFor(find.textContaining('@moh:amer.test →')), 'recorded calls'); });
    await step('Admin: one call\'s full trace', () async {
      await tap(find.textContaining('@moh:amer.test →'), 'a call');
      expectFound(await waitFor(find.textContaining('Signalling and media events')), 'trace ladder');
      await wait(1); await t.pageBack(); await wait(1); await t.pageBack();
    });

    final failed = results.where((r) => r['pass'] != true).length;
    // ignore: avoid_print
    print('IN-USE RESULT: ${results.length - failed}/${results.length} steps passed');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
