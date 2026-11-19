import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import '../services/api_service.dart';

/// Virtual office (docs/VIRTUAL_OFFICE.md): your own agent team at their desks. Give the Chief of Staff a request
/// and watch it plan, hand parts to specialists, who work in parallel and hand back; the team room shows every
/// hand-over. Click someone to see their work or ask them directly.
class OfficeScreen extends StatefulWidget {
  const OfficeScreen({super.key});
  @override State<OfficeScreen> createState() => _S();
}

const _rooms = ['Command centre', 'Comms room', 'Operations room', 'Strategy room', 'Creative studio', 'Finance room', 'Growth corner', 'Wellbeing room'];
Color statusColour(String s) => switch (s) { 'working' => const Color(0xFF3B82F6), 'needs_approval' => const Color(0xFFF59E0B), 'assigned' => const Color(0xFF8B5CF6), _ => const Color(0xFF9CA3AF) };

class _S extends State<OfficeScreen> {
  Map<String, dynamic>? o; String? err, dept, selected; bool iso = true, sending = false; Timer? t; final ask = TextEditingController();
  @override void initState() { super.initState(); _load(); t = Timer.periodic(const Duration(seconds: 3), (_) => _load()); }
  @override void dispose() { t?.cancel(); super.dispose(); }
  Future<void> _load() async {
    try { final r = await context.read<ApiService>().getMap('/v1/office'); if (mounted) setState(() { o = r; err = null; }); }
    catch (e) { if (mounted) setState(() => err = '$e'.replaceFirst('Exception: ', '')); }
  }
  Future<void> _ask({String? agent}) async {
    final text = ask.text.trim(); if (text.isEmpty) return;
    setState(() => sending = true);
    try { await context.read<ApiService>().postMap('/v1/office/requests', {'request': text, if (agent != null) 'agent': agent}); ask.clear(); await _load(); }
    catch (e) { if (mounted) ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$e'.replaceFirst('Exception: ', '')))); }
    if (mounted) setState(() => sending = false);
  }
  List<dynamic> get agents => (o?['agents'] as List? ?? const []).where((a) => dept == null || a['dept'] == dept).toList();
  String nameOf(String id) => id == 'you' ? 'You' : ((o?['agents'] as List? ?? const []).firstWhere((a) => a['id'] == id, orElse: () => {'name': id})['name'] as String);

  @override
  Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme; final x = o;
    final depts = {for (final a in (x?['agents'] as List? ?? const [])) a['dept'] as String}.toList();
    return Scaffold(
      appBar: AppBar(title: const Text('My agent office'), actions: [
        SegmentedButton<bool>(segments: const [ButtonSegment(value: true, label: Text('3D')), ButtonSegment(value: false, label: Text('2D'))], selected: {iso}, onSelectionChanged: (v) => setState(() => iso = v.first)),
        const SizedBox(width: 12)]),
      body: err != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text(err!)))
        : x == null ? const Center(child: CircularProgressIndicator())
        : LayoutBuilder(builder: (c, box) {
            final wide = box.maxWidth > 1000;
            final floor = Column(children: [
              SizedBox(height: 44, child: ListView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6), children: [
                Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: const Text('All'), selected: dept == null, onSelected: (_) => setState(() => dept = null))),
                for (final d in depts) Padding(padding: const EdgeInsets.only(right: 6), child: ChoiceChip(label: Text(d), selected: dept == d, onSelected: (_) => setState(() => dept = d))),
              ])),
              Expanded(child: Container(margin: const EdgeInsets.all(12), decoration: BoxDecoration(color: const Color(0xFF0F1220), borderRadius: BorderRadius.circular(16)),
                clipBehavior: Clip.antiAlias, child: InteractiveViewer(minScale: 0.6, maxScale: 2.5, child: _Floor(agents: agents, iso: iso, selected: selected, onTap: (id) => setState(() => selected = id))))),
              Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 4), child: Wrap(spacing: 14, children: [
                for (final (k, l) in [('working', 'Working'), ('needs_approval', 'Needs your approval'), ('assigned', 'Assigned'), ('available', 'Available')])
                  Row(mainAxisSize: MainAxisSize.min, children: [CircleAvatar(radius: 5, backgroundColor: statusColour(k)), const SizedBox(width: 4), Text(l, style: const TextStyle(fontSize: 12))])])),
              Padding(padding: const EdgeInsets.all(12), child: Row(children: [
                Expanded(child: TextField(controller: ask, minLines: 1, maxLines: 3, onSubmitted: (_) => _ask(),
                  decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: 'Ask your Chief of Staff, e.g. "Prepare me for Monday\'s vendor review: agenda, risks, budget"'))),
                const SizedBox(width: 8),
                FilledButton.icon(onPressed: sending ? null : () => _ask(), icon: const Icon(Icons.send), label: const Text('Ask Amer')),
              ])),
            ]);
            final side = selected == null ? _TeamRoom(o: x, nameOf: nameOf) : _AgentPanel(agent: (x['agents'] as List).firstWhere((a) => a['id'] == selected), o: x, nameOf: nameOf,
                onClose: () => setState(() => selected = null), onChanged: _load);
            return wide ? Row(children: [Expanded(child: floor), VerticalDivider(width: 1, color: cs.outlineVariant), SizedBox(width: 380, child: side)])
                        : Column(children: [Expanded(flex: 3, child: floor), const Divider(height: 1), Expanded(flex: 2, child: side)]);
          }));
  }
}

