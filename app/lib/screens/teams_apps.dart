import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:matrix/matrix.dart';
import '../services/app_store.dart';
import '../services/decisions_tasks.dart';

/// The built-in Microsoft Teams apps, rebuilt on encrypted chat storage (docs/TEAMS_APPS.md).
/// Each opens in a chat or channel, like a Teams tab, and everyone there shares it.

// ============================== Lists (Microsoft Lists) ==============================
const _colTypes = ['text', 'number', 'date', 'choice', 'person', 'yes/no'];
const _listTemplates = {
  'Issue tracker': [('Issue', 'text', ''), ('Priority', 'choice', 'High,Medium,Low'), ('Status', 'choice', 'New,In progress,Blocked,Done'), ('Assigned to', 'person', ''), ('Due', 'date', '')],
  'Asset manager': [('Asset', 'text', ''), ('Site', 'text', ''), ('Vendor', 'choice', 'Ciena,Huawei,Nokia,Other'), ('Serial', 'text', ''), ('In service', 'yes/no', '')],
  'Risk register': [('Risk', 'text', ''), ('Likelihood', 'choice', 'High,Medium,Low'), ('Impact', 'choice', 'High,Medium,Low'), ('Owner', 'person', ''), ('Mitigation', 'text', '')],
  'Blank list': [('Title', 'text', '')],
};

