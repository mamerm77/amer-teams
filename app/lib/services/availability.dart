import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart' show HardwareKeyboard, KeyEvent;
import 'package:matrix/matrix.dart';
import 'api_service.dart';

/// Presence, following Microsoft Teams' rules (docs/PRESENCE.md):
/// - **You set** Available, Busy, Do not disturb, Be right back, Appear away or Appear offline, with a message.
///   If you don't choose a duration, Teams' defaults apply: Busy and Do not disturb for 1 day, Appear offline until
///   you change it, the others for 7 days. Choosing Available (with no message) goes back to automatic.
/// - **The app sets** (when you have not chosen otherwise): Away after 5 minutes without input, or when the app is
///   in the background; In a call / In a meeting while you are in one; Presenting while you share your screen.
///   Do not disturb and Appear offline that you set still win during calls.
/// - **Do not disturb / Presenting**: messages still arrive but no banners; calls are declined as busy; people on
///   your priority list (Notifications → Priority people) still get through with banners and calls. Push
///   notifications are held by the server (focus mode) with the same exception.
/// Matrix presence only knows online / unavailable / offline, so the finer state travels as a tag at the start of
/// the status message ("[busy] In a review"); your choice is kept in account data so all your devices agree.
enum Avail { available, busy, dnd, brb, away, offline, call, meeting, presenting, focusing, ooo }

class Availability {
  Availability._();
  static final instance = Availability._();
  static const _key = 'com.amerteams.availability';
  static const idleAfter = Duration(minutes: 5);
  final state = ValueNotifier<(Avail, String)>((Avail.available, ''));
  Client? _c; Timer? _t; ApiService? api;
  DateTime _lastInput = DateTime.now(); bool _foreground = true;
  String? _activity;
  (Avail, String)? _overlay;                 // Focus or Out of office, reported by those features (one place decides presence)                         // 'call' | 'meeting' | 'presenting' while in one (set by the call screen)
  List<String> priority = [];                // priority people: break through Do not disturb
  String _published = '';

  static String label(Avail a) => const {Avail.available: 'Available', Avail.busy: 'Busy', Avail.dnd: 'Do not disturb', Avail.brb: 'Be right back',
    Avail.away: 'Away', Avail.offline: 'Appear offline', Avail.call: 'In a call', Avail.meeting: 'In a meeting', Avail.presenting: 'Presenting', Avail.focusing: 'Focusing', Avail.ooo: 'Out of office'}[a]!;
  static Color colour(Avail a) => switch (a) { Avail.available => Colors.green, Avail.busy || Avail.dnd || Avail.call || Avail.meeting || Avail.presenting || Avail.focusing => Colors.red, Avail.ooo => Colors.purple,
    Avail.brb || Avail.away => Colors.amber, Avail.offline => Colors.grey };
  static IconData icon(Avail a) => switch (a) { Avail.dnd || Avail.presenting => Icons.remove_circle, Avail.brb || Avail.away => Icons.schedule, Avail.offline => Icons.cancel_outlined,
    Avail.call => Icons.call, Avail.meeting => Icons.videocam, Avail.focusing => Icons.headphones, Avail.ooo => Icons.flight_takeoff, _ => Icons.circle };
  static const manualChoices = [Avail.available, Avail.busy, Avail.dnd, Avail.brb, Avail.away, Avail.offline];

  /// Teams' default duration when you set a status without choosing one.
  static DateTime? defaultUntil(Avail a, DateTime now) => switch (a) {
    Avail.busy || Avail.dnd => now.add(const Duration(days: 1)), Avail.offline || Avail.available => null, _ => now.add(const Duration(days: 7)) };

  /// Reads someone's state from their presence (tag in the status message, else the plain presence).
  static (Avail, String) parse(CachedPresence? p) {
    final raw = p?.statusMsg ?? '';
    final m = RegExp(r'^\[(busy|dnd|brb|away|call|meeting|presenting|focusing|ooo)\]\s*').firstMatch(raw);
    if (m != null) return (Avail.values.byName(m.group(1)!), raw.substring(m.end));
    final a = switch (p?.presence) { PresenceType.online => Avail.available, PresenceType.unavailable => Avail.away, _ => Avail.offline };
    return (a, raw);
  }

