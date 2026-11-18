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

class HomeScreen extends StatefulWidget { const HomeScreen({super.key}); @override State<HomeScreen> createState() => _S(); }
class _S extends State<HomeScreen> {
  int i = 0;
  static const _dest = [
    (Icons.notifications_none, 'Activity'), (Icons.chat_bubble_outline, 'Chat'), (Icons.call_outlined, 'Calls'), (Icons.groups_outlined, 'Teams'), (Icons.calendar_month, 'Calendar'),
    (Icons.auto_awesome, 'Amer'), (Icons.tune, 'Control'), (Icons.monitor_heart_outlined, 'Health'), (Icons.manage_accounts_outlined, 'Users'), (Icons.security, 'Security')];
  @override
  Widget build(BuildContext c) {
    final pages = [const ActivityScreen(), const RoomsScreen(), const CallsScreen(), const TeamsScreen(), const CalendarScreen(), const CopilotScreen(), const ControlScreen(), const OpsScreen(), const AdminScreen(), const SecurityScreen()];
    final wide = MediaQuery.sizeOf(c).width > 720;
    final body = pages[i];
    if (wide) {
      return Scaffold(body: Row(children: [
        NavigationRail(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), labelType: NavigationRailLabelType.all,
          trailing: IconButton(icon: const Icon(Icons.logout), onPressed: () => c.read<MatrixService>().logout()),
          destinations: [for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), label: Text(d.$2))]),
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
          ListTile(leading: const Icon(Icons.logout), title: const Text('Sign out'), onTap: () { Navigator.pop(s); c.read<MatrixService>().logout(); }),
        ])));
        if (pick != null) setState(() => i = pick);
      },
      destinations: [for (var k = 0; k < main; k++) NavigationDestination(icon: Icon(_dest[k].$1), label: _dest[k].$2),
        const NavigationDestination(icon: Icon(Icons.more_horiz), label: 'More')]));
  }
}