class ListsApp extends StatefulWidget { const ListsApp({super.key, required this.room}); final Room room; @override State<ListsApp> createState() => _ListsState(); }
class _ListsState extends State<ListsApp> {
  List<StoreItem> lists = [], rows = []; StoreItem? open; String q = ''; int? sortCol; bool asc = true;
  Room get room => widget.room;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final l = await AppStore.items(room, 'lists', kind: 'list'); final r = await AppStore.items(room, 'lists', kind: 'row');
    if (mounted) setState(() { lists = l; rows = r; if (open != null) open = l.where((x) => x.id == open!.id).firstOrNull; });
  }
  List<Map> cols(StoreItem l) => (l['columns'] as List? ?? const []).whereType<Map>().toList();

  Future<void> _newList() async {
    var tpl = _listTemplates.keys.first; final name = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('New list'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Name')),
        const SizedBox(height: 8),
        DropdownButtonFormField<String>(value: tpl, decoration: const InputDecoration(labelText: 'Start from'), items: [for (final k in _listTemplates.keys) DropdownMenuItem(value: k, child: Text(k))], onChanged: (v) => set(() => tpl = v!)),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Create'))])));
    if (ok != true || name.text.trim().isEmpty) return;
    await AppStore.save(room, 'lists', {'title': name.text.trim(), 'columns': [for (final (n, t, ch) in _listTemplates[tpl]!) {'name': n, 'type': t, 'choices': ch}]}, kind: 'list');
    await _load();
  }

  Future<void> _addColumn(StoreItem l) async {
    final name = TextEditingController(), ch = TextEditingController(); var type = 'text';
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Add column'),
      content: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: name, autofocus: true, decoration: const InputDecoration(labelText: 'Column name')),
        DropdownButtonFormField<String>(value: type, decoration: const InputDecoration(labelText: 'Type'), items: [for (final t in _colTypes) DropdownMenuItem(value: t, child: Text(t))], onChanged: (v) => set(() => type = v!)),
        if (type == 'choice') TextField(controller: ch, decoration: const InputDecoration(labelText: 'Choices, separated by commas')),
      ]),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Add'))])));
    if (ok != true || name.text.trim().isEmpty) return;
    await AppStore.save(room, 'lists', {'item_id': l.id, 'title': l.s('title'), 'columns': [...cols(l), {'name': name.text.trim(), 'type': type, 'choices': ch.text.trim()}]}, kind: 'list');
    await _load();
  }

  Future<void> _editRow(StoreItem l, [StoreItem? row]) async {
    final cs = cols(l); final vals = <String, Object?>{...((row?['values'] as Map?)?.cast<String, Object?>() ?? {})};
    final ctl = {for (final c in cs) '${c['name']}': TextEditingController(text: '${vals['${c['name']}'] ?? ''}')};
    final people = room.getParticipants();
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text(row == null ? 'New item' : 'Edit item'),
      content: SizedBox(width: 440, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (final c in cs) Padding(padding: const EdgeInsets.only(bottom: 8), child: switch ('${c['type']}') {
          'choice' => DropdownButtonFormField<String>(value: ('${c['choices']}'.split(',').map((x) => x.trim()).contains(vals['${c['name']}']) ? '${vals['${c['name']}']}' : null),
              decoration: InputDecoration(labelText: '${c['name']}'), items: [for (final x in '${c['choices']}'.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty)) DropdownMenuItem(value: x, child: Text(x))],
              onChanged: (v) => set(() => vals['${c['name']}'] = v)),
          'person' => DropdownButtonFormField<String>(value: people.any((u) => u.id == vals['${c['name']}']) ? '${vals['${c['name']}']}' : null,
              decoration: InputDecoration(labelText: '${c['name']}'), items: [for (final u in people) DropdownMenuItem(value: u.id, child: Text(u.calcDisplayname()))],
              onChanged: (v) => set(() => vals['${c['name']}'] = v)),
          'yes/no' => SwitchListTile(contentPadding: EdgeInsets.zero, title: Text('${c['name']}'), value: vals['${c['name']}'] == true, onChanged: (v) => set(() => vals['${c['name']}'] = v)),
          'date' => OutlinedButton.icon(icon: const Icon(Icons.event), label: Text('${c['name']}: ${vals['${c['name']}'] ?? 'pick a date'}'), onPressed: () async {
              final p = await showDatePicker(context: d, initialDate: DateTime.tryParse('${vals['${c['name']}']}') ?? DateTime.now(), firstDate: DateTime(2000), lastDate: DateTime(2100));
              if (p != null) set(() => vals['${c['name']}'] = DateFormat('yyyy-MM-dd').format(p)); }),
          _ => TextField(controller: ctl['${c['name']}'], keyboardType: c['type'] == 'number' ? TextInputType.number : TextInputType.text, decoration: InputDecoration(labelText: '${c['name']}')),
        }),
      ]))),
      actions: [
        if (row != null) TextButton(onPressed: () async { await AppStore.delete(room, 'lists', row.id); if (d.mounted) Navigator.pop(d, false); _load(); }, child: const Text('Delete')),
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))])));
    if (ok != true) return;
    for (final c in cs.where((c) => c['type'] == 'text' || c['type'] == 'number')) {
      final t = ctl['${c['name']}']!.text.trim();
      vals['${c['name']}'] = c['type'] == 'number' ? num.tryParse(t) : t;
    }
    await AppStore.save(room, 'lists', {if (row != null) 'item_id': row.id, 'list': l.id, 'values': vals, 'title': '${vals['${cs.first['name']}'] ?? ''}'}, kind: 'row');
    await _load();
  }

  String _show(Map c, Object? v) => v == null ? '' : c['type'] == 'person' ? nameIn(room, '$v') : c['type'] == 'yes/no' ? (v == true ? 'Yes' : 'No') : '$v';

  @override Widget build(BuildContext c) {
    final l = open;
    if (l == null) {
      return Scaffold(floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('New list'), onPressed: _newList),
        body: RefreshIndicator(onRefresh: _load, child: ListView(children: [
          if (lists.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No lists yet. Track issues, assets, risks or anything with columns.')),
          for (final x in lists) ListTile(leading: const Icon(Icons.table_rows_outlined), title: Text(x.s('title')),
            subtitle: Text('${rows.where((r) => r['list'] == x.id).length} items · ${cols(x).length} columns'), onTap: () => setState(() => open = x)),
        ])));
    }
    final cs = cols(l);
    var mine = rows.where((r) => r['list'] == l.id && (q.isEmpty || '${r['values']}'.toLowerCase().contains(q.toLowerCase()))).toList();
    if (sortCol != null && sortCol! < cs.length) {
      final k = '${cs[sortCol!]['name']}';
      mine.sort((a, b) { final x = '${(a['values'] as Map?)?[k] ?? ''}', y = '${(b['values'] as Map?)?[k] ?? ''}'; final nx = num.tryParse(x), ny = num.tryParse(y);
        final r = nx != null && ny != null ? nx.compareTo(ny) : x.compareTo(y); return asc ? r : -r; });
    }
    return Scaffold(
      floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('New item'), onPressed: () => _editRow(l)),
      body: Column(children: [
        Padding(padding: const EdgeInsets.all(8), child: Row(children: [
          IconButton(tooltip: 'All lists', icon: const Icon(Icons.arrow_back), onPressed: () => setState(() => open = null)),
          Text(l.s('title'), style: Theme.of(c).textTheme.titleMedium), const SizedBox(width: 12),
          Expanded(child: TextField(decoration: const InputDecoration(isDense: true, prefixIcon: Icon(Icons.filter_list), hintText: 'Filter items', border: OutlineInputBorder()), onChanged: (v) => setState(() => q = v))),
          TextButton.icon(icon: const Icon(Icons.view_column_outlined), label: const Text('Add column'), onPressed: () => _addColumn(l)),
        ])),
        Expanded(child: SingleChildScrollView(child: SingleChildScrollView(scrollDirection: Axis.horizontal, child: DataTable(
          sortColumnIndex: sortCol, sortAscending: asc, showCheckboxColumn: false,
          columns: [for (var i = 0; i < cs.length; i++) DataColumn(label: Text('${cs[i]['name']}'), onSort: (ci, a) => setState(() { sortCol = ci; asc = a; }))],
          rows: [for (final r in mine) DataRow(onSelectChanged: (_) => _editRow(l, r), cells: [for (final col in cs) DataCell(Text(_show(col, (r['values'] as Map?)?['${col['name']}'])))])],
        )))),
      ]));
  }
}