  Future<void> start(Client c, {ApiService? api}) async {
    _c = c; this.api = api ?? this.api; _t?.cancel();
    _t = Timer.periodic(const Duration(seconds: 30), (_) => _refresh());
    try { final s = await this.api?.getMap('/v1/notify/settings'); priority = ((s?['priority_senders'] as List?) ?? const []).map((x) => '$x').toList(); } catch (_) {}
    await _refresh();
  }

  // ---- signals from the app ----
  void input() { final wasIdle = _idle; _lastInput = DateTime.now(); if (wasIdle) _refresh(); }
  void foreground(bool on) { _foreground = on; if (on) _lastInput = DateTime.now(); _refresh(); }
  void activity(String? a) { _activity = a; _refresh(); }       // the call screen: 'call', 'meeting', 'presenting' or null
  /// Focus (Avail.focusing) and Out of office (Avail.ooo) report here instead of setting presence themselves.
  void overlay(Avail? a, [String msg = '']) { _overlay = a == null ? null : (a, msg); _published = ''; _refresh(); }
  bool get _idle => !_foreground || DateTime.now().difference(_lastInput) > idleAfter;

  Map<String, Object?> get _saved => _c?.accountData[_key]?.content ?? const {};
  (Avail?, String) get _manual {
    final s = _saved; final until = s['until'];
    if (until is int && DateTime.now().millisecondsSinceEpoch > until) return (null, '');
    final a = Avail.values.asNameMap()[s['state']];
    return (a == Avail.available ? null : a, '${s['msg'] ?? ''}');
  }

  /// What everyone sees now, from your choice and what the app knows (Teams' precedence).
  (Avail, String) get effective {
    final (m, msg) = _manual;
    // Teams' precedence: what you set as Do not disturb / Appear offline; then calls and meetings; then Focus;
    // then Out of office; then the rest of what you set; then automatic Away / Available.
    if (m == Avail.offline || m == Avail.dnd) return (m!, msg);
    if (_activity == 'presenting') return (Avail.presenting, msg);
    if (_activity == 'meeting') return (Avail.meeting, msg);
    if (_activity == 'call') return (Avail.call, msg);
    final o = _overlay;
    if (o != null) return (o.$1, msg.isNotEmpty ? msg : o.$2);
    if (m != null) return (m, msg);
    if (_idle) return (Avail.away, msg);
    return (Avail.available, msg);
  }

  Future<void> _refresh() async {
    final s = _saved; final until = s['until'];
    if (until is int && DateTime.now().millisecondsSinceEpoch > until && s['state'] != null && s['state'] != 'available') {
      await set(Avail.available, '', until: null); return;                  // the chosen duration ended: back to automatic
    }
    await _publish();
  }

  Future<void> _publish() async {
    final c = _c; if (c == null || c.userID == null) return;
    final (a, msg) = effective; state.value = (a, msg);
    final tag = switch (a) { Avail.available => '', Avail.offline => '', _ => '[${a.name}] ' };
    final presence = switch (a) { Avail.offline => PresenceType.offline, Avail.away || Avail.brb || Avail.ooo => PresenceType.unavailable, _ => PresenceType.online };
    final key = '${presence.name}|$tag$msg';
    if (key == _published) return;
    _published = key;
    try { await c.setPresence(c.userID!, presence, statusMsg: '$tag$msg'.trim()); } catch (_) {}
  }

  /// Your choice. [until] null = Teams' default duration for that state.
  Future<void> set(Avail a, String msg, {DateTime? until, bool useDefault = true}) async {
    final c = _c; if (c == null || c.userID == null) return;
    final end = until ?? (useDefault ? defaultUntil(a, DateTime.now()) : null);
    await c.setAccountData(c.userID!, _key, {'state': a.name, 'msg': msg, if (end != null) 'until': end.millisecondsSinceEpoch});
    _published = ''; await _publish();
    try {   // Do not disturb holds push notifications on the server too (priority people get through)
      final mins = a == Avail.dnd ? ((end ?? DateTime.now().add(const Duration(days: 1))).difference(DateTime.now()).inMinutes).clamp(1, 7 * 24 * 60) : 0;
      await api?.postMap('/v1/notify/focus', {'minutes': mins});
    } catch (_) {}
  }

  /// Banners and ringing are held in Do not disturb and while presenting, except for priority people.
  bool get quiet => state.value.$1 == Avail.dnd || state.value.$1 == Avail.presenting || state.value.$1 == Avail.focusing;
  bool holds(String? sender) => quiet && !priority.contains(sender);
  bool get doNotDisturb => state.value.$1 == Avail.dnd;
}

