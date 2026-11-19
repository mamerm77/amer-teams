import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import '../services/office_text.dart';
import 'file_preview_screen.dart';

/// Shared files with versions and grouping (docs/FILES.md). Built on this device from the chat's encrypted history:
/// a file shared again under the same name is a new version of it; earlier versions stay one tap away.
class FilesScreen extends StatefulWidget {
  const FilesScreen({super.key, required this.room});
  final Room room;
  @override State<FilesScreen> createState() => _S();
}
class _S extends State<FilesScreen> {
  Map<String, List<Event>> byName = {}; bool loading = true; String kind = 'documents'; final q = TextEditingController();
  static const kinds = {'documents': 'Documents', 'images': 'Images', 'media': 'Audio and video', 'other': 'Other'};
  static String kindOf(Event e) => switch (e.messageType) {
    MessageTypes.Image => 'images', MessageTypes.Video || MessageTypes.Audio => 'media',
    _ => OfficeText.canPreview(e.body) ? 'documents' : 'other' };
  static String key(Event e) => e.body.trim().toLowerCase();
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final tl = await widget.room.getTimeline();
    for (var i = 0; i < 6 && tl.canRequestHistory; i++) { await tl.requestHistory(historyCount: 250); }
    final files = tl.events.where((e) => e.type == EventTypes.Message && !e.redacted && {MessageTypes.Image, MessageTypes.File, MessageTypes.Audio, MessageTypes.Video}.contains(e.messageType));
    final m = <String, List<Event>>{};
    for (final e in files) { m.putIfAbsent(key(e), () => []).add(e); }           // newest first, as timelines give them
    tl.cancelSubscriptions();
    if (mounted) setState(() { byName = m; loading = false; });
  }
  String _size(Event e) { final s = (e.content['info'] as Map?)?['size'] as int?; return s == null ? '' : s > 1 << 20 ? '${(s / (1 << 20)).toStringAsFixed(1)} MB' : '${(s / 1024).ceil()} KB'; }
  void _open(Event e) => Navigator.push(context, MaterialPageRoute(builder: (_) => FilePreviewScreen(room: widget.room, event: e)));
  @override
  Widget build(BuildContext c) {
    final groups = byName.entries.where((g) => kindOf(g.value.first) == kind && (q.text.isEmpty || g.key.contains(q.text.toLowerCase()))).toList()
      ..sort((a, b) => b.value.first.originServerTs.compareTo(a.value.first.originServerTs));
    String d(DateTime t) => t.toLocal().toString().substring(0, 16);
    return DefaultTabController(length: kinds.length, child: Scaffold(
      appBar: AppBar(title: Text('Files · ${widget.room.getLocalizedDisplayname()}'), bottom: TabBar(isScrollable: true, onTap: (i) => setState(() => kind = kinds.keys.elementAt(i)),
        tabs: [for (final k in kinds.entries) Tab(text: '${k.value} (${byName.values.where((v) => kindOf(v.first) == k.key).length})')])),
      body: loading ? const Center(child: CircularProgressIndicator()) : Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: TextField(controller: q, decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Filter by name', isDense: true), onChanged: (_) => setState(() {}))),
        Expanded(child: groups.isEmpty ? const Center(child: Text('No files of this kind')) : ListView(children: [for (final g in groups) () {
          final latest = g.value.first;
          final title = ListTile(leading: Icon(kind == 'images' ? Icons.image_outlined : kind == 'media' ? Icons.movie_outlined : Icons.description_outlined),
            title: Text(latest.body), subtitle: Text('${g.value.length > 1 ? 'v${g.value.length} · ' : ''}${latest.senderFromMemoryOrFallback.calcDisplayname()} · ${d(latest.originServerTs)}${_size(latest).isEmpty ? '' : ' · ${_size(latest)}'}'),
            onTap: () => _open(latest));
          if (g.value.length == 1) return title;
          return ExpansionTile(leading: title.leading, title: title.title!, subtitle: title.subtitle, children: [
            for (var i = 0; i < g.value.length; i++) ListTile(dense: true, contentPadding: const EdgeInsets.only(left: 72, right: 16),
              title: Text('Version ${g.value.length - i}${i == 0 ? ' (latest)' : ''}'), subtitle: Text('${g.value[i].senderFromMemoryOrFallback.calcDisplayname()} · ${d(g.value[i].originServerTs)}'),
              trailing: const Icon(Icons.open_in_new, size: 18), onTap: () => _open(g.value[i])),
          ]);
        }()])),
        const Padding(padding: EdgeInsets.all(8), child: Text('Share a file again with the same name to add a new version.', style: TextStyle(fontSize: 12))),
      ])));
  }
}