// ============================== Forms (Microsoft Forms) ==============================
class FormsApp extends StatefulWidget { const FormsApp({super.key, required this.room}); final Room room; @override State<FormsApp> createState() => _FormsState(); }
class _FormsState extends State<FormsApp> {
  List<StoreItem> forms = [], responses = [];
  Room get room => widget.room;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final f = await AppStore.items(room, 'forms', kind: 'form'); final r = await AppStore.items(room, 'forms', kind: 'response');
    if (mounted) setState(() { forms = f; responses = r; });
  }
  List<Map> qs(StoreItem f) => (f['questions'] as List? ?? const []).whereType<Map>().toList();

  Future<void> _new() async {
    final title = TextEditingController(); final questions = <Map<String, Object?>>[]; var anon = false;
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('New form'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        TextField(controller: title, autofocus: true, decoration: const InputDecoration(labelText: 'Form title')),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Hide names in the results'), value: anon, onChanged: (v) => set(() => anon = v)),
        for (var i = 0; i < questions.length; i++) ListTile(dense: true, title: Text('${i + 1}. ${questions[i]['q']}'), subtitle: Text('${questions[i]['type']}${questions[i]['options'] != null ? ': ${questions[i]['options']}' : ''}'),
          trailing: IconButton(icon: const Icon(Icons.delete_outline), onPressed: () => set(() => questions.removeAt(i)))),
        Wrap(spacing: 6, children: [
          for (final t in const ['choice', 'text', 'rating']) ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(t == 'choice' ? 'Choice' : t == 'text' ? 'Text' : 'Rating'), onPressed: () async {
            final qt = await askText(d, 'Question'); if (qt == null) return;
            String? opts; if (t == 'choice') { opts = await askText(d, 'Options, separated by commas'); if (opts == null) return; }
            set(() => questions.add({'q': qt, 'type': t, if (opts != null) 'options': opts}));
          })]),
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Publish'))])));
    if (ok != true || title.text.trim().isEmpty || questions.isEmpty) return;
    await AppStore.save(room, 'forms', {'title': title.text.trim(), 'questions': questions, 'anonymous': anon}, kind: 'form');
    await room.sendTextEvent('📝 New form: ${title.text.trim()} — open Apps → Forms in this chat to respond.');
    await _load();
  }

  Future<void> _respond(StoreItem f) async {
    final ans = <int, Object?>{}; final ctl = <int, TextEditingController>{};
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: Text(f.s('title')),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
        for (var i = 0; i < qs(f).length; i++) ...[
          Padding(padding: const EdgeInsets.only(top: 10), child: Text('${i + 1}. ${qs(f)[i]['q']}', style: const TextStyle(fontWeight: FontWeight.w600))),
          switch ('${qs(f)[i]['type']}') {
            'choice' => Column(children: [for (final o in '${qs(f)[i]['options']}'.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty))
                RadioListTile<String>(dense: true, value: o, groupValue: ans[i] as String?, title: Text(o), onChanged: (v) => set(() => ans[i] = v))]),
            'rating' => Row(children: [for (var n = 1; n <= 5; n++) IconButton(icon: Icon((ans[i] as int? ?? 0) >= n ? Icons.star : Icons.star_border, color: Colors.amber), onPressed: () => set(() => ans[i] = n))]),
            _ => TextField(controller: ctl.putIfAbsent(i, () => TextEditingController()), maxLines: 3),
          },
        ],
      ]))),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Submit'))])));
    if (ok != true) return;
    ctl.forEach((i, t) => ans[i] = t.text.trim());
    await AppStore.save(room, 'forms', {'item_id': '${f.id}-${room.client.userID}', 'form': f.id, 'answers': [for (var i = 0; i < qs(f).length; i++) ans[i]]}, kind: 'response', summary: '[forms] response');
    await _load();
    if (mounted) ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Response submitted')));
  }

  void _results(StoreItem f) {
    final rs = responses.where((r) => r['form'] == f.id).toList(); final anon = f['anonymous'] == true;
    showModalBottomSheet(context: context, isScrollControlled: true, builder: (s) => DraggableScrollableSheet(expand: false, initialChildSize: .8, builder: (_, sc) => ListView(controller: sc, padding: const EdgeInsets.all(16), children: [
      Text('${f.s('title')} · ${rs.length} response${rs.length == 1 ? '' : 's'}', style: Theme.of(s).textTheme.titleLarge),
      for (var i = 0; i < qs(f).length; i++) ...[
        const Divider(), Text('${i + 1}. ${qs(f)[i]['q']}', style: const TextStyle(fontWeight: FontWeight.w600)),
        if (qs(f)[i]['type'] == 'choice')
          for (final o in '${qs(f)[i]['options']}'.split(',').map((x) => x.trim()).where((x) => x.isNotEmpty)) () {
            final n = rs.where((r) => (r['answers'] as List?)?.elementAtOrNull(i) == o).length;
            return ListTile(dense: true, title: Text(o), subtitle: LinearProgressIndicator(value: rs.isEmpty ? 0 : n / rs.length), trailing: Text('$n'));
          }()
        else if (qs(f)[i]['type'] == 'rating') () {
          final v = rs.map((r) => (r['answers'] as List?)?.elementAtOrNull(i)).whereType<num>().toList();
          return ListTile(dense: true, title: Text(v.isEmpty ? 'No ratings' : 'Average ${(v.reduce((a, b) => a + b) / v.length).toStringAsFixed(1)} of 5 (${v.length} ratings)'));
        }()
        else for (final r in rs) ListTile(dense: true, title: Text('${(r['answers'] as List?)?.elementAtOrNull(i) ?? ''}'), subtitle: anon ? null : Text(nameIn(room, r.by))),
      ],
    ])));
  }

  @override Widget build(BuildContext c) {
    final me = room.client.userID;
    return Scaffold(floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('New form'), onPressed: _new),
      body: RefreshIndicator(onRefresh: _load, child: ListView(children: [
        if (forms.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('No forms yet. Make a survey, quiz or registration with choice, text and rating questions.')),
        for (final f in forms) Card(child: ListTile(leading: const Icon(Icons.assignment_outlined), title: Text(f.s('title')),
          subtitle: Text('${qs(f).length} questions · ${responses.where((r) => r['form'] == f.id).length} responses · by ${nameIn(room, f.by)}'),
          trailing: Wrap(spacing: 6, children: [
            if (!responses.any((r) => r['form'] == f.id && r.by == me)) FilledButton.tonal(onPressed: () => _respond(f), child: const Text('Respond')) else const Chip(label: Text('Responded')),
            OutlinedButton(onPressed: () => _results(f), child: const Text('Results'))]))),
      ])));
  }
}