/// The office floor: rooms laid out on a grid, drawn in isometric 3D or flat 2D, with each agent at their desk.
class _Floor extends StatelessWidget {
  const _Floor({required this.agents, required this.iso, required this.selected, required this.onTap});
  final List<dynamic> agents; final bool iso; final String? selected; final void Function(String) onTap;
  static const cols = 4, cell = 150.0;
  Offset project(double gx, double gy, Size s) {           // grid units -> screen
    if (!iso) return Offset(40 + gx * cell, 40 + gy * cell * 0.75);
    final ox = s.width / 2, oy = 60.0;
    return Offset(ox + (gx - gy) * cell * 0.62, oy + (gx + gy) * cell * 0.36);
  }
  @override
  Widget build(BuildContext c) => LayoutBuilder(builder: (c, box) {
    final size = Size(math.max(box.maxWidth, 900), math.max(box.maxHeight, 620));
    final byRoom = <String, List<dynamic>>{}; for (final a in agents) { byRoom.putIfAbsent(a['room'] as String, () => []).add(a); }
    final tiles = <Widget>[];
    for (var i = 0; i < _rooms.length; i++) {
      final gx = (i % cols).toDouble(), gy = (i ~/ cols).toDouble();
      final people = byRoom[_rooms[i]] ?? const [];
      for (var k = 0; k < people.length; k++) {
        final a = people[k]; final p = project(gx + 0.3 + 0.45 * k, gy + 0.5, size);
        final working = a['status'] == 'working', disabled = a['enabled'] == false;
        tiles.add(Positioned(left: p.dx - 70, top: p.dy - 64, child: GestureDetector(onTap: () => onTap(a['id']), child: Opacity(opacity: disabled ? 0.4 : 1, child: Column(children: [
          Stack(clipBehavior: Clip.none, children: [
            AnimatedContainer(duration: const Duration(milliseconds: 600), width: 40, height: 40, decoration: BoxDecoration(shape: BoxShape.circle,
              color: working ? const Color(0xFF3B82F6) : const Color(0xFF374151), border: Border.all(color: a['id'] == selected ? Colors.white : statusColour(a['status']), width: 3),
              boxShadow: [if (working) BoxShadow(color: const Color(0xFF3B82F6).withValues(alpha: 0.6), blurRadius: 16)]),
              child: Center(child: Text((a['name'] as String).substring(0, 1), style: const TextStyle(color: Colors.white, fontWeight: FontWeight.bold, fontSize: 18)))),
            if ((a['approvals'] as int) > 0) Positioned(right: -8, top: -8, child: _Badge('${a['approvals']}', const Color(0xFFF59E0B))),
            if ((a['open'] as int) > 0) Positioned(left: -8, top: -8, child: _Badge('${a['open']}', const Color(0xFF8B5CF6))),
          ]),
          const SizedBox(height: 4),
          Container(width: 140, padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4), decoration: BoxDecoration(color: const Color(0xEE111827), borderRadius: BorderRadius.circular(8), border: Border.all(color: const Color(0xFF374151))),
            child: Column(children: [
              Text('${a['name']}', style: const TextStyle(color: Colors.white, fontWeight: FontWeight.w600, fontSize: 13), overflow: TextOverflow.ellipsis),
              Text('${a['role']}', style: const TextStyle(color: Color(0xFFD1D5DB), fontSize: 10), overflow: TextOverflow.ellipsis),
            ])),
        ]))))));
      }
    }
    return SizedBox(width: size.width, height: size.height, child: Stack(children: [
      Positioned.fill(child: CustomPaint(painter: _OfficePainter(iso: iso, project: (x, y) => project(x, y, size)))), ...tiles]));
  });
}

