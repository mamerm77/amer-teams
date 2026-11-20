import 'dart:typed_data';
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';

/// Team settings for owners, following Microsoft Teams' owner / member / guest rules (docs/TEAM_SETTINGS.md).
/// Wherever Matrix can, the server enforces the setting through power levels, not just the app:
/// - Members can create channels → the team's `m.space.child` permission (0 = members, 50 = owners and admins).
/// - Members can add and remove tabs → each channel's `com.amerteams.channel` permission.
/// - Members can use @channel → each channel's `notifications.room` level (Synapse checks it on every @room).
/// - Archive → every channel becomes read-only (events_default 100) and the team is marked archived; Restore undoes it.
/// - Members can edit and delete their messages → enforced by the app (Matrix always lets people redact their own).
const kTeamSettings = 'com.amerteams.team';

Map<String, Object?> teamSettingsOf(Room team) => Map<String, Object?>.from(team.getState(kTeamSettings)?.content ?? {});
bool teamArchived(Room team) => teamSettingsOf(team)['archived'] == true;
bool membersMayEditDelete(Room? team) => team == null || teamSettingsOf(team)['members_edit_delete'] != false;

class TeamSettingsScreen extends StatefulWidget {
  const TeamSettingsScreen({super.key, required this.teamId}); final String teamId;
  @override State<TeamSettingsScreen> createState() => _S();
}
class _S extends State<TeamSettingsScreen> {
  late Map<String, Object?> o; bool busy = false; String? status;
  MatrixService get m => context.read<MatrixService>();
  Room get team => m.client.getRoomById(widget.teamId)!;
  @override void initState() { super.initState(); o = teamSettingsOf(context.read<MatrixService>().client.getRoomById(widget.teamId)!); }
  bool get owner => team.getPowerLevelByUserId(m.userId).level >= 100;

  Future<void> _pl(Room r, void Function(Map<String, Object?> pl) edit) async {
    final pl = Map<String, Object?>.from(r.getState(EventTypes.RoomPowerLevels)?.content ?? {});
    pl['events'] = Map<String, Object?>.from((pl['events'] as Map?) ?? {});
    pl['notifications'] = Map<String, Object?>.from((pl['notifications'] as Map?) ?? {});
    edit(pl);
    await m.client.setRoomStateWithKey(r.id, EventTypes.RoomPowerLevels, '', pl);
  }

  Future<void> _save() async {
    setState(() { busy = true; status = 'Saving…'; });
    final chans = m.channelsOf(team); var failed = 0;
    try {
      await m.client.setRoomStateWithKey(team.id, kTeamSettings, '', o);
      await _pl(team, (pl) { (pl['events'] as Map)['m.space.child'] = o['members_create_channels'] == false ? 50 : 0;
        if (team.joinRules != JoinRules.public) pl['invite'] = 50; });            // private team: only owners add people (Teams rule)
      for (final ch in chans) {
        try {
          await _pl(ch, (pl) {
            (pl['events'] as Map)['com.amerteams.channel'] = o['members_add_tabs'] == false ? 50 : 0;
            (pl['notifications'] as Map)['room'] = o['members_channel_mention'] == false ? 50 : 0;
            pl['events_default'] = o['archived'] == true ? 100 : 0;          // archived: read-only for everyone but owners
          });
        } catch (_) { failed++; }
      }
      if (mounted) { ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(failed == 0 ? 'Team settings saved and applied to ${chans.length} channels' : 'Saved; $failed channels could not be changed (you are not an owner there)'))); Navigator.pop(context); }
    } catch (e) { if (mounted) setState(() => status = 'Could not save: $e'); }
    if (mounted) setState(() => busy = false);
  }

  Future<void> _picture() async {
    final files = await FilePicker.pickFiles(); if (files.isEmpty) return;
    final f = files.first; final bytes = await f.xFile.readAsBytes();
    setState(() => status = 'Uploading picture…');
    try { await team.setAvatar(MatrixImageFile(bytes: Uint8List.fromList(bytes), name: f.name)); if (mounted) setState(() => status = 'Team picture changed'); }
    catch (e) { if (mounted) setState(() => status = 'Could not change the picture: $e'); }
  }

  Future<void> _rename() async {
    final name = TextEditingController(text: team.getLocalizedDisplayname()), desc = TextEditingController(text: team.topic);
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Edit team'), content: Column(mainAxisSize: MainAxisSize.min, children: [
      TextField(controller: name, decoration: const InputDecoration(labelText: 'Team name')), TextField(controller: desc, decoration: const InputDecoration(labelText: 'Description'))]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
    if (ok != true) return;
    await team.setName(name.text.trim()); await team.setDescription(desc.text.trim()); if (mounted) setState(() {});
  }

  Widget _sw(String k, String title, String sub, {bool def = true}) => SwitchListTile(title: Text(title), subtitle: Text(sub), value: (o[k] ?? def) == true,
    onChanged: owner && !busy ? (v) => setState(() => o[k] = v) : null);

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text('Team settings · ${team.getLocalizedDisplayname()}'), actions: [
      if (owner) Padding(padding: const EdgeInsets.only(right: 8), child: FilledButton(onPressed: busy ? null : _save, child: const Text('Save')))]),
    body: ListView(children: [
      if (!owner) const MaterialBanner(content: Text('Only team owners can change these settings.'), actions: [SizedBox.shrink()]),
      if (status != null) Padding(padding: const EdgeInsets.all(12), child: Text(status!)),
      ListTile(leading: const Icon(Icons.edit), title: const Text('Edit name and description'), enabled: owner, onTap: _rename),
      ListTile(leading: const Icon(Icons.image_outlined), title: const Text('Change team picture'), enabled: owner, onTap: _picture),
      const _H('Member permissions'),
      _sw('members_create_channels', 'Members can create channels', 'Enforced by the server'),
      _sw('members_add_tabs', 'Members can add, remove and change tabs', 'Enforced by the server'),
      _sw('members_edit_delete', 'Members can edit and delete their messages', 'Enforced by the app'),
      const _H('@mentions'),
      _sw('members_channel_mention', 'Members can use @channel', 'Notifies everyone in the channel. Enforced by the server'),
      const _H('Archive'),
      _sw('archived', 'Archive this team', 'Channels become read-only for everyone except owners; you can restore it any time', def: false),
    ]));
}

class _H extends StatelessWidget { const _H(this.t); final String t;
  @override Widget build(BuildContext c) => Padding(padding: const EdgeInsets.fromLTRB(16, 16, 16, 0), child: Text(t, style: Theme.of(c).textTheme.titleSmall?.copyWith(color: Theme.of(c).colorScheme.primary))); }