// ============================== Praise ==============================
const _badges = {'Thank you': '🙏', 'Kind heart': '💖', 'Team player': '🤝', 'Problem solver': '🧩', 'Leader': '🧭', 'Inspiring': '🌟', 'Above and beyond': '🚀', 'Courage': '🦁'};
class PraiseApp extends StatefulWidget { const PraiseApp({super.key, required this.room}); final Room room; @override State<PraiseApp> createState() => _PraiseState(); }
class _PraiseState extends State<PraiseApp> {
  List<StoreItem> items = []; Room get room => widget.room;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { final p = await AppStore.items(room, 'praise'); if (mounted) setState(() => items = p); }
  Future<void> _send() async {
    final people = room.getParticipants().where((u) => u.id != room.client.userID).toList(); if (people.isEmpty) return;
    var to = people.first.id; var badge = _badges.keys.first; final note = TextEditingController();
    final ok = await showDialog<bool>(context: context, builder: (d) => StatefulBuilder(builder: (d, set) => AlertDialog(title: const Text('Send praise'),
      content: SizedBox(width: 420, child: Column(mainAxisSize: MainAxisSize.min, children: [
        DropdownButtonFormField<String>(value: to, decoration: const InputDecoration(labelText: 'To'), items: [for (final u in people) DropdownMenuItem(value: u.id, child: Text(u.calcDisplayname()))], onChanged: (v) => set(() => to = v!)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, children: [for (final b in _badges.entries) ChoiceChip(label: Text('${b.value} ${b.key}'), selected: badge == b.key, onSelected: (_) => set(() => badge = b.key))]),
        TextField(controller: note, maxLines: 3, decoration: const InputDecoration(labelText: 'Add a note')),
      ])),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Send'))])));
    if (ok != true) return;
    await AppStore.save(room, 'praise', {'to': to, 'badge': badge, 'note': note.text.trim()});
    await room.sendTextEvent('${_badges[badge]} Praise for ${nameIn(room, to)}: $badge${note.text.trim().isEmpty ? '' : ' — ${note.text.trim()}'}');
    await _load();
  }
  @override Widget build(BuildContext c) {
    final count = <String, int>{}; for (final p in items) { count[p.s('to')] = (count[p.s('to')] ?? 0) + 1; }
    final top = count.entries.toList()..sort((a, b) => b.value.compareTo(a.value));
    return Scaffold(floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.celebration), label: const Text('Send praise'), onPressed: _send),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(8), children: [
        if (top.isNotEmpty) Card(child: Padding(padding: const EdgeInsets.all(12), child: Wrap(spacing: 12, runSpacing: 6, children: [const Text('Most praised:'), for (final e in top.take(5)) Chip(label: Text('${nameIn(room, e.key)} · ${e.value}'))]))),
        if (items.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Recognise a colleague with a badge and a note. It is posted in the chat too.')),
        for (final p in items) Card(child: ListTile(leading: Text(_badges[p.s('badge')] ?? '🏅', style: const TextStyle(fontSize: 28)),
          title: Text('${p.s('badge')} · for ${nameIn(room, p.s('to'))}'), subtitle: Text('${p.s('note').isEmpty ? '' : '${p.s('note')}\n'}from ${nameIn(room, p.by)} · ${DateFormat('d MMM y').format(p.at)}'))),
      ])));
  }
}

