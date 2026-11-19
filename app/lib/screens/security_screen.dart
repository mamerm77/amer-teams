import '../services/accessibility.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:matrix/encryption.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/app_lock.dart';
import '../services/matrix_service.dart';
import '../services/locale.dart';

/// Security: your devices (verify with emoji, sign out), encrypted key backup with a recovery key,
/// and app lock.
class SecurityScreen extends StatefulWidget { const SecurityScreen({super.key}); @override State<SecurityScreen> createState() => _S(); }
class _S extends State<SecurityScreen> {
  Client get c => context.read<MatrixService>().client;
  List<Device> devices = []; bool? lockOn;
  @override void initState() { super.initState(); _load(); AppLock.enabled().then((v) => setState(() => lockOn = v)); }
  Future<void> _load() async { final d = await c.getDevices() ?? []; if (mounted) setState(() => devices = d); }
  void _msg(Object t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$t'.replaceFirst('Exception: ', ''))));

  // ---------- verification ----------
  Future<void> _verify(DeviceKeys dk) async {
    final v = await dk.startVerification();
    if (mounted) await showVerification(context, v);
    setState(() {});
  }

  Future<void> _signOut(Device d) async {
    final pw = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (x) => AlertDialog(title: Text('Sign out ${d.displayName ?? d.deviceId}?'),
      content: TextField(controller: pw, obscureText: true, decoration: const InputDecoration(labelText: 'Confirm with your password')),
      actions: [TextButton(onPressed: () => Navigator.pop(x, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(x, true), child: const Text('Sign out'))]));
    if (ok != true) return;
    try {
      await c.deleteDevice(d.deviceId, auth: AuthenticationPassword(password: pw.text, identifier: AuthenticationUserIdentifier(user: c.userID!)));
    } on MatrixException catch (e) {
      if (e.session == null) rethrow;
      await c.deleteDevice(d.deviceId, auth: AuthenticationPassword(session: e.session, password: pw.text, identifier: AuthenticationUserIdentifier(user: c.userID!)));
    } catch (e) { _msg(e); }
    _load();
  }

  // ---------- secure backup (SSSS + cross-signing + online key backup) ----------
  Future<void> _backup() async {
    final enc = c.encryption; if (enc == null) { _msg('Encryption is not ready yet'); return; }
    final done = Completer<void>(); String? shownKey;
    late Bootstrap b;
    Future<void> step(Bootstrap b) async {
      try {
        switch (b.state) {
          case BootstrapState.loading: return;
          case BootstrapState.askWipeSsss: b.wipeSsss(false);
          case BootstrapState.askUseExistingSsss: b.useExistingSsss(true);
          case BootstrapState.askBadSsss: b.ignoreBadSecrets(true);
          case BootstrapState.askUnlockSsss:
            final key = await _askRecoveryKey();
            if (key == null) { if (!done.isCompleted) done.complete(); return; }
            await b.newSsssKey!.unlock(keyOrPassphrase: key); b.unlockedSsss();
          case BootstrapState.askNewSsss:
            await b.newSsss(); shownKey = b.newSsssKey?.recoveryKey;
          case BootstrapState.openExistingSsss: await b.openExistingSsss();
          case BootstrapState.askWipeCrossSigning: await b.wipeCrossSigning(false);
          case BootstrapState.askSetupCrossSigning: await b.askSetupCrossSigning(setupMasterKey: true, setupSelfSigningKey: true, setupUserSigningKey: true);
          case BootstrapState.askWipeOnlineKeyBackup: b.wipeOnlineKeyBackup(false);
          case BootstrapState.askSetupOnlineKeyBackup: await b.askSetupOnlineKeyBackup(true);
          case BootstrapState.error: if (!done.isCompleted) done.completeError(Exception('Backup setup failed'));
          case BootstrapState.done: if (!done.isCompleted) done.complete();
        }
      } catch (e) { if (!done.isCompleted) done.completeError(e); }
    }
    b = enc.bootstrap(onUpdate: (x) => step(x));
    try {
      await done.future.timeout(const Duration(minutes: 3));
      if (!mounted) return;
      if (shownKey != null) {
        await showDialog(context: context, barrierDismissible: false, builder: (d) => AlertDialog(title: const Text('Save your recovery key'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Your chat history is now backed up, encrypted with this key. You need it to read old messages on a new phone or PC. Store it somewhere safe; Amer Teams cannot recover it.'),
            const SizedBox(height: 12), SelectableText(shownKey!, style: const TextStyle(fontFamily: 'monospace', fontSize: 16))]),
          actions: [TextButton(onPressed: () => Clipboard.setData(ClipboardData(text: shownKey!)), child: const Text('Copy')),
            FilledButton(onPressed: () => Navigator.pop(d), child: const Text('I have saved it'))]));
      } else { _msg('Backup unlocked: old messages will now decrypt on this device'); }
    } catch (e) { _msg(e); }
    setState(() {});
  }
  /// Restore on this device: unlock the encrypted backup with the recovery key and load all old message keys.
  Future<void> _restore() async {
    final enc = c.encryption; if (enc == null) { _msg('Encryption is not ready yet'); return; }
    if (await enc.keyManager.isCached() && await enc.crossSigning.isCached()) {
      _msg('Backup already unlocked on this device: old messages open here');
      return;
    }
    final key = await _askRecoveryKey(); if (key == null || key.isEmpty) return;
    try {
      await enc.ssss.open().unlock(keyOrPassphrase: key);        // also caches the secrets and self-signs this device
      await enc.keyManager.loadAllKeys();
      _msg('Backup unlocked: old messages will now decrypt on this device');
    } catch (e) {
      _msg('That recovery key did not unlock your backup');
    }
    if (mounted) setState(() {});
  }

