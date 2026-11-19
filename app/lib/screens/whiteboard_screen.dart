import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';

const kWbStroke = 'com.amerteams.wb.stroke';
const kWbClear = 'com.amerteams.wb.clear';

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

  List<Map<String, Object?>> get strokes {
    final evs = (tl?.events ?? []).reversed.toList();      // oldest first
    final lastClear = evs.lastIndexWhere((e) => e.type == kWbClear);
    return [for (final e in evs.skip(lastClear + 1)) if (e.type == kWbStroke) e.content];
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
      IconButton(tooltip: 'Clear for everyone', icon: const Icon(Icons.delete_sweep), onPressed: () => room.sendEvent({'body': '🧽 cleared the whiteboard'}, type: kWbClear)),
    ]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(8), child: Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
        for (final p in palette) GestureDetector(onTap: () => setState(() { colour = p; eraser = false; }),
          child: CircleAvatar(radius: 14, backgroundColor: p, child: !eraser && colour == p ? const Icon(Icons.check, size: 16, color: Colors.white) : null)),
        IconButton(tooltip: 'Eraser', isSelected: eraser, icon: const Icon(Icons.auto_fix_normal), onPressed: () => setState(() => eraser = !eraser)),
        SizedBox(width: 140, child: Slider(min: 1, max: 12, value: width, onChanged: (v) => setState(() => width = v))),
      ])),
      Expanded(child: LayoutBuilder(builder: (_, box) => Container(margin: const EdgeInsets.all(8), color: Colors.white,
        child: GestureDetector(
          onPanStart: (d) => setState(() => current = [d.localPosition]),
          onPanUpdate: (d) => setState(() => current.add(d.localPosition)),
          onPanEnd: (_) => _send(Size(box.maxWidth - 16, box.maxHeight - 16)),
          child: CustomPaint(size: Size.infinite, painter: _Board(strokes, current, eraser ? Colors.white : colour, eraser ? 24 : width)))))),
    ]));
}

class _Board extends CustomPainter {
  _Board(this.strokes, this.current, this.colour, this.width);
  final List<Map<String, Object?>> strokes; final List<Offset> current; final Color colour; final double width;
  @override void paint(Canvas canvas, Size s) {
    for (final st in strokes) {
      final pts = (st['points'] as List).map((p) => Offset((p[0] as num) * s.width, (p[1] as num) * s.height)).toList();
      _line(canvas, pts, Color((st['color'] as num).toInt()), (st['width'] as num).toDouble());
    }
    _line(canvas, current, colour, width);
  }
  void _line(Canvas c, List<Offset> pts, Color col, double w) {
    if (pts.length < 2) return;
    final path = Path()..moveTo(pts.first.dx, pts.first.dy);
    for (final p in pts.skip(1)) { path.lineTo(p.dx, p.dy); }
    c.drawPath(path, Paint()..color = col..strokeWidth = w..style = PaintingStyle.stroke..strokeCap = StrokeCap.round..strokeJoin = StrokeJoin.round);
  }
  @override bool shouldRepaint(_) => true;
}
