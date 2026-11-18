import 'dart:async';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import '../services/matrix_service.dart';

/// Search the organisation directory and pick one or more people.
Future<List<Profile>?> pickPeople(BuildContext context, {bool multiple = false, String title = 'Choose people'}) =>
    Navigator.push<List<Profile>>(context, MaterialPageRoute(builder: (_) => _Picker(multiple: multiple, title: title)));

class _Picker extends StatefulWidget { const _Picker({required this.multiple, required this.title}); final bool multiple; final String title; @override State<_Picker> createState() => _S(); }
class _S extends State<_Picker> {
  final q = TextEditingController(); List<Profile> results = []; final chosen = <String, Profile>{}; Timer? debounce; bool busy = false;
  @override void initState() { super.initState(); _search(''); }
  Future<void> _search(String t) async {
    setState(() => busy = true);
    try {
      final c = context.read<MatrixService>().client;
      final r = await c.searchUserDirectory(t.isEmpty ? (c.userID!.split(':').last) : t, limit: 30);
      setState(() => results = r.results.where((p) => p.userId != c.userID).toList());
    } catch (_) { setState(() => results = []); }
    finally { if (mounted) setState(() => busy = false); }
  }
  @override Widget build(BuildContext c) => Scaffold(
    appBar: AppBar(title: Text(widget.title), actions: [
      if (widget.multiple) TextButton(onPressed: chosen.isEmpty ? null : () => Navigator.pop(c, chosen.values.toList()), child: Text('Done (${chosen.length})'))]),
    body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: TextField(controller: q, autofocus: true,
        decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Search by name or username', border: OutlineInputBorder()),
        onChanged: (t) { debounce?.cancel(); debounce = Timer(const Duration(milliseconds: 300), () => _search(t)); })),
      if (busy) const LinearProgressIndicator(),
      Expanded(child: results.isEmpty && !busy ? const Center(child: Text('No people found'))
        : ListView(children: [for (final p in results) ListTile(
          leading: CircleAvatar(child: Text((p.displayName ?? p.userId).replaceAll('@', '').characters.first.toUpperCase())),
          title: Text(p.displayName ?? p.userId), subtitle: Text(p.userId),
          trailing: widget.multiple ? Checkbox(value: chosen.containsKey(p.userId), onChanged: (_) => setState(() => chosen.containsKey(p.userId) ? chosen.remove(p.userId) : chosen[p.userId] = p)) : null,
          onTap: () => widget.multiple ? setState(() => chosen.containsKey(p.userId) ? chosen.remove(p.userId) : chosen[p.userId] = p) : Navigator.pop(c, [p]))])),
    ]));
}