// ============================== Updates (check-ins) ==============================
class UpdatesApp extends StatefulWidget { const UpdatesApp({super.key, required this.room}); final Room room; @override State<UpdatesApp> createState() => _UpdatesState(); }
class _UpdatesState extends State<UpdatesApp> {
  List<StoreItem> templates = [], updates = []; Room get room => widget.room;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final t = await AppStore.items(room, 'updates', kind: 'template'); final u = await AppStore.items(room, 'updates', kind: 'update');
    if (mounted) setState(() { templates = t; updates = u; });
  }
  static String week(DateTime d) { final mon = DateTime(d.year, d.month, d.day).subtract(Duration(days: d.weekday - 1)); return DateFormat('yyyy-MM-dd').format(mon); }
  Future<void> _newTemplate() async {
    final name = await askText(context, 'Check-in name', hint: 'e.g. Weekly status'); if (name == null || !mounted) return;
    final qs = await askText(context, 'Questions, one per line', initial: 'What did you finish this week?\nWhat is next?\nAny blockers?', lines: 5); if (qs == null) return;
    await AppStore.save(room, 'updates', {'title': name, 'questions': qs.split('\n').map((x) => x.trim()).where((x) => x.isNotEmpty).toList()}, kind: 'template');
    await room.sendTextEvent('🔁 New check-in: $name — submit it every week in Apps → Updates.');
    await _load();
  }
  Future<void> _submit(StoreItem t) async {
    final qs = (t['questions'] as List? ?? const []).map((x) => '$x').toList(); final ctl = [for (final _ in qs) TextEditingController()];
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text('${t.s('title')} · week of ${week(DateTime.now())}'),
      content: SizedBox(width: 460, child: SingleChildScrollView(child: Column(mainAxisSize: MainAxisSize.min, children: [
        for (var i = 0; i < qs.length; i++) Padding(padding: const EdgeInsets.only(bottom: 8), child: TextField(controller: ctl[i], maxLines: 3, decoration: InputDecoration(labelText: qs[i])))]))),
      actions: [TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Submit'))]));
    if (ok != true) return;
    await AppStore.save(room, 'updates', {'item_id': '${t.id}-${week(DateTime.now())}-${room.client.userID}', 'template': t.id, 'week': week(DateTime.now()), 'answers': [for (final c in ctl) c.text.trim()]}, kind: 'update', summary: '[updates] check-in');
    await _load();
  }
  @override Widget build(BuildContext c) {
    final wk = week(DateTime.now()), me = room.client.userID, members = room.getParticipants().where((u) => u.membership == Membership.join).toList();
    return Scaffold(floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.add), label: const Text('New check-in'), onPressed: _newTemplate),
      body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(8), children: [
        if (templates.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Set up a recurring check-in (weekly status, daily stand-up) and see who has submitted.')),
        for (final t in templates) Card(child: ExpansionTile(leading: const Icon(Icons.update), title: Text(t.s('title')),
          subtitle: Text('This week: ${updates.where((u) => u['template'] == t.id && u['week'] == wk).length} of ${members.length} submitted'),
          trailing: updates.any((u) => u['template'] == t.id && u['week'] == wk && u.by == me) ? const Chip(label: Text('Submitted')) : FilledButton.tonal(onPressed: () => _submit(t), child: const Text('Submit')),
          children: [
            Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Wrap(spacing: 6, children: [
              for (final u in members.where((m) => !updates.any((x) => x['template'] == t.id && x['week'] == wk && x.by == m.id))) Chip(avatar: const Icon(Icons.hourglass_empty, size: 14), label: Text(u.calcDisplayname()))])),
            for (final u in updates.where((u) => u['template'] == t.id).take(30)) ListTile(dense: true, title: Text('${nameIn(room, u.by)} · week of ${u.s('week')}'),
              subtitle: Text([for (var i = 0; i < ((t['questions'] as List?)?.length ?? 0); i++) '${(t['questions'] as List)[i]}\n  ${(u['answers'] as List?)?.elementAtOrNull(i) ?? ''}'].join('\n'))),
          ])),
      ])));
  }
}

