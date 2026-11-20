import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'people_picker.dart';

/// Meeting options (Microsoft Teams parity, docs/MEETING_OPTIONS.md): set before or during a meeting by organisers.
/// Stored in the chat's meeting settings (state event), so they apply to every meeting in that chat and every device.
/// Who can present is enforced by the server (media token); the others are enforced by every participant's app.
const kMeetingSettings = 'com.amerteams.meeting.settings';

Map<String, Object?> meetingOptionsOf(Room r) => Map<String, Object?>.from(r.getState(kMeetingSettings)?.content ?? {});
bool optAllowMic(Room r, String me) => meetingOptionsOf(r)['allow_mic'] != false || r.getPowerLevelByUserId(me).level >= 50 || isPresenter(r, me);
bool optAllowCamera(Room r, String me) => meetingOptionsOf(r)['allow_camera'] != false || r.getPowerLevelByUserId(me).level >= 50 || isPresenter(r, me);
bool optChat(Room r, String me) { final v = meetingOptionsOf(r)['chat'] ?? 'on'; return v == 'on' || (v == 'organisers' && r.getPowerLevelByUserId(me).level >= 50); }
bool optReactions(Room r) => meetingOptionsOf(r)['reactions'] != false;
bool isPresenter(Room r, String me) => ((meetingOptionsOf(r)['presenters'] as List?) ?? const []).contains(me);

class MeetingOptionsScreen extends StatefulWidget {
  const MeetingOptionsScreen({super.key, required this.roomId}); final String roomId;
  @override State<MeetingOptionsScreen> createState() => _S();
}
class _S extends State<MeetingOptionsScreen> {
  late Map<String, Object?> o; bool saving = false;
  Room get room => context.read<MatrixService>().client.getRoomById(widget.roomId)!;
  @override void initState() { super.initState(); o = meetingOptionsOf(context.read<MatrixService>().client.getRoomById(widget.roomId)!); }
  bool get canEdit => room.getPowerLevelByUserId(room.client.userID!).level >= 50;

  Future<void> _save() async {
    setState(() => saving = true);
    try {
      await room.client.setRoomStateWithKey(room.id, kMeetingSettings, '', o);
      final lobby = '${o['lobby'] ?? 'invited'}';
      final want = lobby == 'everyone' ? JoinRules.knock : JoinRules.invite;  // invited people go straight in; others ask (knock) only when allowed
      if (room.joinRules != want) { try { await room.setJoinRules(want); } catch (_) {} }
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Meeting options saved for everyone'))); Navigator.pop(context); }
    } catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('Could not save: $e'))); }
    if (mounted) setState(() => saving = false);
  }

  Widget _choice(String key, String title, String help, List<(String, String)> opts, String def) => ListTile(
    title: Text(title), subtitle: Text(help),
    trailing: DropdownButton<String>(value: opts.any((x) => x.$1 == (o[key] ?? def)) ? '${o[key] ?? def}' : def,
      items: [for (final (v, l) in opts) DropdownMenuItem(value: v, child: Text(l))], onChanged: canEdit ? (v) => setState(() => o[key] = v) : null));
  Widget _switch(String key, String title, String help) => SwitchListTile(title: Text(title), subtitle: Text(help), value: o[key] != false, onChanged: canEdit ? (v) => setState(() => o[key] = v) : null);

  @override Widget build(BuildContext c) {
    final presenters = ((o['presenters'] as List?) ?? const []).map((x) => '$x').toList();
    return Scaffold(
      appBar: AppBar(title: const Text('Meeting options'), actions: [if (canEdit) Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton(onPressed: saving ? null : _save, child: const Text('Save')))]),
      body: ListView(children: [
        if (!canEdit) const MaterialBanner(content: Text('Only organisers can change these options.'), actions: [SizedBox.shrink()]),
        const _H('Joining'),
        _choice('lobby', 'Who can bypass the lobby', 'Others wait until an organiser admits them',
          const [('invited', 'People in this chat'), ('everyone', 'Anyone with the meeting ID can ask to join'), ('organisers', 'Only organisers')], 'invited'),
        const _H('Presenting'),
        _choice('who_presents', 'Who can present', 'Presenters can talk, turn on video and share their screen. Enforced by the server',
          const [('everyone', 'Everyone'), ('organisers', 'Only organisers'), ('specific', 'Specific people')], 'everyone'),
        if (o['who_presents'] == 'specific') ...[
          for (final p in presenters) ListTile(dense: true, leading: const Icon(Icons.co_present_outlined), title: Text(room.unsafeGetUserFromMemoryOrFallback(p).calcDisplayname()),
            trailing: canEdit ? IconButton(icon: const Icon(Icons.close), onPressed: () => setState(() => o['presenters'] = presenters.where((x) => x != p).toList())) : null),
          if (canEdit) Align(alignment: Alignment.centerLeft, child: Padding(padding: const EdgeInsets.only(left: 16), child: TextButton.icon(icon: const Icon(Icons.person_add), label: const Text('Choose presenters'), onPressed: () async {
            final p = await pickPeople(c, multiple: true, title: 'Presenters'); if (p != null) setState(() => o['presenters'] = {...presenters, ...p.map((x) => x.userId)}.toList()); }))),
        ],
        const _H('Attendees'),
        _switch('allow_mic', 'Allow mic for attendees', 'When off, only organisers and presenters can unmute'),
        _switch('allow_camera', 'Allow camera for attendees', 'When off, only organisers and presenters can turn on video'),
        _choice('chat', 'Meeting chat', 'Messages in the meeting', const [('on', 'On'), ('organisers', 'Only organisers can send'), ('off', 'Off')], 'on'),
        _switch('reactions', 'Allow reactions', 'Live emoji reactions during the meeting'),
        const _H('Amer'),
        _switch('ai_allowed', 'Allow Amer minutes and captions', 'When off, nobody can turn on Amer in this chat\'s meetings'),
        const Padding(padding: EdgeInsets.all(16), child: Text('These options apply to every meeting in this chat. Changes reach people already in the meeting straight away.', style: TextStyle(fontSize: 12))),
      ]));
  }
}

class _H extends StatelessWidget { const _H(this.t); final String t;
  @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), child: Text(t, style: Theme.of(c).textTheme.titleSmall?.copyWith(color: Theme.of(c).colorScheme.primary))); }
