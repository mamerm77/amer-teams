import 'package:flutter/material.dart';
import 'apps_screen.dart';
import 'people_screen.dart';
import 'office_screen.dart';
import 'calendar_screen.dart';

/// Help and guide: how to do each common job, in the words people use, with a button that opens the right place.
/// Written for someone coming from Microsoft Teams: where the same thing lives, and what is different here.
class HelpScreen extends StatefulWidget { const HelpScreen({super.key}); @override State<HelpScreen> createState() => _S(); }

class Guide {
  const Guide(this.icon, this.title, this.teams, this.steps, {this.open, this.note});
  final IconData icon; final String title, teams; final List<String> steps; final Widget Function()? open; final String? note;
}

const kGuides = <(String, List<Guide>)>[
  ('Getting started', [
    Guide(Icons.badge_outlined, 'Fill in your contact card', 'Teams: your profile card',
      ['Open People (Apps → People).', 'Tap "My contact details".', 'Add your work email, phone, job title and department, then Save.', 'Colleagues can now find you by any of these.'], open: _people),
    Guide(Icons.person_add, 'Add colleagues to your contacts', 'Teams: Calls → Contacts',
      ['Open People → Contacts → "Add contacts".', 'Search by name, email, phone, job title or department.', 'Tick the people and press Add.', 'Star your favourites: they appear first everywhere you add people.'], open: _people),
    Guide(Icons.groups, 'Make a contact group', 'Teams: contact groups',
      ['People → Groups → "New contact group".', 'Name it (e.g. "Optical team") and choose the people.', 'In any "Add people" box, "Add all" adds the whole group at once.'], open: _people),
    Guide(Icons.mail_outline, 'Invite someone who is not on Amer Teams', 'Teams: invite people to Teams',
      ['In any "Add people" box, type their email or phone number and choose "Invite … to Amer Teams", or use People → "Invite someone new".',
       'Send the message shown (email, WhatsApp or SMS). The link works once, for 14 days.',
       'They create their account in a browser. If you invited them from a team or chat, your app adds them there automatically.',
       'Follow progress in People → Invitations.'], open: _people),
  ]),
  ('Chat', [
    Guide(Icons.chat_bubble_outline, 'Start a chat', 'Teams: New chat',
      ['Go to Chat and press "New encrypted chat".', 'Pick one person for a private chat, or several for a group chat.', 'Everything is end-to-end encrypted: the server cannot read it.']),
    Guide(Icons.priority_high, 'Send an important or urgent message', 'Teams: Set delivery options',
      ['In a chat, press "!" next to the message box.', 'Choose Important (red label) or Urgent: they get an alert now and again every 2 minutes for 20 minutes until they read it.']),
    Guide(Icons.shortcut, 'Forward several messages', 'Teams: Forward',
      ['Open a message\'s menu (⋯) and choose "Select messages".', 'Tap the other messages to add them (up to 20).', 'Press Forward and choose the chat.']),
    Guide(Icons.task_alt, 'Turn a message into a task', 'Teams: Planner from a message',
      ['Open the message\'s menu (⋯) → Create task.', 'Set who owns it and the due date.', 'It appears in Tasks and on the chat\'s Planner board.']),
  ]),
  ('Teams and channels', [
    Guide(Icons.groups_2_outlined, 'Create a team and add people', 'Teams: Join or create a team',
      ['Go to Teams → Create team. Choose private (invite only) or public.', 'Open the team → "Add members": search, pick a contact group, or invite someone new by email.',
       'Members are added to every standard channel automatically.']),
    Guide(Icons.lock, 'Make a private channel', 'Teams: Private channel',
      ['In a team, press "Add channel" and choose Private.', 'Pick who can see it. Only they can open it; new team members are not added.']),
    Guide(Icons.add_box_outlined, 'Add an app as a channel tab', 'Teams: + Add a tab',
      ['Open a channel and press the "+" box at the top.', 'Choose Planner, Lists, Notes, Forms, Milestones, Goals, Updates or Praise.', 'It appears next to Posts and Files for everyone in the channel.']),
    Guide(Icons.shield_outlined, 'Moderate a channel', 'Teams: Channel moderation',
      ['On the channel\'s menu (⋮ in the team) choose "Moderate".', 'Only owners and moderators can then start posts; everyone can still reply.']),
  ]),
  ('Meetings and calls', [
    Guide(Icons.event, 'Schedule a meeting', 'Teams: Calendar → New meeting',
      ['Go to Calendar and press "New meeting", or tap an empty slot in the Day or Week view.', 'Give it a title, choose the chat (its people are invited), date, time and length.',
       'Or press "Schedule with Amer" and just type, e.g. "30 min vendor review Thursday 11am".'], open: _calendar),
    Guide(Icons.push_pin_outlined, 'Pin or spotlight someone in a meeting', 'Teams: Pin for me / Spotlight',
      ['In the meeting, press "⋯" on the person\'s video.', '"Pin for me" changes only your view; "Spotlight for everyone" (organisers) changes everyone\'s.']),
    Guide(Icons.fact_check_outlined, 'See who attended', 'Teams: Attendance report',
      ['After the meeting, open the chat\'s menu (⋮) → "Meeting attendance report" (organisers only).', 'It shows who joined, when they joined and left, and for how long.']),
    Guide(Icons.phone_forwarded, 'Transfer, park or forward a phone call', 'Teams Phone',
      ['On a company-line call: Transfer sends it to a colleague; Park gives a 3-digit code anyone can pick it up with.', 'Phone → Call forwarding: ring someone else as well, forward, or send to voicemail.']),
  ]),
  ('Your AI team', [
    Guide(Icons.apartment, 'Ask your agents to do work', 'Teams: Copilot and agents (Facilitator, Project Manager…)',
      ['Open Apps → "My agent office".', 'Optional: "Work on a chat" so they read that chat (on your device).', 'Type the request and press "Ask Amer". The Chief of Staff hands parts to the right agents.',
       'If they propose actions (post a message, create tasks, book a meeting), nothing happens until you press Approve.'],
      open: _office, note: 'Needs the AI key set on your server by the administrator. Confidential chats are never sent to the AI.'),
  ]),
  ('Status', [
    Guide(Icons.circle, 'Set your status', 'Teams: availability and status message',
      ['Press your initial (top right) → your status.', 'Choose Available, Busy, Do not disturb, Be right back, Appear away or Appear offline.', 'Add a message and when it should clear.']),
  ]),
];

