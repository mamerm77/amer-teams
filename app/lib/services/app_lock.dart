import 'dart:convert';
import 'dart:isolate';
import 'dart:math';
import 'dart:io';
import 'dart:async';
import 'package:crypto/crypto.dart';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// PIN app lock (docs/FEATURE_LOGIC.md).
/// - PIN stored only as PBKDF2-HMAC-SHA256 (150 000 iterations, random 16-byte salt) in the app's private storage.
/// - Failed attempts are persisted, so restarting the app does not reset them; lockout escalates 30 s → 5 min → 1 h.
/// - Turning the lock off requires the current PIN.
class AppLock {
  static const iterations = 150000;
  static Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/app_lock.json');
  static Future<Map<String, dynamic>?> _read() async { final f = await _f(); return await f.exists() ? jsonDecode(await f.readAsString()) as Map<String, dynamic> : null; }
  static Future<void> _write(Map<String, dynamic> j) async => (await _f()).writeAsString(jsonEncode(j));
  static Future<bool> enabled() async => (await _f()).exists();

  static List<int> pbkdf2(List<int> pin, List<int> salt, int iters) {
    final h = Hmac(sha256, pin);
    var u = h.convert([...salt, 0, 0, 0, 1]).bytes; final out = List<int>.from(u);
    for (var i = 1; i < iters; i++) { u = h.convert(u).bytes; for (var k = 0; k < out.length; k++) { out[k] ^= u[k]; } }
    return out;
  }
  static Future<String> _derive(String pin, List<int> salt, int iters) =>
      Isolate.run(() => base64.encode(pbkdf2(utf8.encode(pin), salt, iters)));

  static Future<void> setPin(String pin) async {
    final r = Random.secure(); final salt = List<int>.generate(16, (_) => r.nextInt(256));
    await _write({'v': 2, 'salt': base64.encode(salt), 'iter': iterations, 'hash': await _derive(pin, salt, iterations), 'fails': 0, 'until': 0});
  }
  /// Seconds the user must still wait before another attempt (0 = may try now).
  static Future<int> waitSeconds() async {
    final j = await _read(); if (j == null) return 0;
    final until = (j['until'] as num?)?.toInt() ?? 0;
    return max(0, ((until - DateTime.now().millisecondsSinceEpoch) / 1000).ceil());
  }
  static Future<bool> check(String pin) async {
    final j = await _read(); if (j == null) return true;
    if (await waitSeconds() > 0) return false;
    bool ok;
    if (j['v'] == 2) {
      ok = _eq(await _derive(pin, base64.decode(j['salt']), (j['iter'] as num).toInt()), j['hash'] as String);
    } else {                                            // v1 (salted SHA-256): verify, then upgrade
      ok = _eq(sha256.convert(utf8.encode('${j['salt']}:$pin')).toString(), j['hash'] as String);
      if (ok) { await setPin(pin); return true; }
    }
    if (ok) { j['fails'] = 0; j['until'] = 0; await _write(j); return true; }
    final fails = ((j['fails'] as num?)?.toInt() ?? 0) + 1;
    final lock = fails >= 15 ? 3600 : fails >= 10 ? 300 : fails >= 5 ? 30 : 0;
    j['fails'] = fails; j['until'] = lock > 0 ? DateTime.now().millisecondsSinceEpoch + lock * 1000 : 0;
    await _write(j);
    return false;
  }
  /// Turns the lock off only with the correct PIN.
  static Future<bool> disable(String pin) async { if (!await check(pin)) return false; await clear(); return true; }
  static Future<void> clear() async { final f = await _f(); if (await f.exists()) await f.delete(); }
  static bool _eq(String a, String b) { if (a.length != b.length) return false; var d = 0; for (var i = 0; i < a.length; i++) { d |= a.codeUnitAt(i) ^ b.codeUnitAt(i); } return d == 0; }
}

/// Shows the lock screen on start and after more than a minute in the background.
class LockGate extends StatefulWidget { const LockGate({super.key, required this.child}); final Widget child; @override State<LockGate> createState() => _G(); }
class _G extends State<LockGate> with WidgetsBindingObserver {
  bool locked = false; DateTime? away; final pin = TextEditingController(); String? err; int tries = 0;
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); AppLock.enabled().then((v) => setState(() => locked = v)); AppLock.waitSeconds().then((w) { if (w > 0) _cooldown(w); }); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); super.dispose(); }
  @override void didChangeAppLifecycleState(AppLifecycleState s) async {
    if (s == AppLifecycleState.paused || s == AppLifecycleState.hidden) away ??= DateTime.now();
    if (s == AppLifecycleState.resumed) {
      if (away != null && DateTime.now().difference(away!).inSeconds > 60 && await AppLock.enabled()) setState(() => locked = true);
      away = null;
    }
  }
  Timer? _cool;
  Future<void> _try() async {
    final w0 = await AppLock.waitSeconds();
    if (w0 > 0) { _cooldown(w0); return; }
    if (await AppLock.check(pin.text)) { setState(() { locked = false; err = null; tries = 0; pin.clear(); }); return; }
    pin.clear();
    final w = await AppLock.waitSeconds();
    if (w > 0) { _cooldown(w); } else { setState(() => err = 'Wrong PIN'); }
  }
  void _cooldown(int secs) {
    setState(() { tries = 5; err = 'Too many attempts. Try again in ${secs >= 60 ? '${(secs / 60).ceil()} min' : '$secs s'}.'; });
    _cool?.cancel(); _cool = Timer(Duration(seconds: secs), () { if (mounted) setState(() { tries = 0; err = null; }); });
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
