import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:pdfrx/pdfrx.dart';
import '../services/office_text.dart';

/// File preview with comments (docs/FILE_PREVIEWS.md). The file is decrypted and rendered on this device; nothing
/// is sent to a conversion server. Comments are replies in the file's own thread, so they are end-to-end encrypted
/// like any message and show in the chat's thread view too.
class FilePreviewScreen extends StatefulWidget {
  const FilePreviewScreen({super.key, required this.room, required this.event, this.onDownload});
  final Room room; final Event event; final VoidCallback? onDownload;
  @override State<FilePreviewScreen> createState() => _S();
}

class _S extends State<FilePreviewScreen> {
  MatrixFile? file; Object? err; OfficePreview? office; Timeline? tl; final input = TextEditingController();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    try {
      final f = await widget.event.downloadAndDecryptAttachment();
      OfficePreview? o; if (OfficeText.ext(f.name) != 'pdf') o = OfficeText.read(f.name, f.bytes);
      tl = await widget.room.getTimeline(onUpdate: () { if (mounted) setState(() {}); });
      if (mounted) setState(() { file = f; office = o; });
    } catch (e) { if (mounted) setState(() => err = e); }
  }
  @override void dispose() { tl?.cancelSubscriptions(); super.dispose(); }

  List<Event> get comments => (tl?.events ?? []).where((e) => e.relationshipType == RelationshipTypes.thread && e.relationshipEventId == widget.event.eventId && e.type == EventTypes.Message).toList().reversed.toList();

  Widget _office(OfficePreview p) => switch (p) {
    DocPreview(:final paras) => ListView(padding: const EdgeInsets.all(16), children: [for (final (s, t) in paras)
      Padding(padding: const EdgeInsets.only(bottom: 10), child: Text(t, style: s.startsWith('Heading') || s == 'Title' ? Theme.of(context).textTheme.titleLarge : null))]),
    SheetPreview(:final sheets) => DefaultTabController(length: sheets.length, child: Column(children: [
      TabBar(isScrollable: true, tabs: [for (final s in sheets) Tab(text: s.$1)]),
      Expanded(child: TabBarView(children: [for (final s in sheets) _sheet(s.$2)])),
    ])),
    SlidesPreview(:final slides) => ListView(padding: const EdgeInsets.all(16), children: [for (var i = 0; i < slides.length; i++) Card(child: Padding(padding: const EdgeInsets.all(16),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [Text('Slide ${i + 1}', style: Theme.of(context).textTheme.labelSmall),
        if (slides[i].isNotEmpty) Text(slides[i].first, style: Theme.of(context).textTheme.titleMedium), for (final t in slides[i].skip(1)) Text(t)])))]),
    TextPreview(:final text) => SingleChildScrollView(padding: const EdgeInsets.all(16), child: SelectableText(text, style: const TextStyle(fontFamily: 'monospace'))),
  };

  Widget _sheet(List<List<String>> rows) {
    final n = rows.fold<int>(1, (m, r) => r.length > m ? r.length : m);
    return SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
      columns: [for (var i = 0; i < n; i++) DataColumn(label: Text(_colName(i)))],
      rows: [for (final r in rows) DataRow(cells: [for (var i = 0; i < n; i++) DataCell(Text(i < r.length ? r[i] : ''))])])));
  }
  static String _colName(int i) { var s = ''; i++; while (i > 0) { final m = (i - 1) % 26; s = String.fromCharCode(65 + m) + s; i = (i - m - 1) ~/ 26; } return s; }

  @override
  Widget build(BuildContext c) {
    final f = file;
    return Scaffold(
      appBar: AppBar(title: Text(widget.event.body, overflow: TextOverflow.ellipsis), actions: [
        if (widget.onDownload != null) IconButton(tooltip: 'Download', icon: const Icon(Icons.download), onPressed: widget.onDownload)]),
      body: err != null ? Center(child: Padding(padding: const EdgeInsets.all(24), child: Text('Cannot preview this file: $err\nDownload it to open it in another app.')))
          : f == null ? const Center(child: CircularProgressIndicator())
          : LayoutBuilder(builder: (c, box) {
              final view = office != null ? _office(office!) : PdfViewer.data(f.bytes, sourceName: widget.event.eventId ?? f.name);
              final side = _comments();
              return box.maxWidth > 900 ? Row(children: [Expanded(child: view), const VerticalDivider(width: 1), SizedBox(width: 320, child: side)])
                  : Column(children: [Expanded(flex: 3, child: view), const Divider(height: 1), Expanded(flex: 2, child: side)]);
            }),
    );
  }

  Widget _comments() => Column(children: [
    ListTile(dense: true, title: Text('Comments (${comments.length})'), subtitle: const Text('End-to-end encrypted, in this file\'s thread')),
    Expanded(child: ListView(children: [for (final e in comments) ListTile(dense: true, title: Text(e.body), subtitle: Text('${e.senderFromMemoryOrFallback.calcDisplayname()} · ${TimeOfDay.fromDateTime(e.originServerTs).format(context)}'))])),
    Padding(padding: const EdgeInsets.all(8), child: Row(children: [
      Expanded(child: TextField(controller: input, decoration: const InputDecoration(hintText: 'Add a comment', isDense: true, border: OutlineInputBorder()), onSubmitted: (_) => _send())),
      IconButton(tooltip: 'Send comment', icon: const Icon(Icons.send), onPressed: _send)])),
  ]);
  Future<void> _send() async {
    final t = input.text.trim(); if (t.isEmpty) return; input.clear();
    await widget.room.sendTextEvent(t, threadRootEventId: widget.event.eventId, threadLastEventId: comments.lastOrNull?.eventId ?? widget.event.eventId);
  }
}