Widget _people() => const PeopleScreen();
Widget _office() => const OfficeScreen();
Widget _calendar() => const CalendarScreen();

class _S extends State<HelpScreen> {
  String q = '';
  @override Widget build(BuildContext c) {
    bool hit(Guide g) => q.isEmpty || '${g.title} ${g.teams} ${g.steps.join(' ')}'.toLowerCase().contains(q.toLowerCase());
    return Scaffold(appBar: AppBar(title: const Text('Help and guide')), body: ListView(padding: const EdgeInsets.all(12), children: [
      TextField(decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'How do I… (e.g. invite, private channel, attendance)', border: OutlineInputBorder()), onChanged: (v) => setState(() => q = v)),
      const SizedBox(height: 8),
      ListTile(leading: const Icon(Icons.apps), title: const Text('Every feature in one list'), subtitle: const Text('Apps: each feature with one line on what it does'),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const AppsScreen()))),
      for (final (section, guides) in kGuides) if (guides.any(hit)) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 16, 4, 4), child: Text(section, style: Theme.of(c).textTheme.titleMedium?.copyWith(color: Theme.of(c).colorScheme.primary))),
        for (final g in guides.where(hit)) Card(child: ExpansionTile(leading: Icon(g.icon), title: Text(g.title), subtitle: Text(g.teams, style: Theme.of(c).textTheme.bodySmall),
          childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12), expandedCrossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var i = 0; i < g.steps.length; i++) Padding(padding: const EdgeInsets.only(bottom: 6), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              CircleAvatar(radius: 10, child: Text('${i + 1}', style: const TextStyle(fontSize: 11))), const SizedBox(width: 8), Expanded(child: Text(g.steps[i]))])),
            if (g.note != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text(g.note!, style: Theme.of(c).textTheme.bodySmall)),
            if (g.open != null) Align(alignment: Alignment.centerRight, child: FilledButton.tonal(onPressed: () => Navigator.push(c, MaterialPageRoute(builder: (_) => g.open!())), child: const Text('Open'))),
          ])),
      ],
    ]));
  }
}

/// First launch: a short welcome with the three things to do first.
Future<void> showWelcomeTour(BuildContext c) => showDialog(context: c, builder: (d) => AlertDialog(
  title: const Text('Welcome to Amer Teams'),
  content: const SizedBox(width: 440, child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
    Text('It works like Microsoft Teams, and everything is end-to-end encrypted on your own server.'), SizedBox(height: 12),
    ListTile(dense: true, leading: Icon(Icons.badge_outlined), title: Text('1. Fill in your contact card'), subtitle: Text('People → My contact details')),
    ListTile(dense: true, leading: Icon(Icons.person_add), title: Text('2. Add your colleagues'), subtitle: Text('People → Add contacts, or invite someone new by email')),
    ListTile(dense: true, leading: Icon(Icons.groups_2_outlined), title: Text('3. Create or join a team'), subtitle: Text('Teams → Create team → Add members')),
    SizedBox(height: 8), Text('Help and guide (your initial, top right) explains every feature step by step.'),
  ])),
  actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Later')),
    FilledButton(onPressed: () { Navigator.pop(d); Navigator.push(c, MaterialPageRoute(builder: (_) => const PeopleScreen())); }, child: const Text('Start with People'))]));
