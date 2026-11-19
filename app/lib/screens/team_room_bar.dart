import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import 'call_screen.dart';

/// Ambient presence (docs/AMBIENT.md): who is in the team's drop-in room right now, and one tap to join muted.
class TeamRoomBar extends StatefulWidget {
  const TeamRoomBar({super.key, required this.room});
  final Room room;
  @override State<TeamRoomBar> createState() => _S();
}
class _S extends State<TeamRoomBar> {
  List<dynamic> here = []; Timer? t;
  @override void initState() { super.initState(); _poll(); t = Timer.periodic(const Duration(seconds: 30), (_) => _poll()); }
  @override void dispose() { t?.cancel(); super.dispose(); }
  Future<void> _poll() async {
    try { final r = await context.read<ApiService>().getMap('/v1/ambient/${Uri.encodeComponent(widget.room.id)}'); if (mounted) setState(() => here = r['here'] as List); } catch (_) {}
  }
  @override
  Widget build(BuildContext c) {
    final names = here.map((p) => '${p['name']}').toList();
    return Material(color: Theme.of(c).colorScheme.surfaceContainerLow, child: InkWell(
      onTap: () async { await Navigator.push(c, MaterialPageRoute(builder: (_) => CallScreen(roomId: widget.room.id, meeting: true, video: false, ambient: true))); _poll(); },
      child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), child: Row(children: [
        Icon(Icons.weekend_outlined, size: 18, color: names.isEmpty ? null : Colors.green),
        const SizedBox(width: 8),
        Expanded(child: Text(names.isEmpty ? 'Team room: nobody here · drop in muted' : 'Team room: ${names.take(3).join(', ')}${names.length > 3 ? ' +${names.length - 3}' : ''}',
          overflow: TextOverflow.ellipsis, style: Theme.of(c).textTheme.bodySmall)),
        Text('Drop in', style: TextStyle(color: Theme.of(c).colorScheme.primary, fontSize: 12)),
      ]))));
  }
}