// ============================== Notes (OneNote / Wiki) ==============================
class NotesApp extends StatefulWidget { const NotesApp({super.key, required this.room}); final Room room; @override State<NotesApp> createState() => _NotesState(); }
class _NotesState extends State<NotesApp> {
  List<StoreItem> pages = []; StoreItem? open; Room get room => widget.room;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { final p = await AppStore.items(room, 'notes'); if (mounted) setState(() { pages = p; if (open != null) open = p.where((x) => x.id == open!.id).firstOrNull; }); }
  Future<void> _edit([StoreItem? p]) async {
    final title = TextEditingController(text: p?.s('title') ?? ''), section = TextEditingController(text: p?.s('section') ?? 'General'), body = TextEditingController(text: p?.s('text') ?? '');
    final ok = await showDialog<bool>(context: context, builder: (d) => AlertDialog(title: Text(p == null ? 'New page' : 'Edit page'),
      content: SizedBox(width: 560, child: Column(mainAxisSize: MainAxisSize.min, children: [
        TextField(controller: section, decoration: const InputDecoration(labelText: 'Section')),
        TextField(controller: title, autofocus: p == null, decoration: const InputDecoration(labelText: 'Page title')),
        const SizedBox(height: 8),
        TextField(controller: body, minLines: 10, maxLines: 20, decoration: const InputDecoration(border: OutlineInputBorder(), hintText: 'Write here. Lines starting with - become bullets; [ ] becomes a to-do.')),
      ])),
      actions: [if (p != null) TextButton(onPressed: () async { await AppStore.delete(room, 'notes', p.id); if (d.mounted) Navigator.pop(d, false); setState(() => open = null); _load(); }, child: const Text('Delete')),
        TextButton(onPressed: () => Navigator.pop(d, false), child: const Text('Cancel')), FilledButton(onPressed: () => Navigator.pop(d, true), child: const Text('Save'))]));
    if (ok != true || title.text.trim().isEmpty) return;
    await AppStore.save(room, 'notes', {if (p != null) 'item_id': p.id, 'title': title.text.trim(), 'section': section.text.trim().isEmpty ? 'General' : section.text.trim(), 'text': body.text});
    await _load();
  }
  @override Widget build(BuildContext c) {
    final sections = <String, List<StoreItem>>{}; for (final p in pages) { (sections[p.s('section')] ??= []).add(p); }
    final nav = ListView(children: [
      for (final s in sections.entries) ExpansionTile(initiallyExpanded: true, leading: const Icon(Icons.folder_outlined), title: Text(s.key), children: [
        for (final p in s.value) ListTile(dense: true, selected: open?.id == p.id, title: Text(p.s('title')), subtitle: Text('${nameIn(room, p.by)} · ${DateFormat('d MMM HH:mm').format(p.at)}'), onTap: () => setState(() => open = p))]),
      if (pages.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('A shared notebook for this chat: sections and pages, encrypted.')),
    ]);
    final page = open == null ? const Center(child: Text('Select a page')) : ListView(padding: const EdgeInsets.all(20), children: [
      Row(children: [Expanded(child: Text(open!.s('title'), style: Theme.of(c).textTheme.headlineSmall)), IconButton(tooltip: 'Edit page', icon: const Icon(Icons.edit), onPressed: () => _edit(open))]),
      Text('Last edited by ${nameIn(room, open!.by)} · ${DateFormat('d MMM y HH:mm').format(open!.at)}', style: Theme.of(c).textTheme.labelSmall), const Divider(),
      for (final line in open!.s('text').split('\n'))
        line.trimLeft().startsWith('[ ]') || line.trimLeft().startsWith('[x]')
          ? Row(children: [Icon(line.trimLeft().startsWith('[x]') ? Icons.check_box : Icons.check_box_outline_blank, size: 18), const SizedBox(width: 6), Expanded(child: Text(line.trimLeft().substring(3).trim()))])
          : line.trimLeft().startsWith('- ') ? Padding(padding: const EdgeInsets.only(left: 8), child: Text('•  ${line.trimLeft().substring(2)}'))
          : line.startsWith('# ') ? Padding(padding: const EdgeInsets.only(top: 8), child: Text(line.substring(2), style: Theme.of(c).textTheme.titleMedium))
          : SelectableText(line),
    ]);
    return Scaffold(floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.note_add_outlined), label: const Text('New page'), onPressed: () => _edit()),
      body: LayoutBuilder(builder: (_, k) => k.maxWidth >= 800 ? Row(children: [SizedBox(width: 280, child: nav), const VerticalDivider(width: 1), Expanded(child: page)])
          : open == null ? nav : Column(children: [Align(alignment: Alignment.centerLeft, child: TextButton.icon(icon: const Icon(Icons.arrow_back), label: const Text('Pages'), onPressed: () => setState(() => open = null))), Expanded(child: page)])));
  }
}

