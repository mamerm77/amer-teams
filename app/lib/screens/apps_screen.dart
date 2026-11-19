import 'package:flutter/material.dart';
import '../services/accessibility.dart';
import '../services/locale.dart';
import 'admin_screen.dart';
import 'agent_ops_screen.dart';
import 'analytics_screen.dart';
import 'call_trace_screen.dart';
import 'catch_up_screen.dart';
import 'control_screen.dart';
import 'expertise_screen.dart';
import 'find_time_screen.dart';
import 'flags_screen.dart';
import 'focus_screen.dart';
import 'followed_threads_screen.dart';
import 'guest_accounts_screen.dart';
import 'in_person_screen.dart';
import 'meeting_rooms_screen.dart';
import 'notifications_screen.dart';
import 'operator_screen.dart';
import 'ops_screen.dart';
import 'partners_screen.dart';
import 'personal_agents_screen.dart';
import 'phone_screen.dart';
import 'saved_screen.dart';
import 'security_screen.dart';
import 'skills_screen.dart';
import 'tasks_screen.dart';
import 'workflows_screen.dart';

/// Every feature in one place, like Teams' "Apps" and Slack's "More": a name, one line on what it does, one tap to
/// open it. Features that belong to a chat or a meeting are listed with where to find them.
class AppItem {
  const AppItem(this.icon, this.name, this.what, {this.open, this.where});
  final IconData icon; final String name, what; final Widget Function()? open; final String? where;
}

const _sections = <(String, List<AppItem>)>[
  ('Your work', [
    AppItem(Icons.auto_awesome, 'Catch me up', 'What happened while you were away, per chat, with what needs you', open: _catchUp),
    AppItem(Icons.task_alt, 'Tasks', 'Your tasks from every chat: due dates, overdue first', open: _tasks),
    AppItem(Icons.bookmark_outline, 'Saved messages', 'Messages you saved, in your own folders', open: _saved),
    AppItem(Icons.forum_outlined, 'Followed threads', 'Threads you follow, newest replies first', open: _threads),
    AppItem(Icons.headphones, 'Focus and wellbeing', 'Hold notifications for a while; see your week (only you)', open: _focus),
    AppItem(Icons.person_search, 'Who knows about…', 'Find colleagues by topic; publish what you know', open: _expertise),
    AppItem(Icons.notifications_active_outlined, 'Notifications', 'Quiet hours, per-chat levels, priority people', open: _notify),
  ]),
  ('Meetings and calls', [
    AppItem(Icons.manage_search, 'Find a time', 'Free slots for everyone, with prayer times and Ramadan hours', open: _findTime),
    AppItem(Icons.meeting_room_outlined, 'Meeting rooms', 'Book a room; check in; room display tablets', open: _rooms),
    AppItem(Icons.record_voice_over, 'In-person notes', 'Transcribe a meeting in a room; Amer writes the minutes', open: _inPerson),
    AppItem(Icons.dialpad, 'Phone', 'Call phone numbers; answer the company line', open: _phone),
    AppItem(Icons.videocam_outlined, 'In a meeting', 'Record with consent, translated captions, Q&A, guest link, phone dial-in, blur, live identity check', where: 'Meeting → More (…)'),
  ]),
  ('Amer and agents', [
    AppItem(Icons.groups_2_outlined, 'My agents', 'Your personal agent team, with the glass box of what they did', open: _agents),
    AppItem(Icons.storefront_outlined, 'Skills and marketplace', 'Reusable AI skills and custom agents; your organisation\'s marketplace', open: _skills),
    AppItem(Icons.account_tree_outlined, 'Workflows', 'Automations described in plain language', open: _workflows),
    AppItem(Icons.hub_outlined, 'Agent Ops', 'All agents running, their cost and health', open: _agentOps),
    AppItem(Icons.chat_outlined, 'In a chat', '/ask, /premortem, /skill, Meeting twin, Files with versions, Connectors, Shifts, Walkie-talkie', where: 'Chat → menu (⋮) or type /'),
  ]),
  ('Operations', [
    AppItem(Icons.crisis_alert, 'Operator', 'NOC incidents: war rooms, on-call, paging, MTTA/MTTR', open: _operator),
    AppItem(Icons.monitor_heart_outlined, 'Health', 'Service health and alerts', open: _health),
    AppItem(Icons.tune, 'Control centre', 'Live view of calls, devices and services', open: _control),
    AppItem(Icons.timeline, 'Call trace', 'Every call, step by step, for troubleshooting', open: _trace),
  ]),
  ('Administration', [
    AppItem(Icons.manage_accounts_outlined, 'Users', 'Accounts, invite codes, legal holds', open: _users),
    AppItem(Icons.insights, 'Usage analytics', 'How the organisation uses Amer Teams (totals only)', open: _analytics),
    AppItem(Icons.badge_outlined, 'Guests and data residency', 'Guest accounts; where each kind of data is kept', open: _guests),
    AppItem(Icons.handshake_outlined, 'Partner organisations', 'Shared channels with other companies', open: _partners),
    AppItem(Icons.flag_outlined, 'Feature flags', 'Switch features on or off per organisation', open: _flags),
  ]),
  ('Settings', [
    AppItem(Icons.security, 'Security and devices', 'Devices, backups, app lock, language', open: _security),
    AppItem(Icons.accessibility_new, 'Accessibility and look', 'Text size, contrast, motion, 3D / 2.5D / flat look', open: _a11y),
  ]),
];
Widget _catchUp() => const CatchUpScreen(); Widget _tasks() => const TasksScreen(); Widget _saved() => const SavedScreen(); Widget _threads() => const FollowedThreadsScreen();
Widget _focus() => const FocusScreen(); Widget _expertise() => const ExpertiseScreen(); Widget _notify() => const NotificationsScreen(); Widget _findTime() => const FindTimeScreen();
Widget _rooms() => const MeetingRoomsScreen(); Widget _inPerson() => const InPersonScreen(); Widget _phone() => const PhoneScreen(); Widget _agents() => const PersonalAgentsScreen();
Widget _skills() => const SkillsScreen(); Widget _workflows() => const WorkflowsScreen(); Widget _agentOps() => const AgentOpsScreen(); Widget _operator() => const OperatorScreen();
Widget _health() => const OpsScreen(); Widget _control() => const ControlScreen(); Widget _trace() => const CallTraceScreen(); Widget _users() => const AdminScreen();
Widget _analytics() => const AnalyticsScreen(); Widget _guests() => const GuestAccountsScreen(); Widget _partners() => const PartnersScreen(); Widget _flags() => const FlagsScreen();
Widget _security() => const SecurityScreen(); Widget _a11y() => const A11yScreen();