  Future<String?> _askRecoveryKey() async {
    final k = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Enter your recovery key'),
      content: TextField(controller: k, decoration: const InputDecoration(hintText: 'EsT1 abcd …')),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Unlock'))]));
    return ok == true ? k.text.trim() : null;
  }

  // ---------- app lock ----------
  Future<void> _setPin() async {
    final a = TextEditingController(), b = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Set app PIN'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: a, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(labelText: 'PIN (4–8 digits)')),
        TextField(controller: b, obscureText: true, keyboardType: TextInputType.number, maxLength: 8, decoration: const InputDecoration(labelText: 'Repeat PIN'))]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Set'))]));
    if (ok != true) return;
    if (!RegExp(r'^\d{4,8}$').hasMatch(a.text) || a.text != b.text) { _msg('PINs must match and be 4–8 digits'); return; }
    await AppLock.setPin(a.text); setState(() => lockOn = true); _msg('App lock on: the app asks for your PIN after 1 minute in the background');
  }

  Future<void> _disableLock() async {
    final p = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Turn off app lock'),
      content: TextField(controller: p, obscureText: true, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Current PIN')),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Turn off'))]));
    if (ok != true) return;
    if (await AppLock.disable(p.text)) { setState(() => lockOn = false); _msg('App lock off'); }
    else { final w = await AppLock.waitSeconds(); _msg(w > 0 ? 'Too many attempts. Try again in $w s' : 'Wrong PIN'); }
  }

  @override Widget build(BuildContext ctx) {
    final mine = c.userDeviceKeys[c.userID]?.deviceKeys ?? {};
    final crossSigned = c.encryption?.crossSigning.enabled ?? false;
    final backup = c.encryption?.keyManager.enabled ?? false;
    return Scaffold(appBar: AppBar(title: const Text('Security')), body: RefreshIndicator(onRefresh: _load, child: ListView(children: [
      ListTile(title: Text('Encrypted backup', style: Theme.of(ctx).textTheme.titleSmall)),
      ListTile(leading: Icon(backup && crossSigned ? Icons.cloud_done : Icons.cloud_off, color: backup && crossSigned ? Colors.green : Colors.orange),
        title: Text(backup && crossSigned ? 'Chat history is backed up' : 'Set up secure backup'),
        subtitle: const Text('Keeps your encryption keys in an encrypted backup so old messages open on a new device'),
        trailing: FilledButton.tonal(onPressed: backup && crossSigned ? _restore : _backup, child: Text(backup && crossSigned ? 'Restore here' : 'Set up'))),
      const Divider(),
      ListTile(title: Text('Your devices', style: Theme.of(ctx).textTheme.titleSmall), subtitle: const Text('Verify new devices by comparing emoji, so nobody can impersonate you')),
      for (final d in devices) () {
        final dk = mine[d.deviceId]; final current = d.deviceId == c.deviceID;
        return ListTile(
          leading: Icon(current ? Icons.smartphone : Icons.devices, color: dk?.verified == true ? Colors.green : null),
          title: Text('${d.displayName ?? d.deviceId}${current ? ' (this device)' : ''}'),
          subtitle: Text('${d.deviceId} · ${dk?.verified == true ? 'verified' : 'not verified'}${d.lastSeenTs != null ? ' · last seen ${DateTime.fromMillisecondsSinceEpoch(d.lastSeenTs!).toLocal().toString().substring(0, 16)}' : ''}'),
          trailing: current ? null : PopupMenuButton<String>(onSelected: (a) { if (a == 'verify' && dk != null) _verify(dk); if (a == 'out') _signOut(d); },
            itemBuilder: (_) => [if (dk != null && !dk.verified) const PopupMenuItem(value: 'verify', child: Text('Verify')), const PopupMenuItem(value: 'out', child: Text('Sign out'))]));
      }(),
      const Divider(),
      ListTile(leading: const Icon(Icons.language), title: Text(t(context, 'Language')),
        subtitle: Text({'system': t(context, 'System'), 'en': 'English', 'ar': 'العربية'}[AppLocale.instance.mode]!),
        onTap: () async {
          final v = await showDialog<String>(context: context, builder: (d) => SimpleDialog(title: Text(t(context, 'Language')), children: [
            for (final (k, l) in [('system', t(context, 'System')), ('en', 'English'), ('ar', 'العربية (من اليمين إلى اليسار)')])
              SimpleDialogOption(onPressed: () => Navigator.pop(d, k), child: Text(l))]));
          if (v != null) { await AppLocale.instance.set(v); if (mounted) setState(() {}); }
        }),
      ListTile(leading: const Icon(Icons.accessibility_new), title: const Text('Accessibility'), subtitle: const Text('Text size, high contrast, motion, captions, shortcuts'),
        onTap: () => Navigator.push(context, MaterialPageRoute(builder: (_) => const A11yScreen()))),
      SwitchListTile(secondary: const Icon(Icons.pin), title: const Text('App lock'), subtitle: const Text('Ask for a PIN when you return to the app'),
        value: lockOn ?? false, onChanged: (v) async { if (v) { await _setPin(); } else { await _disableLock(); } }),
    ])));
  }
}

