import 'package:flutter/material.dart';
import 'package:flutter_tts/flutter_tts.dart';

/// Immersive Reader (Microsoft Teams parity): large, spaced text, adjustable size and spacing, line focus, and read
/// aloud with each word highlighted as it is spoken. Arabic is read with an Arabic voice and shown right to left.
/// Speech uses the device's own voices (nothing leaves the device). Linux desktops may have no voice: then
/// read-aloud says so and the rest still works.
class ImmersiveReader extends StatefulWidget {
  const ImmersiveReader({super.key, required this.text, this.from = ''}); final String text, from;
  @override State<ImmersiveReader> createState() => _S();
}
class _S extends State<ImmersiveReader> {
  final tts = FlutterTts(); double size = 26, spacing = 1.8, rate = 0.45; bool focus = false, speaking = false, dark = false; int start = -1, end = -1; String? err;
  bool get arabic => RegExp(r'[؀-ۿ]').allMatches(widget.text).length > widget.text.length / 4;
  @override void initState() {
    super.initState();
    tts.setProgressHandler((t, s, e, w) { if (mounted) setState(() { start = s; end = e; }); });
    tts.setCompletionHandler(() { if (mounted) setState(() { speaking = false; start = end = -1; }); });
  }
  @override void dispose() { tts.stop(); super.dispose(); }
  Future<void> _speak() async {
    if (speaking) { await tts.stop(); setState(() { speaking = false; start = end = -1; }); return; }
    try {
      await tts.setLanguage(arabic ? 'ar' : 'en-GB'); await tts.setSpeechRate(rate);
      setState(() { speaking = true; err = null; });
      await tts.speak(widget.text);
    } catch (e) { setState(() { speaking = false; err = 'Read aloud is not available on this device'; }); }
  }
  @override Widget build(BuildContext c) {
    final bg = dark ? const Color(0xFF1E1E1E) : const Color(0xFFF7F3E8), fg = dark ? const Color(0xFFEDEDED) : const Color(0xFF222222);
    final t = widget.text; final hi = start >= 0 && end <= t.length && end > start;
    final style = TextStyle(fontSize: size, height: spacing, color: fg, letterSpacing: size / 40);
    final body = RichText(textDirection: arabic ? TextDirection.rtl : TextDirection.ltr, text: TextSpan(style: style, children: hi
      ? [TextSpan(text: t.substring(0, start)), TextSpan(text: t.substring(start, end), style: TextStyle(backgroundColor: Colors.amber.withValues(alpha: .55))), TextSpan(text: t.substring(end))]
      : [TextSpan(text: t)]));
    return Scaffold(backgroundColor: bg,
      appBar: AppBar(backgroundColor: bg, foregroundColor: fg, title: Text(widget.from.isEmpty ? 'Immersive Reader' : 'Immersive Reader · ${widget.from}', style: const TextStyle(fontSize: 15)), actions: [
        IconButton(tooltip: 'Text size and spacing', icon: const Icon(Icons.text_fields), onPressed: () => showModalBottomSheet(context: c, builder: (s) => StatefulBuilder(builder: (s, set) => Padding(padding: const EdgeInsets.all(16), child: Column(mainAxisSize: MainAxisSize.min, children: [
          ListTile(title: const Text('Text size'), subtitle: Slider(min: 16, max: 56, value: size, onChanged: (v) { set(() {}); setState(() => size = v); })),
          ListTile(title: const Text('Line spacing'), subtitle: Slider(min: 1.2, max: 2.6, value: spacing, onChanged: (v) { set(() {}); setState(() => spacing = v); })),
          ListTile(title: const Text('Reading speed'), subtitle: Slider(min: 0.2, max: 0.8, value: rate, onChanged: (v) { set(() {}); setState(() => rate = v); })),
          SwitchListTile(title: const Text('Line focus'), value: focus, onChanged: (v) { set(() {}); setState(() => focus = v); }),
          SwitchListTile(title: const Text('Dark page'), value: dark, onChanged: (v) { set(() {}); setState(() => dark = v); }),
        ]))))),
      ]),
      floatingActionButton: FloatingActionButton.extended(onPressed: _speak, icon: Icon(speaking ? Icons.stop : Icons.volume_up), label: Text(speaking ? 'Stop' : 'Read aloud')),
      body: Column(children: [
        if (err != null) MaterialBanner(content: Text(err!), actions: [TextButton(onPressed: () => setState(() => err = null), child: const Text('OK'))]),
        Expanded(child: Center(child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 760), child: SingleChildScrollView(padding: const EdgeInsets.fromLTRB(32, 32, 32, 96),
          child: focus ? Container(padding: const EdgeInsets.symmetric(vertical: 8), decoration: BoxDecoration(border: Border.symmetric(horizontal: BorderSide(color: fg.withValues(alpha: .25)))), child: body) : body)))),
      ]));
  }
}