/// Reports input and app lifecycle to presence (Away after 5 minutes idle or in the background).
class PresenceActivity extends StatefulWidget {
  const PresenceActivity({super.key, required this.child}); final Widget child;
  @override State<PresenceActivity> createState() => _PA();
}
class _PA extends State<PresenceActivity> with WidgetsBindingObserver {
  @override void initState() { super.initState(); WidgetsBinding.instance.addObserver(this); HardwareKeyboard.instance.addHandler(_key); }
  @override void dispose() { WidgetsBinding.instance.removeObserver(this); HardwareKeyboard.instance.removeHandler(_key); super.dispose(); }
  bool _key(KeyEvent e) { Availability.instance.input(); return false; }
  @override void didChangeAppLifecycleState(AppLifecycleState s) => Availability.instance.foreground(s == AppLifecycleState.resumed);
  @override Widget build(BuildContext c) => Listener(behavior: HitTestBehavior.translucent,
    onPointerDown: (_) => Availability.instance.input(), onPointerHover: (_) => Availability.instance.input(), onPointerSignal: (_) => Availability.instance.input(),
    child: widget.child);
}

/// The Teams status dialog: your status, message, and how long it lasts.
Future<void> showAvailability(BuildContext c) async {
  final cur = Availability.instance.state.value;
  var a = Availability.manualChoices.contains(cur.$1) ? cur.$1 : Avail.available; final msg = TextEditingController(text: cur.$2); var clear = 'default';
  final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
    title: const Text('Set status'),
    content: SizedBox(width: 400, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      if (!Availability.manualChoices.contains(cur.$1)) Padding(padding: const EdgeInsets.only(bottom: 8), child: Text('Now: ${Availability.label(cur.$1)} (set automatically)', style: Theme.of(d).textTheme.bodySmall)),
      for (final v in Availability.manualChoices) RadioListTile<Avail>(dense: true, value: v, groupValue: a, onChanged: (x) => set(() => a = x!),
        title: Row(children: [Icon(Availability.icon(v), size: 14, color: Availability.colour(v)), const SizedBox(width: 8), Text(v == Avail.available ? 'Available (automatic)' : v == Avail.away ? 'Appear away' : Availability.label(v))])),
      const SizedBox(height: 8),
      TextField(controller: msg, maxLength: 280, decoration: const InputDecoration(labelText: 'Status message', hintText: 'e.g. In a design review until 3 pm')),
      DropdownButtonFormField<String>(value: clear, decoration: const InputDecoration(labelText: 'Duration'), items: [
        DropdownMenuItem(value: 'default', child: Text(switch (a) { Avail.busy || Avail.dnd => 'Default: 1 day', Avail.offline => 'Default: until I change it', Avail.available => 'Default', _ => 'Default: 7 days' })),
        const DropdownMenuItem(value: '30m', child: Text('30 minutes')), const DropdownMenuItem(value: '1h', child: Text('1 hour')), const DropdownMenuItem(value: '2h', child: Text('2 hours')),
        const DropdownMenuItem(value: 'today', child: Text('Today')), const DropdownMenuItem(value: 'week', child: Text('This week')), const DropdownMenuItem(value: 'never', child: Text('Until I change it'))],
        onChanged: (v) => set(() => clear = v ?? 'default')),
      Padding(padding: const EdgeInsets.only(top: 8), child: Text('Automatic: Away after 5 minutes idle, In a call or In a meeting while you are in one, Presenting while you share. Do not disturb sends calls to busy and hides banners, except for your priority people.',
        style: Theme.of(d).textTheme.bodySmall)),
    ]))),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Done'))])));
  if (ok != true) return;
  final now = DateTime.now();
  final until = switch (clear) {
    '30m' => now.add(const Duration(minutes: 30)), '1h' => now.add(const Duration(hours: 1)), '2h' => now.add(const Duration(hours: 2)),
    'today' => DateTime(now.year, now.month, now.day, 23, 59), 'week' => DateTime(now.year, now.month, now.day + (7 - now.weekday), 23, 59), _ => null };
  await Availability.instance.set(a, msg.text.trim(), until: until, useDefault: clear == 'default');
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Status: ${Availability.label(a)}${msg.text.trim().isEmpty ? '' : ' · ${msg.text.trim()}'}')));
}
