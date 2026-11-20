import 'people_screen.dart';
import 'help_screen.dart';
import '../services/urgent.dart';
import '../services/availability.dart';
import 'package:matrix/matrix.dart' show Client;
import '../services/accessibility.dart';
import 'notifications_screen.dart';
import 'search_screen.dart';
import 'apps_screen.dart';
import '../services/focus.dart';
import 'operator_screen.dart';
import 'dart:async';
import 'call_screen.dart';
import '../services/handoff.dart';
import '../services/calendar_connector.dart';
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
import '../services/enclave_client.dart';
import '../services/search_index.dart';
import '../services/locale.dart';

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
    OutOfOffice.instance.start(m.client); CalendarConnector.instance.start();
    FocusGuard.instance.attach(m.client, ApiService(m)); FocusGuard.instance.ended.addListener(_focusEnded);
    _searchClient = m.client; SearchIndex.instance.start(m.client); Availability.instance.start(m.client); Urgent.instance.start(m.client);
    _people = Timer.periodic(const Duration(minutes: 2), (_) => _invitees()); Future.delayed(const Duration(seconds: 5), _invitees);
    Future.delayed(const Duration(seconds: 2), () async {          // first launch on this account: the welcome tour, once
      if (!mounted) return; final cl = context.read<MatrixService>().client;
      if (cl.accountData['com.amerteams.welcomed'] != null || const bool.fromEnvironment('IN_USE_TEST')) return;
      try { await cl.setAccountData(cl.userID!, 'com.amerteams.welcomed', {'at': DateTime.now().millisecondsSinceEpoch}); } catch (_) {}
      if (mounted) showWelcomeTour(context);
    }); Urgent.instance.pending.addListener(_urgent);                          // on-device index of decrypted messages
    Flags.instance.load(ApiService(m)).then((_) => EnclaveClient.instance.check(ApiService(m), unattestedAllowed: Flags.instance.on('ai_unattested_enclave')));
    Reminders.instance.due.addListener(_reminder);
    _checkAway();
    _handoffSub = m.client.onSync.stream.listen((_) => _checkHandoff());
  }
  StreamSubscription? _handoffSub; int? _handoffShown;
  void _focusEnded() { final s = FocusGuard.instance.ended.value; if (s != null && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(duration: const Duration(seconds: 10), content: Text(s.text))); }
  void _checkHandoff() {
    final m = context.read<MatrixService>(); final h = Handoff.elsewhere(m.client);
    if (h == null || h['since'] == _handoffShown || !mounted) return;
    _handoffShown = h['since'] as int; final sm = ScaffoldMessenger.of(context);
    sm.showMaterialBanner(MaterialBanner(leading: const Icon(Icons.devices), content: Text('You are in a ${h['meeting'] == true ? 'meeting' : 'call'} on ${h['device_name']}.'), actions: [
      TextButton(onPressed: sm.hideCurrentMaterialBanner, child: Text(L.t(context, 'Not now'))),
      FilledButton(onPressed: () { sm.hideCurrentMaterialBanner(); Navigator.of(context).push(MaterialPageRoute(builder: (_) => CallScreen(roomId: h['room_id'], callId: h['call_id'], meeting: h['meeting'] == true))); }, child: Text(L.t(context, 'Move it here')))]));
  }
  Client? _searchClient; Timer? _people;
  Future<void> _invitees() async {
    if (!mounted) return;
    final n = await addJoinedInvitees(context.read<MatrixService>(), ApiService(context.read<MatrixService>()));
    if (n > 0 && mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$n ${n == 1 ? 'person you invited has' : 'people you invited have'} joined and been added to your teams and chats')));
  }
  void _urgent() {
    if (!mounted) return;
    final sm = ScaffoldMessenger.of(context); sm.hideCurrentMaterialBanner();
    final p = Urgent.instance.pending.value; if (p.isEmpty) return;
    final e = p.first;
    sm.showMaterialBanner(MaterialBanner(backgroundColor: Colors.red.shade50, leading: const Icon(Icons.notification_important, color: Colors.red),
      content: Text('Urgent from ${e.senderFromMemoryOrFallback.calcDisplayname()} in ${e.room.getLocalizedDisplayname()}: ${e.body.substring(8)}', maxLines: 2, overflow: TextOverflow.ellipsis),
      actions: [TextButton(onPressed: () { sm.hideCurrentMaterialBanner(); Urgent.instance.dismiss(e); openChat(context, e.roomId!); }, child: const Text('Open')),
        TextButton(onPressed: () { sm.hideCurrentMaterialBanner(); Urgent.instance.dismiss(e); }, child: const Text('Dismiss'))]));
  }
  @override void dispose() { _people?.cancel(); Urgent.instance.pending.removeListener(_urgent); _handoffSub?.cancel(); Reminders.instance.due.removeListener(_reminder); WidgetsBinding.instance.removeObserver(this); ComplianceService.instance.stop(); WorkflowRunner.instance.stop(); GlassBox.instance.stop(); OutOfOffice.instance.stop(); SearchIndex.instance.stop(_searchClient); super.dispose(); }
  @override void didChangeAppLifecycleState(AppLifecycleState s) {
    if (s == AppLifecycleState.resumed) { _checkAway(); } else if (s == AppLifecycleState.paused || s == AppLifecycleState.inactive) { CatchUp.markActive(); }
  }
  void _reminder() {
    final r = Reminders.instance.due.value; if (r == null || !mounted) return;
    final sm = ScaffoldMessenger.of(context);
    sm.showMaterialBanner(MaterialBanner(leading: const Icon(Icons.alarm), content: Text('Reminder: ${r['preview']}'), actions: [
      TextButton(onPressed: () { sm.hideCurrentMaterialBanner(); Reminders.instance.snooze('${r['id']}', const Duration(hours: 1)); }, child: Text(L.t(context, 'In 1 hour'))),
      TextButton(onPressed: () { sm.hideCurrentMaterialBanner(); Reminders.instance.dismiss('${r['id']}'); }, child: Text(L.t(context, 'Done'))),
      FilledButton(onPressed: () { sm.hideCurrentMaterialBanner(); Reminders.instance.dismiss('${r['id']}');
        Navigator.push(context, MaterialPageRoute(builder: (_) => ChatScreen(roomId: '${r['room']}'))); }, child: Text(L.t(context, 'Open'))),
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
        TextButton(onPressed: () => ScaffoldMessenger.of(context).hideCurrentMaterialBanner(), child: Text(L.t(context, 'Later'))),
        FilledButton(onPressed: () { ScaffoldMessenger.of(context).hideCurrentMaterialBanner();
          Navigator.push(context, MaterialPageRoute(builder: (_) => const CatchUpScreen())); }, child: Text(L.t(context, 'Catch me up'))),
      ]));
  }

  int i = 0;
  // Teams / Slack layout: a short app bar; everything else is one tap away in Apps, which also explains each feature.
  static const _dest = [
    (Icons.notifications_none, Icons.notifications, 'Activity'), (Icons.chat_bubble_outline, Icons.chat_bubble, 'Chat'), (Icons.groups_outlined, Icons.groups, 'Teams'),
    (Icons.calendar_month_outlined, Icons.calendar_month, 'Calendar'), (Icons.call_outlined, Icons.call, 'Calls'), (Icons.auto_awesome_outlined, Icons.auto_awesome, 'Amer'),
    (Icons.apps_outlined, Icons.apps, 'Apps')];

  Widget _page(BuildContext c, int k) => switch (k) {
    0 => const ActivityScreen(),
    1 => twoPane(c) ? Row(children: [const SizedBox(width: 380, child: RoomsScreen()), const VerticalDivider(width: 1),
          Expanded(child: ValueListenableBuilder<String?>(valueListenable: selectedChat, builder: (c, id, _) => id == null
            ? Center(child: Column(mainAxisSize: MainAxisSize.min, children: [Icon(Icons.forum_outlined, size: 64, color: Theme.of(c).colorScheme.outline), const SizedBox(height: 12),
                Text(L.t(c, 'Choose a chat'), style: Theme.of(c).textTheme.titleMedium)]))
            : ChatScreen(key: ValueKey(id), roomId: id, onClose: () => selectedChat.value = null)))])
        : const RoomsScreen(),
    2 => const TeamsScreen(), 3 => const CalendarScreen(), 4 => const CallsScreen(), 5 => const CopilotScreen(), _ => const AppsScreen() };

  /// Top bar, as in Teams: search everywhere in the middle, your profile and settings on the right.
  PreferredSizeWidget _top(BuildContext c) {
    final m = context.read<MatrixService>(); final me = m.client.userID ?? '';
    return PreferredSize(preferredSize: const Size.fromHeight(52), child: Material(color: Theme.of(c).colorScheme.surfaceContainer, child: SafeArea(bottom: false, child: Padding(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8), child: Row(children: [
        Text('Amer Teams', style: Theme.of(c).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)), const SizedBox(width: 16),
        Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 560), child: InkWell(borderRadius: BorderRadius.circular(8),
          onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => const SearchScreen())),
          child: Container(height: 34, padding: const EdgeInsets.symmetric(horizontal: 10), decoration: BoxDecoration(color: Theme.of(c).colorScheme.surface, borderRadius: BorderRadius.circular(8), border: Border.all(color: Theme.of(c).colorScheme.outlineVariant)),
            child: Row(children: [const Icon(Icons.search, size: 18), const SizedBox(width: 8), Text(L.t(c, 'Search messages, files and people'), style: Theme.of(c).textTheme.bodySmall)])))))),
        const SizedBox(width: 12),
        PopupMenuButton<String>(tooltip: 'Your profile and settings', onSelected: (v) {
            if (v == 'security') Navigator.push(c, MaterialPageRoute(builder: (_) => const SecurityScreen()));
            if (v == 'a11y') Navigator.push(c, MaterialPageRoute(builder: (_) => const A11yScreen()));
            if (v == 'notify') Navigator.push(c, MaterialPageRoute(builder: (_) => const NotificationsScreen()));
            if (v == 'out') confirmSignOut(c);
            if (v == 'status') showAvailability(c);
            if (v == 'help') Navigator.push(c, MaterialPageRoute(builder: (_) => const HelpScreen()));
            if (v == 'people') Navigator.push(c, MaterialPageRoute(builder: (_) => const PeopleScreen()));
          },
          itemBuilder: (_) => [
            PopupMenuItem(enabled: false, child: Text(me)),
            PopupMenuItem(value: 'status', child: ValueListenableBuilder(valueListenable: Availability.instance.state, builder: (_, v, __) => ListTile(
              leading: Icon(Availability.icon(v.$1), color: Availability.colour(v.$1)), title: Text(Availability.label(v.$1)), subtitle: Text(v.$2.isEmpty ? 'Set status message' : v.$2)))),
            const PopupMenuItem(value: 'people', child: ListTile(leading: Icon(Icons.contacts_outlined), title: Text('People and contacts'))),
            const PopupMenuItem(value: 'help', child: ListTile(leading: Icon(Icons.help_outline), title: Text('Help and guide'))),
            PopupMenuItem(value: 'notify', child: ListTile(leading: const Icon(Icons.notifications_active_outlined), title: Text(L.t(c, 'Notifications')))),
            PopupMenuItem(value: 'security', child: ListTile(leading: const Icon(Icons.security), title: Text(L.t(c, 'Security')))),
            PopupMenuItem(value: 'a11y', child: ListTile(leading: const Icon(Icons.accessibility_new), title: Text(L.t(c, 'Accessibility')))),
            PopupMenuItem(enabled: false, child: Text('Build ${const String.fromEnvironment('BUILD_ID', defaultValue: 'dev')} · ${const String.fromEnvironment('BUILD_DATE', defaultValue: 'local')}', style: const TextStyle(fontSize: 11))),
            PopupMenuItem(value: 'out', child: ListTile(leading: const Icon(Icons.logout), title: Text(L.t(c, 'Sign out')))),
          ],
          child: CircleAvatar(radius: 16, child: Text(me.length > 1 ? me[1].toUpperCase() : '?'))),
      ]))))); }

  @override
  Widget build(BuildContext c) {
    final wide = MediaQuery.sizeOf(c).width > 720;
    if (wide) {
      return Scaffold(appBar: _top(c), body: Row(children: [
        NavigationRail(selectedIndex: i, onDestinationSelected: (v) => setState(() => i = v), labelType: NavigationRailLabelType.all, minWidth: 68,
          destinations: [for (final d in _dest) NavigationRailDestination(icon: Icon(d.$1), selectedIcon: Icon(d.$2), label: Text(t(c, d.$3)))]),
        const VerticalDivider(width: 1), Expanded(child: _page(c, i))]));
    }
    // Phones, as in the Teams and Slack mobile apps: five tabs; Amer and Apps sit under More.
    return Scaffold(body: _page(c, i), bottomNavigationBar: NavigationBar(selectedIndex: i < 4 ? i : 4,
      onDestinationSelected: (v) async {
        if (v < 4) { setState(() => i = v); return; }
        final pick = await showModalBottomSheet<int>(context: c, builder: (s) => SafeArea(child: Column(mainAxisSize: MainAxisSize.min, children: [
          for (var k = 4; k < _dest.length; k++) ListTile(leading: Icon(_dest[k].$1), title: Text(t(c, _dest[k].$3)), onTap: () => Navigator.pop(s, k)),
          ListTile(leading: const Icon(Icons.security), title: Text(t(c, 'Security')), onTap: () { Navigator.pop(s); Navigator.push(c, MaterialPageRoute(builder: (_) => const SecurityScreen())); }),
          ListTile(leading: const Icon(Icons.logout), title: Text(t(c, 'Sign out')), onTap: () { Navigator.pop(s); confirmSignOut(c); }),
        ])));
        if (pick != null) setState(() => i = pick);
      },
      destinations: [for (var k = 0; k < 4; k++) NavigationDestination(icon: Icon(_dest[k].$1), selectedIcon: Icon(_dest[k].$2), label: t(c, _dest[k].$3)),
        NavigationDestination(icon: const Icon(Icons.more_horiz), label: t(c, 'More'))]));
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
    actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: Text(L.t(d, 'Cancel'))),
      FilledButton(onPressed: () => Navigator.pop(d, true), child: Text(L.t(d, 'Sign out')))]));
  if (ok == true) await m.logout();
}