class AppsScreen extends StatefulWidget {
  const AppsScreen({super.key});
  @override State<AppsScreen> createState() => _S();
}
class _S extends State<AppsScreen> {
  final q = TextEditingController();
  @override
  Widget build(BuildContext c) {
    final f = q.text.trim().toLowerCase();
    bool hit(AppItem a) => f.isEmpty || a.name.toLowerCase().contains(f) || a.what.toLowerCase().contains(f) || L.t(c, a.name).contains(f);
    final cs = Theme.of(c).colorScheme;
    // every tile is built (not lazily), so search, screen readers and keyboard focus reach all of them
    return Scaffold(appBar: AppBar(title: Text(L.t(c, 'Apps'))), body: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 24), child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      TextField(controller: q, onChanged: (_) => setState(() {}), decoration: InputDecoration(prefixIcon: const Icon(Icons.search), hintText: L.t(c, 'Find a feature'), border: const OutlineInputBorder(), isDense: true)),
      for (final (title, items) in _sections) if (items.any(hit)) ...[
        Padding(padding: const EdgeInsets.fromLTRB(4, 20, 4, 8), child: Text(L.t(c, title), style: Theme.of(c).textTheme.titleSmall?.copyWith(color: cs.primary))),
        LayoutBuilder(builder: (c, box) {
          final cols = (box.maxWidth / 300).floor().clamp(1, 4);
          return Wrap(spacing: 10, runSpacing: 10, children: [for (final a in items.where(hit)) SizedBox(width: (box.maxWidth - 10 * (cols - 1)) / cols, child: Card(margin: EdgeInsets.zero,
            child: InkWell(borderRadius: BorderRadius.circular(12), onTap: a.open == null ? null : () => Navigator.push(c, MaterialPageRoute(builder: (_) => a.open!())),
              child: Padding(padding: const EdgeInsets.all(14), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                CircleAvatar(radius: 20, backgroundColor: cs.primaryContainer, child: Icon(a.icon, color: cs.onPrimaryContainer, size: 20)), const SizedBox(width: 12),
                Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(L.t(c, a.name), style: const TextStyle(fontWeight: FontWeight.w600)), const SizedBox(height: 2),
                  Text(a.what, style: Theme.of(c).textTheme.bodySmall),
                  if (a.where != null) Padding(padding: const EdgeInsets.only(top: 4), child: Text('Where: ${a.where}', style: TextStyle(fontSize: 11, color: cs.primary))),
                ])),
              ]))))) ]);
        }),
      ],
    ])));
  }
}
