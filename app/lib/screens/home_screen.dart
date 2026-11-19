import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';
import 'rooms_screen.dart';
import 'copilot_screen.dart';
import 'control_screen.dart';
import 'teams_screen.dart';
import 'calendar_screen.dart';
import 'ops_screen.dart';
import 'admin_screen.dart';
import 'calls_screen.dart';
import 'activity_screen.dart';
import 'security_screen.dart';
import '../services/api_service.dart';
import '../services/compliance_service.dart';
import 'agent_ops_screen.dart';
import 'catch_up_screen.dart';
import '../services/catch_up.dart';
import '../services/workflow_runner.dart';
import '../services/glass_box.dart';
import '../services/later.dart';
import 'chat_screen.dart';
import 'find_time_screen.dart';
import '../services/ooo.dart';
import '../services/feature_flags.dart';

class HomeScreen extends StatefulWidget { const HomeScreen({super.key}); @override State<HomeScreen> createState() => _S(); }
class _S extends State<HomeScreen> with WidgetsBindingObserver {
  @override void initState() {
    super.initState();
    final m = context.read<MatrixService>();
    ComplianceService.instance.start(m.client, ApiService(m));     // business tenants with archiving: add the archiver to chats
    WidgetsBinding.instance.addObserver(this);
    WorkflowRunner.instance.start(m.client, ApiService(m));        // the owner's workflows run on this device
    GlassBox.instance.start(m, ApiService(m));                     // personal agents' approvals; approved actions run here
    ScheduledSender.instance.start(m.client); Reminders.instance.start();
    CalendarPrefs.publish(m, ApiService(m)).catchError((_) {});    // free/busy only, for find-a-time
    OutOfOffice.instance.start(m.client);
    Flags.instance.load(ApiService(m));
    Reminders.instance.due.addListener(_reminder);
    _checkAway();
  }
  @override void dispose() { Reminders.instance.due.removeListener(_reminder); WidgetsBinding.instance.removeObserver(this); ComplianceService.instance.stop(); WorkflowRunner.instance.stop(); GlassBox.instance.stop(); OutOfOffice.instance.stop(); super.dispose(); }
  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) { _checkAway(); } else if (s == AppLifecycleState.paused || s == AppLifecycleState.inactive) { CatchUp.markActive(); }
  }
  void _reminder() {
    final r = Reminders.instance.due.value; if (r == null || !mounted) return;
    final sm = ScaffoldMessenger.of(context);
    sm.showMaterialBanner(MaterialBanner(leading: const Icon(Icons.alarm), content: Text('Reminder: ${r['preview']}'), actions: [
      TextButton(onPressed: () { sm.hideCurrentMaterialBanner(); Reminders.instance.snooze('${r['id']}', const Duration(hours: 1)); }, child: const Text('In 1 hour')),
      TextButton(onPressed: () { sm.hideCurrentMaterialBanner(); Reminders.instance.dismiss('${r['id']}'); }, child: const Text('Done')),
      FilledButton(onPressed: () { sm.hideCurrentMaterialBanner(); Reminders.instance.dismiss('${r['id']}');
        Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(roomId: '${r['room']}'))); }, child: const Text('Open')),
    ]));
  }

  /// Back after 4+ hours away: offer the catch-up digest (as Teams and Slack do), never open it uninvited.
  Future<void> _checkAway() async {
    if (!await CatchUp.cameBackAfterAway() || !mounted) return;
    final unread = context.read<MatrixService>().client.rooms.where((r) => r.notificationCount > 0).length;
    if (unread == 0) return;
    ScaffoldMessenger.of(context).showMaterialBanner(MaterialBanner(
      leading: const Icon(Icons.auto_awesome), content: Text('Welcome back. $unread chats have new messages.'),
      actions: [
        TextButton(onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(), child: const Text('Later')),
        FilledButton(onPressed: () { ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
          Navigator.push(context, MaterialPageRoute(builder: (_) => const CatchUpScreen())); }, child: const Text('Catch me up')),
      ]));
  }

  int i = 0;
  static const _dest = [
    (Icons.notifications_none, 'Activity'), (Icons.chat_bubble_outline, 'Chat'), (Icons.call_outlined, 'Calls'), (Icons.groups_outlined, 'Teams'), (Icons.calendar_month, 'Calendar'),
    (Icons.auto_awesome, 'Amer'), (Icons.hub_outlined, 'Agent Ops'), (Icons.tune, 'Control'), (Icons.monitor_heart_outlined, 'Health'), (Icons.manage_accounts_outlined, 'Users'), (Icons.security, 'Security')];
  @override
  Widget build(BuildContext c) {
    final pages = [const ActivityScreen(), const RoomsScreen(), const CallsScreen(), const TeamsScreen(), const CalendarScreen(), const CopilotScreen(), const AgentOpsScreen(), const ControlScreen(), const OpsScreen(), const AdminScreen(), const SecurityScreen()];
    final wide = MediaQuery.sizeOf(c).width > 720;
    final body = pages[i];
    if (wide) {
      // the rail scrolls when the window is too short for every destination (12 of them on a small laptop screen)
      return Scaffold(body: Row(children: [
        LayoutBuilder(builder: (lc, box) => SingleChildScrollView(child: ConstrainedBox(constraints: BoxConstraints(minHeight: box.maxHeight), child: IntrinsicHeight(child:
        NavigationRail(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), labelType: NavigationRailLabelType.all,
          leading: const Tooltip(message: 'Build ${String.fromEnvironment('BUILD_ID', defaultValue: 'dev')} · ${String.fromEnvironment('BUILD_DATE', defaultValue: 'local')}', child: Text('b${String.fromEnvironment('BUILD_ID', defaultValue: 'dev')}', style: TextStyle(fontSize: 10))),
          trailing: IconButton(tooltip: 'Sign out', icon: const Icon(Icons.logout), onPressed: () => confirmSignOut(c)),
          destinations: [for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2))]))))),
        const VerticalDivider(width: 1), Expanded(child: body)]));
    }
    // Phones: first four tabs plus "More" for Control, Health and Users.
    const main = 4;   // Activity, Chat, Calls, Teams
    return Scaffold(body: body, bottomNavigationBar: NavigationBar(
      selectedIndex: i < main ? i : main,
      onDestinationSelected: (v) async {
        if (v < main) { setState(() => i = v); return; }
        final pick = await showModalBottomSheet<int>(context: c, builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var k = main; k < _dest.length; k++) ListTile(leading: Icon(_dest[k].$1), title: Text(_dest[k].$2), onTap: () => Navigator.pop(s, k)),
          const ListTile(leading: Icon(Icons.info_outline), title: Text('About Amer Teams'),
            subtitle: Text('Build ${String.fromEnvironment('BUILD_ID', defaultValue: 'dev')} · ${String.fromEnvironment('BUILD_DATE', defaultValue: 'local')}')),
          ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: () { Navigator.pop(s); confirmSignOut(c); }),
        ])));
        if (pick != null) setState(() => i = pick);
      },
      destinations: [for (var k = 0; k < main; k++) NavigationDestination(icon: Icon(_dest[k].$1), label: _dest[k].$2),
        const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More')]));
  }
}


/// Sign out, with a warning when this device holds the only copy of the encryption keys (no backup).
Future<void> confirmSignOut(BuildContext c) async {
  final m = c.read<MatrixService>();
  final backedUp = (m.client.encryption?.keyManager.enabled ?? false) && (m.client.encryption?.crossSigning.enabled ?? false);
  final ok = await showDialog<bool>(context: c, builder: (d) => AlertDialog(title: const Text('Sign out?'),
    content: Text(backedUp
        ? 'Your encrypted chat history is backed up. On your next sign-in, use your recovery key in Security to read old messages.'
        : 'You have not set up encrypted backup. If you sign out, old encrypted messages cannot be read on this or any new device. Set up backup in Security first.'),
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')),
      FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Sign out'))]));
  if (ok == true) await m.logout();
}
