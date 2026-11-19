import 'dart:math';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';

const kWbStroke = 'com.amerteams.wb.stroke';
const kWbClear = 'com.amerteams.wb.clear';
const kWbText = 'com.amerteams.wb.text';          // {x, y, text, size, color}; x and y are 0..1 like stroke points
const kWbTemplate = 'com.amerteams.wb.template';  // {name, strokes: [...], texts: [...]}: a whole board in one event

/// Board templates (Phase 3 "whiteboard templates"): drawn with the same strokes and labels as a person would.
Map<String, Object?> wbTemplate(String name) {
  List<List<double>> line(double x1, double y1, double x2, double y2) => [[x1, y1], [x2, y2]];
  List<List<double>> box(double x, double y, double w, double h) => [[x, y], [x + w, y], [x + w, y + h], [x, y + h], [x, y]];
  List<List<double>> circle(double cx, double cy, double r) => [for (var i = 0; i <= 24; i++) [cx + r * cos(i * pi / 12), cy + r * 1.6 * sin(i * pi / 12)]];
  Map<String, Object?> st(List<List<double>> pts, [int color = 0xFF37474F, double w = 3]) => {'points': pts, 'color': color, 'width': w};
  Map<String, Object?> tx(double x, double y, String t, [double size = 18, int color = 0xFF212121]) => {'x': x, 'y': y, 'text': t, 'size': size, 'color': color};
  switch (name) {
    case 'retro': return {'name': 'Retrospective', 'strokes': [st(line(.333, .05, .333, .97)), st(line(.666, .05, .666, .97))],
      'texts': [tx(.04, .02, 'Went well', 22, 0xFF2E7D32), tx(.37, .02, 'To improve', 22, 0xFFC62828), tx(.70, .02, 'Actions', 22, 0xFF1565C0)]};
    case 'swot': return {'name': 'SWOT', 'strokes': [st(line(.5, .03, .5, .97)), st(line(.02, .5, .98, .5))],
      'texts': [tx(.03, .03, 'Strengths', 22, 0xFF2E7D32), tx(.53, .03, 'Weaknesses', 22, 0xFFC62828), tx(.03, .52, 'Opportunities', 22, 0xFF1565C0), tx(.53, .52, 'Threats', 22, 0xFFEF6C00)]};
    case 'network':                               // optical layer (ROADM ring) under an IP layer (routers), joined by client links
      final roadm = [(.2, .72), (.5, .88), (.8, .72), (.5, .56)]; final routers = [(.2, .2), (.5, .12), (.8, .2)];
      return {'name': 'Network sketch', 'strokes': [
        for (var i = 0; i < roadm.length; i++) st(line(roadm[i].$1, roadm[i].$2, roadm[(i + 1) % roadm.length].$1, roadm[(i + 1) % roadm.length].$2), 0xFF1565C0, 4),
        for (final r in roadm) st(circle(r.$1, r.$2, .035), 0xFF1565C0, 3),
        for (final r in routers) st(box(r.$1 - .04, r.$2 - .05, .08, .1), 0xFF2E7D32, 3),
        st(line(.2, .25, .5, .17), 0xFF2E7D32), st(line(.5, .17, .8, .25), 0xFF2E7D32),
        for (var i = 0; i < 3; i++) st(line(routers[i].$1, routers[i].$2 + .05, [roadm[0], roadm[3], roadm[2]][i].$1, [roadm[0], roadm[3], roadm[2]][i].$2 - .055), 0xFF9E9E9E, 2),
      ], 'texts': [tx(.02, .45, 'Optical layer (DWDM / OTN)', 16, 0xFF1565C0), tx(.02, .02, 'IP / MPLS layer', 16, 0xFF2E7D32),
        for (var i = 0; i < roadm.length; i++) tx(roadm[i].$1 + .045, roadm[i].$2 - .02, 'ROADM ${String.fromCharCode(65 + i)}', 14, 0xFF1565C0),
        for (var i = 0; i < routers.length; i++) tx(routers[i].$1 + .05, routers[i].$2 - .02, 'PE${i + 1}', 14, 0xFF2E7D32)]};
  }
  return {'name': name, 'strokes': [], 'texts': []};
}

/// Shared whiteboard. Each stroke is an end-to-end encrypted event in the chat, so everyone in the
/// meeting (and anyone joining later) sees the same board.
class WhiteboardScreen extends StatefulWidget { const WhiteboardScreen({super.key, required this.roomId}); final String roomId; @override State<WhiteboardScreen> createState() => _S(); }
class _S extends State<WhiteboardScreen> {
  Timeline? tl; List<Offset> current = []; Color colour = Colors.black; double width = 3; bool eraser = false;
  static const palette = [Colors.black, Colors.red, Colors.blue, Colors.green, Colors.orange, Colors.purple];
  // The SDK briefly drops rooms while it re-syncs (e.g. after blocking someone): keep the last known room, never crash.
  Room? _room;
  Room get room => _room = context.read<MatrixService>().client.getRoomById(widget.roomId) ?? _room ?? (throw StateError('This chat is no longer available'));
  @override void initState() { super.initState(); WidgetsBinding.instance.addPostFrameCallback((_) async { tl = await room.getTimeline(onUpdate: () { if (mounted) setState(() {}); }); setState(() {}); }); }
  @override void dispose() { tl?.cancelSubscriptions(); super.dispose(); }

