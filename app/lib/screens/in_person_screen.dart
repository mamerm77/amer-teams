import '../services/locale.dart';
import '../services/labels.dart';
import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import 'package:matrix/matrix.dart';
import 'package:provider/provider.dart';
import 'package:speech_to_text/speech_to_text.dart';
import '../services/ai_gate.dart';
import '../services/api_service.dart';
import '../services/decisions_tasks.dart';
import '../services/matrix_service.dart';

/// In-person meeting notes (docs/IN_PERSON_NOTES.md): a meeting in a room, not a call. This device transcribes
/// speech on the device itself; you can mark who is speaking. At the end Amer writes the minutes into the chat you
/// pick, decisions become proposals to confirm and actions become tasks, as for online meetings. No audio is kept.
class InPersonScreen extends StatefulWidget {
  const InPersonScreen({super.key, this.room});
  final Room? room;
  @override State<InPersonScreen> createState() => _S();
}
class _S extends State<InPersonScreen> {
  final stt = SpeechToText(); bool on = false, busy = false; String partial = ''; String speaker = 'Speaker 1';
  final lines = <(DateTime, String, String)>[]; final speakers = <String>['Speaker 1', 'Speaker 2']; Room? room; final agenda = TextEditingController();
  DateTime? started; Timer? _restart;
  @override void initState() { super.initState(); room = widget.room; }
  @override void dispose() { _restart?.cancel(); stt.stop(); super.dispose(); }

