import 'package:flutter/material.dart';
/// One role vocabulary for chats, channels and teams (docs/NAMING.md), from Matrix power levels:
/// 100 = Owner, 50 = Moderator, otherwise Member. Meetings use Teams' own roles instead
/// (Organiser, Co-organiser, Presenter, Attendee: docs/MEETING_OPTIONS.md).
const kOwnerLevel = 100, kModeratorLevel = 50;

String roleName(int level) => level >= kOwnerLevel ? 'Owner' : level >= kModeratorLevel ? 'Moderator' : 'Member';

/// One rule for actions that cannot be undone (docs/NAMING.md): ask first, name the thing, say it cannot be undone.
Future<bool> confirmDestructive(BuildContext context, String action, String detail) async =>
    await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text('$action?'), content: Text('$detail This cannot be undone.'),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
        FilledButton(style: FilledButton.styleFrom(backgroundColor: Colors.red), onPressed: () => Navigator.pop(d, true), child: Text(action))])) == true;