  bool textMode = false;
  /// Since the last clear (a template counts as a clear followed by its own strokes and labels), oldest first.
  List<Event> get _since {
    final evs = (tl?.events ?? []).reversed.toList();
    final last = evs.lastIndexWhere((e) => e.type == kWbClear || e.type == kWbTemplate);
    return evs.skip(last < 0 ? 0 : last).toList();
  }
  List<Map<String, Object?>> get strokes => [for (final e in _since) ...switch (e.type) {
    kWbStroke => [e.content], kWbTemplate => ((e.content['strokes'] as List?) ?? const []).cast<Map<String, Object?>>(), _ => const <Map<String, Object?>>[] }];
  List<Map<String, Object?>> get texts => [for (final e in _since) ...switch (e.type) {
    kWbText => [e.content], kWbTemplate => ((e.content['texts'] as List?) ?? const []).cast<Map<String, Object?>>(), _ => const <Map<String, Object?>>[] }];

  Future<void> _addText(Offset at, Size s) async {
    final t = TextEditingController();
    final v = await showDialog<String>(context: context, builder: (d) => AlertDialog(title: const Text('Add a label'), content: TextField(controller: t, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, t.text), child: const Text('Add'))]));
    if (v == null || v.trim().isEmpty) return;
    await room.sendEvent({'x': at.dx / s.width, 'y': at.dy / s.height, 'text': v.trim(), 'size': 18.0, 'color': colour.toARGB32(), 'body': '🏷 ${v.trim()}'}, type: kWbText);
  }

  Future<void> _send(Size s) async {
    if (current.length < 2) { setState(() => current = []); return; }
    final pts = [for (final p in current) [double.parse((p.dx / s.width).toStringAsFixed(4)), double.parse((p.dy / s.height).toStringAsFixed(4))]];
    final c = eraser ? Colors.white : colour;
    setState(() => current = []);
    await room.sendEvent({'points': pts, 'color': c.toARGB32(), 'width': eraser ? 24.0 : width, 'body': '✏️ drew on the whiteboard'}, type: kWbStroke);
  }

  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: const Text('Whiteboard'), actions: [
      PopupMenuButton<String>(tooltip: 'Templates', icon: const Icon(Icons.dashboard_customize_outlined), onSelected: (k) async {
        final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: const Text('Use a template?'), content: const Text('This replaces the board for everyone.'),
          actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Use template'))]));
        if (ok == true) await room.sendEvent({...wbTemplate(k), 'body': '🧩 whiteboard template: ${wbTemplate(k)['name']}'}, type: kWbTemplate);
      }, itemBuilder: (_) => const [PopupMenuItem(value: 'retro', child: Text('Retrospective')), PopupMenuItem(value: 'swot', child: Text('SWOT')),
        PopupMenuItem(value: 'network', child: Text('Network sketch (optical and IP)'))]),
      IconButton(tooltip: 'Clear for everyone', icon: const Icon(Icons.delete_sweep), onPressed: () => room.sendEvent({'body': '🧽 cleared the whiteboard'}, type: kWbClear)),
    ]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final p in palette) GestureDetector(onTap: () => setState(() { colour = p; eraser = false; }),
          child: CircleAvatar(radius: 14, backgroundColor: p, child: !eraser && colour == p ? const Icon(Icons.check, size: 16, color: Colors.white) : null)),
        IconButton(tooltip: 'Text', isSelected: textMode, icon: const Icon(Icons.text_fields), onPressed: () => setState(() { textMode = !textMode; eraser = false; })),
        IconButton(tooltip: 'Eraser', isSelected: eraser, icon: const Icon(Icons.auto_fix_normal), onPressed: () => setState(() => eraser = !eraser)),
        SizedBox(width: 140, child: Slider(min: 1, max: 12, value: width, onChanged: (v) => setState(() => width = v))),
      ])),
      Expanded(child: LayoutBuilder(builder: (_, box) => Container(margin: const EdgeInsets.all(8), color: Colors.white,
        child: GestureDetector(
          onTapUp: (d) { if (textMode) _addText(d.localPosition, Size(box.maxWidth - 16, box.maxHeight - 16)); },
          onPanStart: (d) => setState(() => current = [d.localPosition]),
          onPanUpdate: (d) => setState(() => current.add(d.localPosition)),
          onPanEnd: (_) => _send(Size(box.maxWidth - 16, box.maxHeight - 16)),
          child: CustomPaint(size: Size.infinite, painter: _Board(strokes, current, eraser ? Colors.white : colour, eraser ? 24 : width, texts)))))),
    ]));
}

class _Board extends CustomPainter {
  _Board(this.strokes, this.current, this.colour, this.width, [this.texts = const []]);
  final List<Map<String, Object?>> strokes; final List<Offset> current; final Color colour; final double width; final List<Map<String, Object?>> texts;
  @override void paint(Canvas canvas, Size s) {
    for (final st in strokes) {
      final pts = (st['points'] as List).map((p) => Offset((p[0] as num) * s.width, (p[1] as num) * s.height)).toList();
      _line(canvas, pts, Color((st['color'] as num).toInt()), (st['width'] as num).toDouble());
    }
    _line(canvas, current, colour, width);
    for (final t in texts) {
      final tp = TextPainter(text: TextSpan(text: '${t['text']}', style: TextStyle(fontSize: (t['size'] as num?)?.toDouble() ?? 18, color: Color((t['color'] as num?)?.toInt() ?? 0xFF212121), fontWeight: FontWeight.w600)),
          textDirection: TextDirection.ltr)..layout(maxWidth: s.width * .45);
      tp.paint(canvas, Offset((t['x'] as num).toDouble() * s.width, (t['y'] as num).toDouble() * s.height));
    }
  }
  void _line(Canvas c, List<Offset> pts, Color col, double w) {
    if (pts.length < 2) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) { path.lineTo(p.dx, p.dy); }
    c.drawPath(path, Paint()..color = col..strokeWidth = w..style = PaintingStyle.stroke..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
  }
  @override bool shouldRepaint(_) => true;
}