class _Badge extends StatelessWidget {
  const _Badge(this.t, this.c);
  final String t; final Color c;
  @override Widget build(BuildContext x) => Container(padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1), decoration: BoxDecoration(color: c, borderRadius: BorderRadius.circular(10)),
    child: Text(t, style: const TextStyle(color: Colors.white, fontSize: 10, fontWeight: FontWeight.bold)));
}

class _OfficePainter extends CustomPainter {
  _OfficePainter({required this.iso, required this.project});
  final bool iso; final Offset Function(double, double) project;
  @override
  void paint(Canvas canvas, Size size) {
    final floor = Paint()..color = const Color(0xFF1F2937), wall = Paint()..color = const Color(0xFF111827), edge = Paint()..color = const Color(0xFF4B5563)..style = PaintingStyle.stroke..strokeWidth = 1.2;
    final desk = Paint()..color = const Color(0xFF374151), screen = Paint()..color = const Color(0xFF60A5FA).withValues(alpha: 0.7);
    for (var i = 0; i < _rooms.length; i++) {
      final gx = (i % _Floor.cols).toDouble(), gy = (i ~/ _Floor.cols).toDouble(); const m = 0.06;
      final a = project(gx + m, gy + m), b = project(gx + 1 - m, gy + m), c = project(gx + 1 - m, gy + 1 - m), d = project(gx + m, gy + 1 - m);
      final f = Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..lineTo(c.dx, c.dy)..lineTo(d.dx, d.dy)..close();
      if (iso) {                                                   // back walls, so the rooms read as 3D
        const h = 26.0;
        canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(b.dx, b.dy)..lineTo(b.dx, b.dy - h)..lineTo(a.dx, a.dy - h)..close(), wall);
        canvas.drawPath(Path()..moveTo(a.dx, a.dy)..lineTo(d.dx, d.dy)..lineTo(d.dx, d.dy - h)..lineTo(a.dx, a.dy - h)..close(), Paint()..color = const Color(0xFF0B1220));
      }
      canvas.drawPath(f, floor); canvas.drawPath(f, edge);
      for (final dx in [0.3, 0.75]) {                               // two desks with glowing screens per room
        final p = project(gx + dx, gy + 0.72);
        canvas.drawRRect(RRect.fromRectAndRadius(Rect.fromCenter(center: p, width: 34, height: 14), const Radius.circular(3)), desk);
        canvas.drawRect(Rect.fromCenter(center: p.translate(0, -10), width: 18, height: 10), screen);
      }
      final tp = TextPainter(text: TextSpan(text: _rooms[i].toUpperCase(), style: const TextStyle(color: Color(0xFF9CA3AF), fontSize: 9, letterSpacing: 1)), textDirection: TextDirection.ltr)..layout();
      tp.paint(canvas, project(gx + 0.12, gy + 0.12).translate(0, -4));
    }
  }
  @override bool shouldRepaint(covariant _OfficePainter o) => o.iso != iso;
}

class _TeamRoom extends StatelessWidget {
  const _TeamRoom({required this.o, required this.nameOf});
  final Map<String, dynamic> o; final String Function(String) nameOf;
  @override
  Widget build(BuildContext c) {
    final msgs = (o['messages'] as List);
    return Column(children: [
      const ListTile(title: Text('Team room'), subtitle: Text('Every hand-over between your agents, newest first. Click someone in the office to see their work.')),
      Expanded(child: msgs.isEmpty ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Quiet so far. Ask Amer for something below.')))
        : ListView(children: [for (final m in msgs) ListTile(dense: true,
            leading: CircleAvatar(radius: 14, child: Text(nameOf(m['sender'])[0])),
            title: Text('${nameOf(m['sender'])} → ${nameOf(m['recipient'])}', style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 12)),
            subtitle: Text('${m['body']}', maxLines: 6, overflow: TextOverflow.ellipsis))])),
    ]);
  }
}

