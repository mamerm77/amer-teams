import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import '../services/canvas_crdt.dart';
import '../services/canvas_service.dart';

/// Canvases attached to a chat (Slack canvas / Loop style). Opened from the chat's menu.
class CanvasListScreen extends StatefulWidget {
  const CanvasListScreen({super.key, required this.room});
  final Room room;
  @override State<CanvasListScreen> createState() => _L();
}
class _L extends State<CanvasListScreen> {
  Future<List<Event>>? f;
  @override void initState() { super.initState(); f = CanvasDoc.list(widget.room); }
  Future<void> _new() async {
    final t = TextEditingController();
    final name = await showDialog<String>(context: context, builder: (d) => AlertDialog(title: const Text('New canvas'),
      content: TextField(controller: t, autofocus: true, decoration: const InputDecoration(labelText: 'Title'), onSubmitted: (v) => Navigator.pop(d, v)),
      actions: [TextButton(onPressed: () => Navigator.pop(d), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, t.text), child: const Text('Create'))]));
    if (name == null || name.trim().isEmpty || !mounted) return;
    final id = await CanvasDoc.create(widget.room, name.trim());
    if (!mounted) return;
    await Navigator.push(context, MaterialPageRoute(builder: (_) => CanvasScreen(room: widget.room, id: id)));
    setState(() => f = CanvasDoc.list(widget.room));
  }
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text('Canvases · ${widget.room.getLocalizedDisplayname()}')),
    floatingActionButton: FloatingActionButton.extended(onPressed: _new, icon: const Icon(Icons.note_add_outlined), label: const Text('New canvas')),
    body: FutureBuilder<List<Event>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      if (s.data!.isEmpty) return const Center(child: Text('No canvases in this chat yet'));
      return ListView(children: [for (final e in s.data!) ListTile(leading: const Icon(Icons.description_outlined),
        title: Text('${e.content['title'] ?? 'Canvas'}'),
        subtitle: Text('${e.senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('d MMM HH:mm').format(e.originServerTs)} · encrypted'),
        onTap: () => Navigator.push(c, MaterialPageRoute(builder: (_) => CanvasScreen(room: widget.room, id: '${e.content['canvas_id']}'))))]);
    }));
}

class CanvasScreen extends StatefulWidget {
  const CanvasScreen({super.key, required this.room, required this.id});
  final Room room; final String id;
  @override State<CanvasScreen> createState() => _C();
}

class _C extends State<CanvasScreen> {
  late final CanvasDoc d = CanvasDoc(widget.room, widget.id);
  final ctl = <String, TextEditingController>{}, shown = <String, String>{};
  @override void initState() { super.initState(); d.addListener(_changed); d.load(); }
  @override void dispose() { d.removeListener(_changed); d.dispose(); for (final c in ctl.values) { c.dispose(); } super.dispose(); }

  /// Remote changes: update each field, keeping the cursor where it was.
  void _changed() {
    for (final e in ctl.entries) {
      final want = e.key.startsWith('cell:') ? _cellText(e.key) : d.text(e.key);
      if (e.value.text != want) {
        final sel = e.value.selection;
        e.value.value = TextEditingValue(text: want, selection: TextSelection.collapsed(offset: sel.baseOffset.clamp(0, want.length)));
      }
      shown[e.key] = want;
    }
    if (mounted) setState(() {});
  }
  String _cellText(String k) { final p = k.substring(5).split('§'); return d.cell(p[0], p[1], p[2]); }

  TextEditingController _c(String key, String initial) => ctl.putIfAbsent(key, () { shown[key] = initial; return TextEditingController(text: initial); });

  Widget _text(String b, {TextStyle? style, String hint = 'Write…'}) {
    final c = _c(b, d.text(b));
    return TextField(controller: c, maxLines: null, style: style, decoration: InputDecoration(border: InputBorder.none, hintText: hint, isDense: true),
      onChanged: (v) { final old = shown[b] ?? ''; shown[b] = v; d.editText(b, old, v); });
  }

