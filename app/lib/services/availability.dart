import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';

/// Teams-style availability: Available, Busy, Do not disturb, Be right back, Appear away, Appear offline, plus a
/// status message that clears itself after a chosen time. Matrix presence only knows online / unavailable / offline,
/// so the finer state travels as a tag at the start of the status message ("[busy] In a review") and is kept in
/// account data so every device of mine shows and expires the same thing.
enum Avail { available, busy, dnd, brb, away, offline }

class Availability {
  Availability._();
  static final instance = Availability._();
  static const _key = 'com.amerteams.availability';
  final state = ValueNotifier<(Avail, String)>((Avail.available, ''));
  Client? _c; Timer? _t;

  static String label(Avail a) => const {Avail.available: 'Available', Avail.busy: 'Busy', Avail.dnd: 'Do not disturb', Avail.brb: 'Be right back', Avail.away: 'Appear away', Avail.offline: 'Appear offline'}[a]!;
  static Color colour(Avail a) => switch (a) { Avail.available => Colors.green, Avail.busy || Avail.dnd => Colors.red, Avail.brb || Avail.away => Colors.amber, Avail.offline => Colors.grey };
  static IconData icon(Avail a) => switch (a) { Avail.dnd => Icons.remove_circle, Avail.brb || Avail.away => Icons.schedule, Avail.offline => Icons.cancel_outlined, _ => Icons.circle };

  /// Reads someone's state from their presence (tag in the status message, else the plain presence).
  static (Avail, String) parse(CachedPresence? p) {
    final raw = p?.statusMsg ?? '';
    final m = RegExp(r'^\[(busy|dnd|brb|away)\]\s*').firstMatch(raw);
    if (m != null) return (Avail.values.byName(m.group(1)!), raw.substring(m.end));
    final a = switch (p?.presence) { PresenceType.online => Avail.available, PresenceType.unavailable => Avail.away, _ => Avail.offline };
    return (a, raw);
  }

  Future<void> start(Client c) async {
    _c = c; _t?.cancel();
    _t = Timer.periodic(const Duration(minutes: 1), (_) => _expire());
    await _expire();
  }

  Map<String, Object?> get _saved => _c?.accountData[_key]?.content ?? const {};

  Future<void> _expire() async {
    final s = _saved; final until = s['until'];
    final a = Avail.values.asNameMap()[s['state']] ?? Avail.available; var msg = '${s['msg'] ?? ''}';
    if (until is int && DateTime.now().millisecondsSinceEpoch > until) { await set(a == Avail.available ? Avail.available : a, '', until: null, resetAvail: true); return; }
    state.value = (a, msg);
  }

  /// [until] clears the message (and a temporary state) at that time; null keeps it until changed.
  Future<void> set(Avail a, String msg, {DateTime? until, bool resetAvail = false}) async {
    final c = _c; if (c == null || c.userID == null) return;
    final finalA = resetAvail ? Avail.available : a;
    final tag = switch (finalA) { Avail.busy => '[busy] ', Avail.dnd => '[dnd] ', Avail.brb => '[brb] ', Avail.away => '[away] ', _ => '' };
    final presence = switch (finalA) { Avail.available || Avail.busy || Avail.dnd => PresenceType.online, Avail.brb || Avail.away => PresenceType.unavailable, Avail.offline => PresenceType.offline };
    await c.setPresence(c.userID!, presence, statusMsg: '$tag$msg'.trim());
    await c.setAccountData(c.userID!, _key, {'state': finalA.name, 'msg': msg, if (until != null) 'until': until.millisecondsSinceEpoch});
    state.value = (finalA, msg);
  }

  bool get doNotDisturb => state.value.$1 == Avail.dnd;
}

/// The Teams status dialog: availability, message, "Clear status message after".
Future<void> showAvailability(BuildContext c) async {
  final cur = Availability.instance.state.value;
  var a = cur.$1; final msg = TextEditingController(text: cur.$2); var clear = 'never';
  final ok = await showDialog<bool>(context: c, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(
    title: const Text('Set status'),
    content: SizedBox(width: 380, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final v in Avail.values) RadioListTile<Avail>(dense: true, value: v, groupValue: a, onChanged: (x) => set(() => a = x!),
        title: Row(children: [Icon(Availability.icon(v), size: 14, color: Availability.colour(v)), const SizedBox(width: 8), Text(Availability.label(v))])),
      const SizedBox(height: 8),
      TextField(controller: msg, maxLength: 280, decoration: const InputDecoration(labelText: 'Status message', hintText: 'e.g. In a design review until 3 pm')),
      DropdownButtonFormField<String>(value: clear, decoration: const InputDecoration(labelText: 'Clear status after'), items: const [
        DropdownMenuItem(value: 'never', child: Text('Never')), DropdownMenuItem(value: '30m', child: Text('30 minutes')),
        DropdownMenuItem(value: '1h', child: Text('1 hour')), DropdownMenuItem(value: '4h', child: Text('4 hours')),
        DropdownMenuItem(value: 'today', child: Text('Today')), DropdownMenuItem(value: 'week', child: Text('This week'))],
        onChanged: (v) => set(() => clear = v ?? 'never')),
    ])),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Done'))])));
  if (ok != true) return;
  final now = DateTime.now();
  final until = switch (clear) {
    '30m' => now.add(const Duration(minutes: 30)), '1h' => now.add(const Duration(hours: 1)), '4h' => now.add(const Duration(hours: 4)),
    'today' => DateTime(now.year, now.month, now.day, 23, 59), 'week' => DateTime(now.year, now.month, now.day + (7 - now.weekday), 23, 59), _ => null };
  await Availability.instance.set(a, msg.text.trim(), until: until);
  if (c.mounted) ScaffoldMessenger.of(c).showSnackBar(SnackBar(content: Text('Status: ${Availability.label(a)}${msg.text.trim().isEmpty ? '' : ' · ${msg.text.trim()}'}')));
}
