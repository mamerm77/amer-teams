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
      try { await body(); } catch (e) {
        final seen = find.byType(Text).evaluate().map((el) => (el.widget as Text).data ?? '').where((x) => x.trim().isNotEmpty).take(60).join(' | ');
        err = '${'$e'.split('\n').first}  ON SCREEN: $seen';
      }
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
    Future<void> type(Finder f, String text, String what) async {
      expectFound(await waitFor(f), what);
      await t.tap(f.first); await wait(.3);            // focus the box first, as a person would (re-attaches text input after a menu closes)
      await t.enterText(f.first, text); await wait(.3);
    }
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

    // record app errors as findings instead of aborting the whole run
    final appErrors = <String>[];
    final prevOnError = FlutterError.onError;
    FlutterError.onError = (d) { appErrors.add(d.exceptionAsString().split('\n').first); // ignore: avoid_print
      print('APP ERROR  ${d.exceptionAsString().split('\n').first}'); };
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
      await wait(2);
      await tap(find.byTooltip('Photo, file, poll or checklist'), 'attach menu');
      if (!await waitFor(find.text('Poll'), secs: 3)) await tap(find.byTooltip('Photo, file, poll or checklist'), 'attach menu (again)');
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
    await step('Meeting: raise hand', () async { await wait(6); /* let the "No camera" notice clear the control bar */ await tap(find.byTooltip('Raise hand'), 'Raise hand'); expectFound(await waitFor(find.byTooltip('Lower hand')), 'hand raised'); });
    await step('Meeting: participants panel', () async { await tap(find.byTooltip('Participants'), 'Participants'); expectFound(await waitFor(find.textContaining('Participants (')), 'participants list'); });
    await step('Meeting: chat panel', () async { await tap(find.byTooltip('Chat'), 'Chat'); expectFound(await waitFor(field('Message everyone (encrypted)')), 'meeting chat'); });
    await step('Meeting: whiteboard', () async {
      await tap(find.byTooltip('More'), 'More');
      await tap(find.text('Whiteboard'), 'Whiteboard'); await wait(3);
      await t.pageBack(); await wait(1);
    });
    await step('Meeting: leave', () async { await tap(find.text('Leave'), 'Leave'); await wait(3); });

    // ---------------- other areas ----------------
    // back to the main screen whatever the meeting steps left open
    for (var i = 0; i < 4 && find.text('Activity').evaluate().isEmpty; i++) { await t.pageBack(); await wait(1); }
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

    // ---------------- remaining messaging and security features ----------------
    Future<void> home() async { for (var i = 0; i < 5 && find.text('Activity').evaluate().isEmpty; i++) { await t.pageBack(); await wait(1); } }
    Future<void> chatInfo() async { await openChat(); await tap(find.byType(PopupMenuButton<String>).last, 'chat menu'); await tap(find.text('Chat info'), 'Chat info'); }
    Future<String> docker(List<String> a) async => ((await Process.run('docker', a)).stdout as String).trim();

    await step('Typing indicator', () async {
      await home(); await openChat(); await sendText('bob: type');
      expectFound(await waitFor(find.textContaining('is typing…'), secs: 20), '"Bob Tester is typing…"');
    });
    await step('Mention reaches Activity', () async {
      await sendText('bob: mention me');
      expectFound(await waitFor(find.textContaining('please review the plan'), secs: 30), 'mention message');
      await home(); await tap(find.text('Activity'), 'Activity tab');
      expectFound(await waitFor(find.textContaining('mentioned you'), secs: 20), 'mention in Activity');
    });
    await step('Forward a message', () async {
      await home(); await openChat();
      await tap(find.byTooltip('Reply, react, forward, edit, delete…'), 'options');
      await tap(find.text('Forward'), 'Forward');
      await tap(find.descendant(of: find.byType(SimpleDialog), matching: find.text('Bob Tester')), 'target chat');
      expectFound(await waitFor(find.textContaining('Forwarded to'), secs: 10), 'Forwarded confirmation');
    });
    await step('Failed send shows ⚠ and Retry delivers it', () async {
      final id = await docker(['ps', '-q', '--filter', 'name=synapse']);
      if (id.isEmpty) throw StateError('synapse container not found');
      await docker(['pause', id]);
      try {
        await sendText('sent while the server was down');
        expectFound(await waitFor(find.textContaining('Not sent'), secs: 90), '⚠ Not sent');
        await shot('failed-send');
      } finally { await docker(['unpause', id]); }
      await wait(5);
      await tap(find.textContaining('Not sent'), 'Not sent · tap');
      await tap(find.text('Retry'), 'Retry');
      for (var i = 0; i < 60 && find.textContaining('Not sent').evaluate().isNotEmpty; i++) { await wait(1); }
      if (find.textContaining('Not sent').evaluate().isNotEmpty) throw StateError('still not sent after retry');
    });
    await step('Block: no messages or calls from Bob', () async {
      await home(); await sendText('bob: in 20s say hi'); await sendText('bob: in 20s call me');
      await chatInfo(); await tap(find.text('Block contact'), 'Block contact');
      expectFound(await waitFor(find.text('Blocked')), 'Blocked confirmation');
      await home(); await openChat();
      await wait(35);
      if (find.text('hello while blocked').evaluate().isNotEmpty) throw StateError('message from blocked user was shown');
      if (find.text('Accept').evaluate().isNotEmpty) throw StateError('call from blocked user rang');
    });
    await step('Unblock', () async {
      await chatInfo(); await tap(find.text('Unblock contact'), 'Unblock contact');
      expectFound(await waitFor(find.text('Unblocked')), 'Unblocked confirmation');
      await home();
    });
    await step('App lock: set PIN', () async {
      await home(); await tap(find.text('Security'), 'Security tab');
      await tap(find.text('App lock'), 'App lock switch');
      await type(field('PIN (4–8 digits)'), '4826', 'PIN'); await type(field('Repeat PIN'), '4826', 'repeat PIN');
      await tap(find.text('Set'), 'Set');
      expectFound(await waitFor(find.textContaining('App lock on'), secs: 30), 'App lock on');
    });
    await step('App lock: wrong PIN cannot turn it off', () async {
      await wait(4); await tap(find.text('App lock'), 'App lock switch');
      await type(field('Current PIN'), '0000', 'current PIN'); await tap(find.text('Turn off'), 'Turn off');
      expectFound(await waitFor(find.text('Wrong PIN'), secs: 30), 'Wrong PIN');
    });
    await step('App lock: correct PIN turns it off', () async {
      await wait(4); await tap(find.text('App lock'), 'App lock switch');
      await type(field('Current PIN'), '4826', 'current PIN'); await tap(find.text('Turn off'), 'Turn off');
      expectFound(await waitFor(find.text('App lock off'), secs: 30), 'App lock off');
    });

    // ---------------- device verification and key backup ----------------
    final moh2Out = '$shots/moh2.json';
    Map<String, dynamic> moh2() { try { return jsonDecode(File(moh2Out).readAsStringSync()) as Map<String, dynamic>; } catch (_) { return {}; } }
    await step('Verify a new device with emoji (SAS)', () async {
      await home();
      await Process.start('python3', ['-u', '../tests/ui_moh2.py'], environment: {'HS': 'http://localhost', 'OUT': moh2Out}, mode: ProcessStartMode.detached);
      expectFound(await waitFor(find.text('Start'), secs: 90), 'incoming verification request');
      await tap(find.text('Start'), 'Start');
      expectFound(await waitFor(find.text('They match'), secs: 60), 'emoji comparison');
      for (var i = 0; i < 20 && (moh2()['emoji'] as List? ?? const []).isEmpty; i++) { await wait(1); }
      final emoji = (moh2()['emoji'] as List? ?? const []).cast<String>();
      if (emoji.length != 7) throw StateError('second device did not compute 7 emoji: ${moh2()}');
      final missing = emoji.where((e) => find.text(e).evaluate().isEmpty).toList();
      if (missing.isNotEmpty) throw StateError('emoji differ between devices; app is missing $missing of $emoji');
      await shot('verification-emoji-match');
      await tap(find.text('They match'), 'They match');
      expectFound(await waitFor(find.textContaining('Verified.'), secs: 60), 'Verified');
      for (var i = 0; i < 30 && moh2()['stage'] != 'done'; i++) { await wait(1); }
      if (moh2()['verified'] != true) throw StateError('second device did not mark the app verified: ${moh2()}');
      await tap(find.text('Done'), 'Done');
    });
    String? recoveryKey;
    await step('Set up encrypted key backup', () async {
      await home(); await tap(find.text('Security'), 'Security tab');
      await tap(find.text('Set up'), 'Set up backup');
      expectFound(await waitFor(find.text('Save your recovery key'), secs: 90), 'recovery key dialog');
      recoveryKey = find.byType(SelectableText).evaluate().map((e) => (e.widget as SelectableText).data ?? '').firstWhere((x) => x.startsWith('Es'), orElse: () => '');
      if (recoveryKey!.isEmpty) throw StateError('recovery key not shown');
      await tap(find.text('I have saved it'), 'I have saved it');
      expectFound(await waitFor(find.text('Chat history is backed up'), secs: 30), 'backup status');
    });
    await step('Server holds the encrypted backup', () async {
      final h = HttpClient();
      Future<Map<String, dynamic>> req(String m, String path, [Object? body, String? tok]) async {
        final r = await h.openUrl(m, Uri.parse('http://localhost$path'));
        r.headers.contentType = ContentType.json; if (tok != null) r.headers.set('Authorization', 'Bearer $tok');
        if (body != null) r.write(jsonEncode(body));
        final res = await r.close(); final txt = await res.transform(utf8.decoder).join();
        return {'status': res.statusCode, ...((txt.isNotEmpty ? jsonDecode(txt) : {}) as Map<String, dynamic>)};
      }
      final login = await req('POST', '/_matrix/client/v3/login', {'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': 'moh'}, 'password': 'Moh-Pass-123!', 'initial_device_display_name': 'backup check (deleted)'});
      final v = await req('GET', '/_matrix/client/v3/room_keys/version', null, login['access_token'] as String);
      await req('POST', '/_matrix/client/v3/logout', {}, login['access_token'] as String);
      if (v['status'] != 200 || v['algorithm'] != 'm.megolm_backup.v1.curve25519-aes-sha2') throw StateError('no backup on server: $v');
      if ((v['count'] as num? ?? 0) < 1) throw StateError('backup holds no keys: $v');
    });
    await step('Restore backup with the recovery key', () async {
      await tap(find.text('Restore here'), 'Restore here');
      if (await waitFor(find.text('Enter your recovery key'), secs: 30)) {
        await type(find.byType(TextField).last, recoveryKey ?? '', 'recovery key'); await tap(find.text('Unlock'), 'Unlock');
      }
      expectFound(await waitFor(find.textContaining('Backup unlocked'), secs: 60), 'Backup unlocked');
    });

    FlutterError.onError = prevOnError;
    results.add({'step': 'No app errors during the run', 'pass': appErrors.isEmpty, 'error': appErrors.toSet().join(' || ')});
    File('$shots/results.json').writeAsStringSync(const JsonEncoder.withIndent(' ').convert(results));
    final failed = results.where((r) => r['pass'] != true).length;
    // ignore: avoid_print
    print('IN-USE RESULT: ${results.length - failed}/${results.length} steps passed');
  }, timeout: const Timeout(Duration(minutes: 40)));
}