class _AgentPanel extends StatelessWidget {
  const _AgentPanel({required this.agent, required this.o, required this.nameOf, required this.onClose, required this.onChanged});
  final Map agent; final Map<String, dynamic> o; final String Function(String) nameOf; final VoidCallback onClose, onChanged;
  @override
  Widget build(BuildContext c) {
    final tasks = (o['tasks'] as List).where((t) => t['agent'] == agent['id']).toList();
    final direct = TextEditingController(); final api = c.read<ApiService>();
    return ListView(padding: const EdgeInsets.all(12), children: [
      Row(children: [CircleAvatar(radius: 22, backgroundColor: statusColour(agent['status']), child: Text('${agent['name']}'[0], style: const TextStyle(color: Colors.white))), const SizedBox(width: 10),
        Expanded(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('${agent['name']}', style: Theme.of(c).textTheme.titleMedium), Text('${agent['role']} · ${agent['room']}', style: const TextStyle(fontSize: 12))])),
        IconButton(tooltip: 'Back to the team room', icon: const Icon(Icons.close), onPressed: onClose)]),
      const SizedBox(height: 8),
      Text('Status: ${'${agent['status']}'.replaceAll('_', ' ')} · ${agent['open']} open · ${agent['done']} done'),
      if (agent['id'] != 'chief') SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('On the team'), value: agent['enabled'] == true,
        onChanged: (v) async { await api.patchMap('/v1/office/agents/${agent['id']}', {'enabled': v}); onChanged(); }),
      Row(children: [Expanded(child: TextField(controller: direct, decoration: InputDecoration(isDense: true, border: const OutlineInputBorder(), hintText: 'Ask ${agent['name']} directly'))),
        IconButton(tooltip: 'Send', icon: const Icon(Icons.send), onPressed: () async { if (direct.text.trim().isEmpty) return; await api.postMap('/v1/office/requests', {'request': direct.text.trim(), 'agent': agent['id']}); onChanged(); })]),
      const SizedBox(height: 12),
      Text('Work', style: Theme.of(c).textTheme.titleSmall),
      if (tasks.isEmpty) const Text('Nothing yet.'),
      for (final t in tasks) Card(child: ListTile(title: Text('${t['title']}'), subtitle: Text('${t['status']}'.replaceAll('_', ' ')),
        leading: CircleAvatar(radius: 6, backgroundColor: statusColour(t['status'] == 'in_progress' ? 'working' : t['status'])),
        onTap: () async {
          final d = await api.getMap('/v1/office/tasks/${t['id']}');
          if (!c.mounted) return;
          await showModalBottomSheet(context: c, isScrollControlled: true, builder: (s) => DraggableScrollableSheet(expand: false, initialChildSize: 0.8, builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.all(16), children: [
            Text('${d['title']}', style: Theme.of(s).textTheme.titleMedium), Text('${d['status']}'.replaceAll('_', ' ')), const SizedBox(height: 8),
            if (d['result'] != null) SelectableText('${d['result']}'),
            if (d['needs_approval'] == true) Wrap(spacing: 8, children: [
              FilledButton(onPressed: () async { await api.postMap('/v1/office/tasks/${d['id']}/decide', {'approve': true}); if (s.mounted) Navigator.pop(s); onChanged(); }, child: const Text('Approve')),
              OutlinedButton(onPressed: () async { await api.postMap('/v1/office/tasks/${d['id']}/decide', {'approve': false}); if (s.mounted) Navigator.pop(s); onChanged(); }, child: const Text('Reject'))]),
            const Divider(), const Text('How the team worked on it'),
            for (final m in d['conversation'] as List) ListTile(dense: true, title: Text('${nameOf(m['sender'])} → ${nameOf(m['recipient'])}'), subtitle: Text('${m['body']}')),
          ])));
        })),
    ]);
  }
}