// ============================== Planner (board of the chat's tasks) ==============================
class PlannerApp extends StatefulWidget { const PlannerApp({super.key, required this.room}); final Room room; @override State<PlannerApp> createState() => _PlannerState(); }
class _PlannerState extends State<PlannerApp> {
  List<Task> tasks = []; Room get room => widget.room;
  static const buckets = [('open', 'To do'), ('in_progress', 'In progress'), ('blocked', 'Blocked'), ('done', 'Done')];
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async {
    final tl = await room.getTimeline(limit: 1500); final t = tasksIn(tl.events); tl.cancelSubscriptions();
    if (mounted) setState(() => tasks = t);
  }
  Future<void> _new(String status) async {
    final title = await askText(context, 'New task'); if (title == null) return;
    await saveTask(room, {'task_id': 'plan-${DateTime.now().microsecondsSinceEpoch}', 'title': title, 'owner': room.client.userID, 'status': status});
    await _load();
  }
  Future<void> _move(Task t, String status) async { await saveTask(room, t.copyWith({'status': status})); await _load(); }
  Future<void> _assign(Task t) async {
    final who = await showDialog<String>(context: context, builder: (d) => SimpleDialog(title: const Text('Assign to'), children: [
      for (final u in room.getParticipants()) SimpleDialogOption(onPressed: () => Navigator.pop(d, u.id), child: Text(u.calcDisplayname()))]));
    if (who != null) { await saveTask(room, t.copyWith({'owner': who})); await _load(); }
  }
  Future<void> _due(Task t) async {
    final p = await showDatePicker(context: context, initialDate: t.due ?? DateTime.now(), firstDate: DateTime(2020), lastDate: DateTime(2100));
    if (p != null) { await saveTask(room, t.copyWith({'due': DateFormat('yyyy-MM-dd').format(p)})); await _load(); }
  }
  @override Widget build(BuildContext c) {
    final cs = Theme.of(c).colorScheme;
    return RefreshIndicator(onRefresh: _load, child: SingleChildScrollView(scrollDirection: Axis.horizontal, padding: const EdgeInsets.all(8), child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
      for (final (k, label) in buckets) Container(width: 280, margin: const EdgeInsets.only(right: 8), padding: const EdgeInsets.all(8),
        decoration: BoxDecoration(color: cs.surfaceContainerHighest.withValues(alpha: .5), borderRadius: BorderRadius.circular(12)),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [Text('$label · ${tasks.where((t) => t.status == k).length}', style: Theme.of(c).textTheme.titleSmall), const Spacer(),
            IconButton(tooltip: 'Add task to $label', icon: const Icon(Icons.add), onPressed: () => _new(k))]),
          for (final t in tasks.where((t) => t.status == k)) Card(child: Padding(padding: const EdgeInsets.all(8), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(t.title, style: TextStyle(decoration: k == 'done' ? TextDecoration.lineThrough : null)),
            const SizedBox(height: 4),
            Wrap(spacing: 4, runSpacing: 4, children: [
              ActionChip(avatar: const Icon(Icons.person_outline, size: 14), label: Text(t.owner.isEmpty ? 'Assign' : nameIn(room, t.owner), style: const TextStyle(fontSize: 11)), onPressed: () => _assign(t)),
              ActionChip(avatar: Icon(Icons.event, size: 14, color: t.overdue ? Colors.red : null), label: Text(t.due == null ? 'Due date' : DateFormat('d MMM').format(t.due!), style: TextStyle(fontSize: 11, color: t.overdue ? Colors.red : null)), onPressed: () => _due(t)),
              PopupMenuButton<String>(tooltip: 'Move to', icon: const Icon(Icons.drive_file_move_outline, size: 18), onSelected: (v) => _move(t, v),
                itemBuilder: (_) => [for (final (k2, l2) in buckets) if (k2 != k) PopupMenuItem(value: k2, child: Text('Move to $l2'))]),
            ]),
          ]))),
        ])),
    ])));
  }
}