  Widget _block(BuildContext c, int i, Map<String, Object?> blk) {
    final b = d.bid(blk), cs = Theme.of(c).colorScheme;
    final body = switch (d.kind(blk)) {
      'h' => _text(b, style: Theme.of(c).textTheme.titleLarge, hint: 'Heading'),
      'todo' => Row(children: [
          Checkbox(value: d.prop(b, 'checked') == true, onChanged: (v) => d.setProp(b, 'checked', v == true)),
          Expanded(child: _text(b, hint: 'To-do', style: d.prop(b, 'checked') == true ? TextStyle(decoration: TextDecoration.lineThrough, color: cs.outline) : null))]),
      'table' => _table(c, b),
      'msg' => Card(color: cs.surfaceContainerHighest, child: ListTile(leading: const Icon(Icons.format_quote),
          title: Text('${d.prop(b, 'body') ?? ''}'), subtitle: Text('${d.prop(b, 'sender') ?? ''}'))),
      _ => _text(b),
    };
    return Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Expanded(child: body),
      PopupMenuButton<String>(tooltip: 'Block options', icon: Icon(Icons.more_vert, size: 18, color: cs.outline), onSelected: (v) {
        if (v == 'del') d.removeBlock(i);
        if (v == 'row') d.addRow(b);
        if (v == 'col') d.addCol(b);
      }, itemBuilder: (_) => [
        if (d.kind(blk) == 'table') const PopupMenuItem(value: 'row', child: Text('Add row')),
        if (d.kind(blk) == 'table') const PopupMenuItem(value: 'col', child: Text('Add column')),
        const PopupMenuItem(value: 'del', child: Text('Delete block'))]),
    ]);
  }

  Widget _table(BuildContext c, String b) {
    final rows = d.rows(b), cols = d.cols(b);
    return SingleChildScrollView(scrollDirection: Axis.horizontal, child: Table(defaultColumnWidth: const FixedColumnWidth(140),
      border: TableBorder.all(color: Theme.of(c).colorScheme.outlineVariant),
      children: [for (final r in rows) TableRow(children: [for (final col in cols) Padding(padding: const EdgeInsets.symmetric(horizontal: 6),
        child: () { final k = 'cell:$b§$r§$col'; final ctrl = _c(k, d.cell(b, r, col));
          return TextField(controller: ctrl, decoration: const InputDecoration(border: InputBorder.none, isDense: true),
            onChanged: (v) { shown[k] = v; d.setCell(b, r, col, v); }); }())])]));
  }

  Future<void> _embed() async {
    final tl = await widget.room.getTimeline();
    final msgs = tl.events.where((e) => e.type == EventTypes.Message && e.content['msgtype'] == 'm.text').take(30).toList();
    tl.cancelSubscriptions();
    if (!mounted) return;
    final e = await showModalBottomSheet<Event>(context: context, builder: (s) => SafeArea(child: ListView(children: [
      const ListTile(title: Text('Embed a message')),
      for (final m in msgs) ListTile(title: Text(m.body, maxLines: 2, overflow: TextOverflow.ellipsis), subtitle: Text(m.senderFromMemoryOrFallback.calcDisplayname()), onTap: () => Navigator.pop(s, m))])));
    if (e != null) d.addBlock('msg', props: {'event_id': e.eventId, 'body': e.body, 'sender': e.senderFromMemoryOrFallback.calcDisplayname()});
  }

  Future<void> _history() async {
    await showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => DraggableScrollableSheet(expand: false, builder: (_, sc) => ListView(controller: sc, children: [
      ListTile(title: Text('Version history (${d.history.length} edits)'), subtitle: const Text('Built from the encrypted edit events in this chat')),
      for (var i = d.history.length - 1; i >= 0; i--) ListTile(dense: true, leading: const Icon(Icons.history),
        title: Text('${d.history[i].senderFromMemoryOrFallback.calcDisplayname()} · ${DateFormat('d MMM HH:mm:ss').format(d.history[i].originServerTs)}'),
        subtitle: Text('${(d.history[i].content['ops'] as List?)?.length ?? 0} changes'),
        onTap: () { final v = d.versionAt(i); Navigator.pop(s); _showVersion(v, d.history[i]); }),
    ])));
  }
  void _showVersion(CrdtDoc v, Event at) => showDialog(context: context, builder: (x) => AlertDialog(
    title: Text('As of ${DateFormat('d MMM HH:mm:ss').format(at.originServerTs)}'),
    content: SizedBox(width: 480, child: SingleChildScrollView(child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final blk in v.visible('blocks')) () { final b = '${(blk['id'] as List)[0]}@${(blk['id'] as List)[1]}';
        return Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(switch ('${blk['val']}') {
          'todo' => '${v.get(b, 'checked') == true ? '☑' : '☐'} ${v.text('$b:text')}', 'table' => '[table]', 'msg' => '❝ ${v.get(b, 'body')}', _ => v.text('$b:text') },
          style: '${blk['val']}' == 'h' ? const TextStyle(fontWeight: FontWeight.bold, fontSize: 18) : null)); }()]))),
    actions: [TextButton(onPressed: () => Navigator.pop(x), child: const Text('Close'))]));

  Future<void> _rename() async {
    final t = TextEditingController(text: d.title);
    final v = await showDialog<String>(context: context, builder: (x) => AlertDialog(title: const Text('Rename canvas'), content: TextField(controller: t, autofocus: true),
      actions: [TextButton(onPressed: () => Navigator.pop(x), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(x, t.text), child: const Text('Save'))]));
    if (v != null && v.trim().isNotEmpty) d.setTitle(v.trim());
  }

  @override Widget build(BuildContext c) {
    if (!d.loaded) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
    final blocks = d.blocks;
    return Scaffold(
      appBar: AppBar(title: GestureDetector(onTap: _rename, child: Text(d.title)), actions: [
        IconButton(tooltip: 'Version history', icon: const Icon(Icons.history), onPressed: _history)]),
      body: Column(children: [
        Padding(padding: const EdgeInsets.fromLTRB(16, 4, 16, 0), child: Row(children: [
          const Icon(Icons.lock, size: 14, color: Colors.green), const SizedBox(width: 4),
          Expanded(child: Text(d.error ?? 'End-to-end encrypted · members of ${widget.room.getLocalizedDisplayname()} edit together',
              style: TextStyle(fontSize: 12, color: d.error != null ? Theme.of(c).colorScheme.error : null)))])),
        Expanded(child: blocks.isEmpty ? const Center(child: Text('Empty canvas: add a block below'))
          : ListView(padding: const EdgeInsets.all(12), children: [for (var i = 0; i < blocks.length; i++) _block(c, i, blocks[i])])),
        SafeArea(top: false, child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), child: Row(children: [
          for (final (k, l, ic) in [('h', 'Heading', Icons.title), ('p', 'Text', Icons.notes), ('todo', 'Checklist', Icons.check_box_outlined), ('table', 'Table', Icons.table_chart_outlined)])
            Padding(padding: const EdgeInsets.only(right: 6), child: ActionChip(avatar: Icon(ic, size: 18), label: Text(l), onPressed: () => d.addBlock(k))),
          ActionChip(avatar: const Icon(Icons.format_quote, size: 18), label: const Text('Message'), onPressed: _embed),
        ]))),
      ]),
    );
  }
}