  Future<void> _listen() async {
    if (!await stt.initialize(onStatus: (s) { if (on && (s == 'done' || s == 'notListening')) { _restart?.cancel(); _restart = Timer(const Duration(milliseconds: 300), _listen); } })) {
      _snack('Speech recognition is not available on this device'); setState(() => on = false); return;
    }
    await stt.listen(onResult: (r) {
      setState(() => partial = r.recognizedWords);
      if (r.finalResult && r.recognizedWords.trim().isNotEmpty) setState(() { lines.add((DateTime.now(), speaker, r.recognizedWords.trim())); partial = ''; });
    }, listenOptions: SpeechListenOptions(partialResults: true, onDevice: true, listenMode: ListenMode.dictation), pauseFor: const Duration(seconds: 8), listenFor: const Duration(minutes: 10));
  }
  Future<void> _toggle() async {
    if (on) { on = false; _restart?.cancel(); await stt.stop(); setState(() {}); return; }
    on = true; started ??= DateTime.now(); setState(() {}); await _listen();
  }
  void _snack(String t) => ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(t)));

  String get transcript => lines.map((l) => '${l.$1.toIso8601String().substring(11, 16)} ${l.$2}: ${l.$3}').join('\n');

  Future<void> _finish() async {
    if (on) await _toggle();
    final r = room; if (r == null) { _snack('Choose the chat for the minutes first'); return; }
    if (lines.isEmpty) { _snack('Nothing was transcribed'); return; }
    final g = aiFor(r); if (!g.allowed) { _snack(g.where); return; }
    setState(() => busy = true);
    final api = context.read<ApiService>(); final label = labelOf(r);
    try {
      final outline = agenda.text.trim().isEmpty ? '' : 'Agenda (use it as the outline): ${agenda.text.trim()}\n';
      final m = await api.ask('Write minutes for this in-person meeting. Speakers are labelled as the note-taker marked them.', context: '$outline$transcript', agent: 'minutes', labels: [if (label != null) label], encrypted: r.encrypted);
      await r.sendTextEvent('📝 Minutes (in-person meeting, ${started!.toLocal().toString().substring(0, 16)}, ${DateTime.now().difference(started!).inMinutes} min)\n${m['answer']}');
      final names = speakers.join(', ');
      final f = await api.ask('From this meeting, reply ONLY with JSON {"decisions":[{"text":str}],"actions":[{"title":str,"owner":str,"due_days":int}]}. Use only what was said. Owners are speaker labels from: $names.',
          context: transcript, agent: 'assist', labels: [if (label != null) label], encrypted: r.encrypted);
      final j = RegExp(r'\{.*\}', dotAll: true).firstMatch('${f['answer']}');
      var nd = 0, na = 0;
      if (j != null) {
        final x = jsonDecode(j.group(0)!) as Map; final me = r.client.userID!;
        String? owner(Object? n) => r.getParticipants().where((u) => u.calcDisplayname().toLowerCase() == '$n'.toLowerCase()).firstOrNull?.id;
        for (final d in ((x['decisions'] as List?) ?? const []).take(10)) { await proposeDecision(r, text: '${d['text']}', owner: me); nd++; }
        for (final a in ((x['actions'] as List?) ?? const []).take(20)) {
          final days = (a['due_days'] as num?)?.toInt();
          await saveTask(r, {'task_id': 'task-${DateTime.now().microsecondsSinceEpoch}-$na', 'title': '${a['title']}${owner(a['owner']) == null && a['owner'] != null ? ' (${a['owner']})' : ''}', 'owner': owner(a['owner']) ?? me, 'status': 'open',
            if (days != null) 'due': DateTime.now().add(Duration(days: days)).toIso8601String().substring(0, 10)}); na++;
        }
      }
      if (!mounted) return;
      _snack('Minutes posted; $nd decision(s) to confirm and $na task(s) added'); Navigator.pop(context);
    } catch (e) { _snack('Could not write the minutes: $e'); }
    if (mounted) setState(() => busy = false);
  }

  @override
  Widget build(BuildContext c) {
    final chats = context.watch<MatrixService>().chats;
    return Scaffold(appBar: AppBar(title: Text(L.t(context, 'In-person meeting notes'))), body: Column(children: [
      Padding(padding: const EdgeInsets.all(12), child: Column(children: [
        DropdownButtonFormField<String>(value: room?.id, decoration: const InputDecoration(labelText: 'Post the minutes to'), isExpanded: true,
          items: [for (final r in chats) DropdownMenuItem(value: r.id, child: Text(r.getLocalizedDisplayname(), overflow: TextOverflow.ellipsis))], onChanged: (v) => setState(() => room = chats.firstWhere((r) => r.id == v))),
        TextField(controller: agenda, decoration: const InputDecoration(labelText: 'Agenda (optional)')),
        const SizedBox(height: 8),
        const Text('Speech is transcribed on this device; no audio is kept. Tell people in the room that notes are being taken.', style: TextStyle(fontSize: 12)),
        const SizedBox(height: 8),
        Wrap(spacing: 6, runSpacing: 6, crossAxisAlignment: WrapCrossAlignment.center, children: [
          const Text('Now speaking:'),
          for (final s in speakers) ChoiceChip(label: Text(s), selected: speaker == s, onSelected: (_) => setState(() => speaker = s)),
          ActionChip(avatar: const Icon(Icons.add, size: 16), label: Text(L.t(context, 'Name a speaker')), onPressed: () async {
            final t = TextEditingController();
            final n = await showDialog<String>(context: c, builder: (d) => AlertDialog(content: TextField(controller: t, autofocus: true, decoration: const InputDecoration(labelText: 'Name, as in the chat')),
              actions: [FilledButton(onPressed: () => Navigator.pop(d, t.text.trim()), child: Text(L.t(context, 'Add')))]));
            if (n != null && n.isNotEmpty) setState(() { speakers.add(n); speaker = n; });
          }),
        ]),
      ])),
      const Divider(height: 1),
      Expanded(child: ListView(reverse: true, padding: const EdgeInsets.all(12), children: [
        if (partial.isNotEmpty) Text('$speaker: $partial…', style: const TextStyle(fontStyle: FontStyle.italic)),
        for (final l in lines.reversed) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text('${l.$1.toLocal().toString().substring(11, 16)}  ${l.$2}: ${l.$3}')),
        if (lines.isEmpty && partial.isEmpty) const Center(child: Text('Press Start and put the device in the middle of the table.')),
      ])),
      SafeArea(child: Padding(padding: const EdgeInsets.all(12), child: Row(children: [
        Expanded(child: FilledButton.icon(onPressed: busy ? null : _toggle, icon: Icon(on ? Icons.pause : Icons.mic), label: Text(on ? 'Pause' : (lines.isEmpty ? 'Start' : 'Resume')))),
        const SizedBox(width: 12),
        Expanded(child: OutlinedButton.icon(onPressed: busy || lines.isEmpty ? null : _finish, icon: busy ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2)) : const Icon(Icons.description), label: Text(L.t(context, 'Finish and write minutes')))),
      ]))),
    ]));
  }
}