// ============================== Goals (Viva Goals / OKRs) ==============================
class GoalsApp extends StatefulWidget { const GoalsApp({super.key, required this.room}); final Room room; @override State<GoalsApp> createState() => _GoalsState(); }
class _GoalsState extends State<GoalsApp> {
  List<StoreItem> goals = []; Room get room => widget.room;
  @override void initState() { super.initState(); _load(); }
  Future<void> _load() async { final g = await AppStore.items(room, 'goals'); if (mounted) setState(() => goals = g); }
  List<Map> krs(StoreItem g) => (g['key_results'] as List? ?? const []).whereType<Map>().toList();
  double progress(StoreItem g) { final k = krs(g); if (k.isEmpty) return 0; return k.map((r) { final t = (r['target'] as num?) ?? 1; return t == 0 ? 0.0 : (((r['current'] as num?) ?? 0) / t).clamp(0, 1).toDouble(); }).reduce((a, b) => a + b) / k.length; }
  Future<void> _new() async {
    final title = await askText(context, 'Objective', hint: 'e.g. Launch the AI-DC interconnect by Q2'); if (title == null || !mounted) return;
    final kr = await askText(context, 'Key results, one per line as "description | target"', initial: 'Sites connected | 12\nLatency below 2 ms on all links | 100', lines: 5); if (kr == null) return;
    final list = [for (final l in kr.split('\n').where((l) => l.trim().isNotEmpty)) {'t': l.split('|').first.trim(), 'target': num.tryParse(l.split('|').length > 1 ? l.split('|')[1].trim() : '') ?? 100, 'current': 0}];
    await AppStore.save(room, 'goals', {'title': title, 'owner': room.client.userID, 'key_results': list});
    await _load();
  }
  Future<void> _check(StoreItem g, int i) async {
    final k = krs(g); final v = await askText(context, 'Progress: ${k[i]['t']} (target ${k[i]['target']})', initial: '${k[i]['current'] ?? 0}'); final n = num.tryParse(v ?? '');
    if (n == null) return;
    final updated = [for (var j = 0; j < k.length; j++) j == i ? {...k[j], 'current': n} : k[j]];
    await AppStore.save(room, 'goals', {'item_id': g.id, 'title': g.s('title'), 'owner': g.s('owner'), 'key_results': updated}, summary: '[goals] check-in ${g.s('title')}');
    await _load();
  }
  @override Widget build(BuildContext c) => Scaffold(floatingActionButton: FloatingActionButton.extended(icon: const Icon(Icons.flag_outlined), label: const Text('New objective'), onPressed: _new),
    body: RefreshIndicator(onRefresh: _load, child: ListView(padding: const EdgeInsets.all(8), children: [
      if (goals.isEmpty) const Padding(padding: EdgeInsets.all(24), child: Text('Objectives and key results for this team, with progress check-ins.')),
      for (final g in goals) Card(child: Padding(padding: const EdgeInsets.all(12), child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [Expanded(child: Text(g.s('title'), style: Theme.of(c).textTheme.titleMedium)), Text('${(progress(g) * 100).round()}%')]),
        Text('Owner ${nameIn(room, g.s('owner'))} · last check-in ${DateFormat('d MMM').format(g.at)}', style: Theme.of(c).textTheme.labelSmall),
        const SizedBox(height: 6), LinearProgressIndicator(value: progress(g)),
        for (var i = 0; i < krs(g).length; i++) ListTile(dense: true, title: Text('${krs(g)[i]['t']}'), subtitle: Text('${krs(g)[i]['current'] ?? 0} of ${krs(g)[i]['target']}'),
          trailing: TextButton(onPressed: () => _check(g, i), child: const Text('Check in'))),
      ]))),
    ])));
}
