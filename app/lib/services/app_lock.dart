import 'dart:convert';
import 'dart:io';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// PIN app lock. The PIN is stored only as a salted SHA-256 hash in the app's private storage.
class AppLock {
  static Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/app_lock.json');
  static Future<bool> enabled() async => (await _f()).exists();
  static Future<void> setPin(String pin) async {
    final salt = DateTime.now().microsecondsSinceEpoch.toString();
    await (await _f()).writeAsString(jsonEncode({'salt': salt, 'hash': sha256.convert(utf8.encode('$salt:$pin')).toString()}));
  }
  static Future<void> clear() async { final f = await _f(); if (await f.exists()) await f.delete(); }
  static Future<bool> check(String pin) async {
    final f = await _f(); if (!await f.exists()) return true;
    final j = jsonDecode(await f.readAsString());
    return sha256.convert(utf8.encode('${j['salt']}:$pin')).toString() == j['hash'];
  }
}

/// Shows the lock screen on start and after more than a minute in the background.
class LockGate extends StatefulWidget { const LockGate({super.key, required this.child}); final Widget child; @override State<LockGate> createState() => _G(); }
class _G extends State<LockGate> with WidgetsBindingObserver {
  bool locked = false; DateTime? away; final pin = TextEditingController(); String? err; int tries = 0;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); AppLock.enabled().then((v) => setState(() => locked = v)); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override void didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) away ??= DateTime.now();
    if (s == AppLifecycleState.resumed) {
      if (away != null && DateTime.now().difference(away!).inSeconds > 60 && await AppLock.enabled()) setState(() => locked = true);
      away = null;
    }
  }
  Future<void> _try() async {
    if (await AppLock.check(pin.text)) { setState(() { locked = false; err = null; tries = 0; pin.clear(); }); return; }
    tries++; pin.clear();
    setState(() => err = tries >= 5 ? 'Too many attempts. Wait 30 seconds.' : 'Wrong PIN');
    if (tries >= 5) { await Future.delayed(const Duration(seconds: 30)); setState(() { tries = 0; err = null; }); }
  }
  @override Widget build(BuildContext c) => Stack(children: [
    widget.child,
    if (locked) Positioned.fill(child: Material(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 320), child: Column(mainAxisSize: MainAxisSize.min, children: [
      const Icon(Icons.lock, size: 48), const SizedBox(height: 12), Text('Amer Teams is locked', style: Theme.of(c).textTheme.titleLarge),
      const SizedBox(height: 16),
      TextField(controller: pin, autofocus: true, obscureText: true, keyboardType: TextInputType.number, textAlign: TextAlign.center, enabled: tries < 5,
        decoration: InputDecoration(labelText: 'PIN', errorText: err), onSubmitted: (_) => _try()),
      const SizedBox(height: 12), FilledButton(onPressed: tries < 5 ? _try : null, child: const Text('Unlock')),
    ]))))),
  ]);
}