/// Emoji verification dialog, used for both directions.
Future<void> showVerification(BuildContext context, KeyVerification v) async {
  await showDialog(context: context, barrierDismissible: false, builder: (d) => StatefulBuilder(builder: (d, set) {
    v.onUpdate = () {
      // diagnostics for the in-use test: the inputs both devices must agree on (no secrets)
      debugPrint('VERIFY state=${v.state.name} txid=${v.transactionId} other=${v.userId}/${v.deviceId} started_by_me=${v.startedVerification} last=${v.lastStep}');
      if (d.mounted) set(() {});
    };
    final close = () => Navigator.of(d).pop();
    Widget body; List<Widget> actions;
    switch (v.state) {
      case KeyVerificationState.askAccept:
        body = Text('${v.userId} wants to verify a device.');
        actions = [TextButton(onPressed: () { v.rejectVerification(); close(); }, child: const Text('Decline')), FilledButton(onPressed: () => v.acceptVerification(), child: const Text('Start'))];
      case KeyVerificationState.askSas:
        body = Column(mainAxisSize: MainAxisSize.min, children: [
          const Text('Check that both screens show the same emoji, in the same order.'), const SizedBox(height: 12),
          Wrap(spacing: 12, runSpacing: 8, alignment: WrapAlignment.center, children: [for (final e in v.sasEmojis) Column(children: [Text(e.emoji, style: const TextStyle(fontSize: 32)), Text(e.name, style: const TextStyle(fontSize: 11))])])]);
        actions = [TextButton(onPressed: () { v.rejectSas(); close(); }, child: const Text('They don’t match')), FilledButton(onPressed: () => v.acceptSas(), child: const Text('They match'))];
      case KeyVerificationState.done:
        body = const Row(children: [Icon(Icons.verified, color: Colors.green), SizedBox(width: 8), Expanded(child: Text('Verified. Messages and calls with this device are trusted.'))]);
        actions = [FilledButton(onPressed: close, child: const Text('Done'))];
      case KeyVerificationState.error:
        body = Text('Verification was cancelled${v.canceledReason != null ? ': ${v.canceledReason}' : ''}.');
        actions = [FilledButton(onPressed: close, child: const Text('Close'))];
      default:
        body = const Row(children: [CircularProgressIndicator(), SizedBox(width: 16), Expanded(child: Text('Waiting for the other device…'))]);
        actions = [TextButton(onPressed: () { v.cancel(); close(); }, child: const Text('Cancel'))];
    }
    return AlertDialog(title: const Text('Verify device'), content: body, actions: actions);
  }));
}
