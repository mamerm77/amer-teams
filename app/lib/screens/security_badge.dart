import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';

/// Encryption details for a chat (creative feature 8, docs/SECURITY_BADGE.md): which keys protect messages and
/// calls, when this device's message key last rotated, and how many of the members' devices are verified.
/// It states plainly what is and is not quantum-safe.
Future<void> showSecurityDetails(BuildContext context, Room room) async {
  final c = room.client, cs = Theme.of(context).colorScheme;
  final enc = room.getState(EventTypes.Encryption)?.content ?? const {};
  final rotMsgs = (enc['rotation_period_msgs'] as num?)?.toInt() ?? 100;
  final rotMs = (enc['rotation_period_ms'] as num?)?.toInt() ?? const Duration(days: 7).inMilliseconds;
  final out = c.encryption?.keyManager.getOutboundGroupSession(room.id);
  final members = room.getParticipants().where((u) => u.membership == Membership.join).map((u) => u.id).toList();
  var devices = 0, verified = 0, blocked = 0;
  for (final u in members) {
    for (final d in (c.userDeviceKeys[u]?.deviceKeys.values ?? const <DeviceKeys>[])) {
      if (u == c.userID && d.deviceId == c.deviceID) continue;
      devices++; if (d.verified) verified++; if (d.blocked) blocked++;
    }
  }
  String ago(DateTime t) { final d = DateTime.now().difference(t); return d.inDays > 0 ? '${d.inDays} d ago' : d.inHours > 0 ? '${d.inHours} h ago' : '${d.inMinutes} min ago'; }
  Widget row(IconData i, Color col, String t, String s) => ListTile(dense: true, leading: Icon(i, color: col), title: Text(t), subtitle: Text(s));
  await showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => SafeArea(child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
    ListTile(title: Text('Encryption · ${room.getLocalizedDisplayname()}', style: Theme.of(s).textTheme.titleMedium)),
    if (!room.encrypted) row(Icons.lock_open, cs.error, 'Not encrypted', 'Amer Teams refuses to send in this chat'),
    if (room.encrypted) ...[
      row(Icons.lock, Colors.green, 'Messages and files: end-to-end encrypted', 'Megolm (AES-256 with HMAC-SHA-256); keys shared device to device over Olm (Curve25519 double ratchet)'),
      row(Icons.shield_outlined, Colors.orange, 'Messages are not yet quantum-safe', 'Curve25519 key exchange can be broken by a future quantum computer. Post-quantum message keys are planned.'),
      row(Icons.verified_user, Colors.green, 'Calls and meetings: quantum-safe', 'Hybrid ML-KEM-768 + X25519 key per call; check the 6-digit safety code shown during the call'),
      row(Icons.autorenew, cs.primary, out == null ? 'This device has not sent a message key yet' : 'Your message key: created ${DateFormat('d MMM HH:mm').format(out.creationTime)} (${ago(out.creationTime)})',
          out == null ? 'A new key is made when you next send' : 'Used for ${out.sentMessages ?? 0} of $rotMsgs messages; rotates after $rotMsgs messages, ${Duration(milliseconds: rotMs).inDays} days, or when someone leaves'),
      row(verified == devices && devices > 0 ? Icons.verified : Icons.devices, verified == devices && devices > 0 ? Colors.green : cs.outline,
          '$verified of $devices member devices verified', blocked > 0 ? '$blocked blocked: they receive no keys' : 'Verify devices with emoji from Security or the member list'),
    ],
    const SizedBox(height: 8),
  ]))));
}
