import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';
import '../services/matrix_service.dart';

/// Quiet hours and priority senders (docs/NOTIFICATIONS.md). Kept on the server's push filter, so they apply to
/// every phone and tablet you use; per-chat levels are your Matrix push rules.
class NotificationsScreen extends StatefulWidget {
  const NotificationsScreen({super.key});
  @override State<NotificationsScreen> createState() => _S();
}

class _S extends State<NotificationsScreen> {
  Map<String, dynamic>? s; String? err;
  ApiService get api => context.read<ApiService>();
  @override void initState() { super.initState(); api.notifySettings().then((v) { if (mounted) setState(() => s = v); }).catchError((e) { if (mounted) setState(() => err = '$e'); }); }
  Map<String, dynamic> get q => (s!['quiet'] as Map).cast<String, dynamic>();
  Future<void> _save() async {
    try { await api.saveNotifySettings(s!); if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Notification settings saved'))); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'))); }
  }
  Future<void> _time(String key) async {
    final p = '${q[key]}'.split(':');
    final t = await showTimePicker(context: context, initialTime: TimeOfDay(hour: int.parse(p[0]), minute: int.parse(p[1])));
    if (t != null) setState(() => s!['quiet'] = {...q, key: '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}'});
  }
  @override Widget build(BuildContext c) {
    if (s == null) return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Notifications'))), body: Center(child: err != null ? Text(err!) : const CircularProgressIndicator()));
    final cl = context.read<MatrixService>().client;
    final prio = (s!['priority_senders'] as List).cast<String>();
    final people = {for (final r in cl.rooms.where((r) => r.isDirectChat && r.directChatMatrixID != null)) r.directChatMatrixID!: r.getLocalizedDisplayname()};
    const names = ['Mon', 'Tue', 'Wed', 'Thu', 'Fri', 'Sat', 'Sun'];
    final days = (q['days'] as List).cast<int>().toSet();
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'Notifications')), actions: [TextButton(onPressed: _save, child: Text(L.t(context, 'Save')))]), body: ListView(children: [
      SwitchListTile(secondary: const Icon(Icons.bedtime_outlined), title: const Text('Quiet hours'), subtitle: const Text('Hold notifications at these times. Messages still arrive; you see them when you open the app.'),
        value: q['enabled'] == true, onChanged: (v) => setState(() => s!['quiet'] = {...q, 'enabled': v})),
      if (q['enabled'] == true) ...[
        ListTile(leading: const Icon(Icons.schedule), title: Text('From ${q['start']} to ${q['end']}'), subtitle: const Text('Tap the times to change them'),
          trailing: Wrap(children: [TextButton(onPressed: () => _time('start'), child: Text(L.t(context, 'Start'))), TextButton(onPressed: () => _time('end'), child: Text(L.t(context, 'End')))])),
        Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Wrap(spacing: 4, children: [for (var i = 0; i < 7; i++) FilterChip(label: Text(names[i]), selected: days.contains(i),
          onSelected: (v) => setState(() { v ? days.add(i) : days.remove(i); s!['quiet'] = {...q, 'days': days.toList()..sort()}; }))])),
        SwitchListTile(title: const Text('Let mentions, direct messages and calls through'), value: q['allow_high'] != false, onChanged: (v) => setState(() => s!['quiet'] = {...q, 'allow_high': v})),
      ],
      const Divider(),
      const ListTile(title: Text('Priority senders'), subtitle: Text('Always notify for these people, even in quiet hours')),
      for (final e in people.entries) CheckboxListTile(title: Text(e.value), subtitle: Text(e.key), value: prio.contains(e.key),
        onChanged: (v) => setState(() => s!['priority_senders'] = v == true ? [...prio, e.key] : prio.where((x) => x != e.key).toList())),
      const Divider(),
      const ListTile(leading: Icon(Icons.info_outline), title: Text('Per chat'), subtitle: Text('Chat info → Notifications: All, Mentions only, or Off')),
    ]));
  }
}

/// Per-chat notification level, using the server's push rules for this room.
Future<void> chooseChatNotifications(BuildContext c, Room room) async {
  final v = await showDialog<PushRuleState>(context: c, builder: (d) => SimpleDialog(title: const Text('Notifications for this chat'), children: [
    for (final (st, l) in [(PushRuleState.notify, 'All messages'), (PushRuleState.mentionsOnly, 'Mentions only'), (PushRuleState.dontNotify, 'Off')])
      SimpleDialogOption(onPressed: () => Navigator.pop(d, st), child: Row(children: [Icon(room.pushRuleState == st ? Icons.radio_button_checked : Icons.radio_button_unchecked, size: 18), const SizedBox(width: 8), Text(l)]))]));
  if (v != null) await room.setPushRuleState(v);
}
