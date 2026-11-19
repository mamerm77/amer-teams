import '../services/locale.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/chat_extras.dart';
import '../services/matrix_service.dart';
import 'chat_screen.dart';

/// Saved (starred) messages from every chat, in folders you make (docs/CHAT_EXTRAS.md). Folder names and which
/// message is in which folder are kept in your account data, like the saved list itself; message text is not.
const kSavedFolders = 'com.amerteams.saved_folders';

class SavedScreen extends StatefulWidget { const SavedScreen({super.key}); @override State<SavedScreen> createState() => _S(); }
class _S extends State<SavedScreen> {
  Future<List<Event>>? f; String? folder;          // null = all
  Client get c => context.read<MatrixService>().client;
  Map<String, dynamic> get data => Map<String, dynamic>.from(c.accountData[kSavedFolders]?.content ?? {});
  List<String> get folders => ((data['folders'] as List?) ?? const []).cast<String>();
  Map<String, String> get assign => Map<String, String>.from((data['assign'] as Map?) ?? const {});
  Future<void> _save(List<String> fs, Map<String, String> a) async { await c.setAccountData(c.userID!, kSavedFolders, {'folders': fs, 'assign': a}); if (mounted) setState(() {}); }
  @override void initState() { super.initState(); f = StarService(context.read<MatrixService>()).load(); }

  Future<void> _newFolder() async {
    final t = TextEditingController();
    final n = await showDialog<String>(context: context, builder: (d) => AlertDialog(title: const Text('New folder'), content: TextField(controller: t, autofocus: true, maxLength: 40),
      actions: [FilledButton(onPressed: () => Navigator.pop(d, t.text.trim()), child: Text(L.t(context, 'Create')))]));
    if (n != null && n.isNotEmpty && !folders.contains(n)) await _save([...folders, n], assign);
  }
  Future<void> _move(Event e) async {
    final v = await showDialog<String>(context: context, builder: (d) => SimpleDialog(title: const Text('Move to folder'), children: [
      SimpleDialogOption(onPressed: () => Navigator.pop(d, ''), child: Text(L.t(context, 'No folder'))),
      for (final x in folders) SimpleDialogOption(onPressed: () => Navigator.pop(d, x), child: Text(x))]));
    if (v == null) return;
    final a = assign; v.isEmpty ? a.remove(e.eventId) : a[e.eventId] = v; await _save(folders, a);
  }
  Future<void> _deleteFolder(String x) async {
    final a = assign..removeWhere((_, v) => v == x); await _save(folders.where((y) => y != x).toList(), a); setState(() => folder = null);
  }

  @override Widget build(BuildContext ctx) => Scaffold(appBar: AppBar(title: Text(L.t(context, 'Saved messages')), actions: [IconButton(tooltip: 'New folder', icon: const Icon(Icons.create_new_folder_outlined), onPressed: _newFolder)]),
    body: FutureBuilder<List<Event>>(future: f, builder: (_, s) {
      if (!s.hasData) return const Center(child: CircularProgressIndicator());
      if (s.data!.isEmpty) return const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Long-press any message and choose Save to keep it here.', textAlign: TextAlign.center)));
      final a = assign; final shown = s.data!.where((e) => folder == null || a[e.eventId] == folder).toList();
      return Column(children: [
        SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), child: Row(children: [
          ChoiceChip(label: Text('All (${s.data!.length})'), selected: folder == null, onSelected: (_) => setState(() => folder = null)), const SizedBox(width: 6),
          for (final x in folders) Padding(padding: const EdgeInsets.only(right: 6), child: InputChip(label: Text('$x (${s.data!.where((e) => a[e.eventId] == x).length})'), selected: folder == x,
            onSelected: (_) => setState(() => folder = x), onDeleted: () => _deleteFolder(x), deleteButtonTooltipMessage: 'Delete folder (messages stay saved)')),
        ])),
        Expanded(child: ListView(children: [for (final e in shown) ListTile(leading: Icon(a[e.eventId] != null ? Icons.folder : Icons.bookmark),
          title: Text(plainMentions(e.body), maxLines: 3, overflow: TextOverflow.ellipsis),
          subtitle: Text('${e.senderFromMemoryOrFallback.calcDisplayname()} · ${e.room.getLocalizedDisplayname()} · ${DateFormat('d MMM').format(e.originServerTs)}${a[e.eventId] != null ? ' · ${a[e.eventId]}' : ''}'),
          trailing: folders.isEmpty ? null : IconButton(tooltip: 'Move to folder', icon: const Icon(Icons.drive_file_move_outline), onPressed: () => _move(e)),
          onTap: () => Navigator.push(ctx, MaterialPageRoute(builder: (_) => ChatScreen(roomId: e.room.id))))])),
      ]);
    }));
}
