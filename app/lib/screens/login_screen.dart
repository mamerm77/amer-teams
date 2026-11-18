import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../config.dart';
import '../services/matrix_service.dart';

/// Client-side copy of the server password policy (server enforces it too).
class LoginScreenPolicy {
  static String? check(String p) {
    if (p.length < 10) return 'Use at least 10 characters';
    if (!RegExp(r'[A-Z]').hasMatch(p) || !RegExp(r'[a-z]').hasMatch(p)) return 'Use upper- and lower-case letters';
    if (!RegExp(r'\d').hasMatch(p)) return 'Include a number';
    if (!RegExp(r'[^A-Za-z0-9]').hasMatch(p)) return 'Include a symbol';
    return null;
  }
}

/// Sign in, or create an account with an invite code from your administrator.
class LoginScreen extends StatefulWidget { const LoginScreen({super.key}); @override State<LoginScreen> createState() => _S(); }
class _S extends State<LoginScreen> {
  final server = TextEditingController(text: kDefaultHomeserver), user = TextEditingController(), pass = TextEditingController(),
      pass2 = TextEditingController(), name = TextEditingController(), invite = TextEditingController();
  bool busy = false, signup = false; String? err;

  static String? pwProblem(String p) => LoginScreenPolicy.check(p);

  Future<void> go() async {
    setState(() { busy = true; err = null; });
    final m = context.read<MatrixService>();
    try {
      if (signup) {
        final p = pwProblem(pass.text);
        if (p != null) throw Exception(p);
        if (pass.text != pass2.text) throw Exception('Passwords do not match');
        if (invite.text.trim().isEmpty) throw Exception('Enter the invite code from your administrator');
        await m.register(server.text.trim(), user.text.trim().toLowerCase(), pass.text, invite.text, displayName: name.text.trim());
      } else {
        await m.login(server.text.trim(), user.text.trim(), pass.text);
      }
    } catch (e) {
      setState(() => err = e.toString().replaceFirst('Exception: ', ''));
    } finally { if (mounted) setState(() => busy = false); }
  }

  @override Widget build(BuildContext c) => Scaffold(body: Center(child: SingleChildScrollView(child: ConstrainedBox(
    constraints: const BoxConstraints(maxWidth: 400), child: Padding(padding: const EdgeInsets.all(24), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.lock, size: 48), const SizedBox(height: 8),
      Text('Amer Teams', style: Theme.of(c).textTheme.headlineMedium),
      const Text('End-to-end encrypted by default'), const SizedBox(height: 16),
      SegmentedButton<bool>(segments: const [ButtonSegment(value: false, label: Text('Sign in')), ButtonSegment(value: true, label: Text('Create account'))],
        selected: {signup}, onSelectionChanged: (v) => setState(() { signup = v.first; err = null; })),
      const SizedBox(height: 12),
      TextField(controller: server, decoration: const InputDecoration(labelText: 'Server')),
      TextField(controller: user, decoration: const InputDecoration(labelText: 'Username'), autocorrect: false),
      if (signup) TextField(controller: name, decoration: const InputDecoration(labelText: 'Display name')),
      TextField(controller: pass, obscureText: true, decoration: InputDecoration(labelText: 'Password',
          helperText: signup ? '10+ characters with upper, lower, number and symbol' : null), onSubmitted: (_) => signup ? null : go()),
      if (signup) TextField(controller: pass2, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm password')),
      if (signup) TextField(controller: invite, decoration: const InputDecoration(labelText: 'Invite code'), autocorrect: false),
      if (err != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(err!, style: TextStyle(color: Theme.of(c).colorScheme.error))),
      const SizedBox(height: 20),
      FilledButton(onPressed: busy ? null : go, child: Text(busy ? 'Please wait…' : signup ? 'Create account' : 'Sign in')),
    ]))))));
}
