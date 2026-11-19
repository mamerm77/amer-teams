import 'dart:convert';
import 'dart:io';
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Accessibility settings (docs/ACCESSIBILITY.md), on top of what the operating system already provides
/// (screen readers, system text size, system high contrast): these apply inside Amer Teams on every platform.
class A11y extends ChangeNotifier {
  A11y._();
  static final instance = A11y._();
  double textScale = 1.0; bool highContrast = false, reduceMotion = false, boldText = false, captionsByDefault = false, underlineLinks = false;
  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/accessibility.json');
  Future<void> load() async {
    try {
      final f = await _f(); if (!await f.exists()) return;
      final j = jsonDecode(await f.readAsString()) as Map<String, dynamic>;
      textScale = (j['textScale'] as num?)?.toDouble().clamp(0.85, 2.0) ?? 1.0; highContrast = j['highContrast'] == true; reduceMotion = j['reduceMotion'] == true;
      boldText = j['boldText'] == true; captionsByDefault = j['captionsByDefault'] == true; underlineLinks = j['underlineLinks'] == true;
      notifyListeners();
    } catch (_) {}
  }
  Future<void> save() async {
    notifyListeners();
    try { await (await _f()).writeAsString(jsonEncode({'textScale': textScale, 'highContrast': highContrast, 'reduceMotion': reduceMotion, 'boldText': boldText,
      'captionsByDefault': captionsByDefault, 'underlineLinks': underlineLinks})); } catch (_) {}
  }

  /// Wraps the app: text size, bold text and reduced motion for everything below.
  Widget apply(BuildContext c, Widget child) {
    final mq = MediaQuery.of(c);
    return MediaQuery(data: mq.copyWith(
      textScaler: TextScaler.linear(mq.textScaler.scale(1) * textScale),
      boldText: mq.boldText || boldText,
      disableAnimations: mq.disableAnimations || reduceMotion,
      highContrast: mq.highContrast || highContrast), child: child);
  }

  ThemeData theme(ThemeData base, Brightness b) {
    if (!highContrast) return base;
    final cs = b == Brightness.dark ? const ColorScheme.highContrastDark() : const ColorScheme.highContrastLight();
    return base.copyWith(colorScheme: cs, scaffoldBackgroundColor: cs.surface,
      dividerTheme: DividerThemeData(color: cs.onSurface, thickness: 1),
      focusColor: cs.primary.withValues(alpha: 0.35),
      inputDecorationTheme: InputDecorationTheme(border: OutlineInputBorder(borderSide: BorderSide(color: cs.onSurface, width: 2))));
  }
}

class A11yScreen extends StatefulWidget {
  const A11yScreen({super.key});
  @override State<A11yScreen> createState() => _S();
}
class _S extends State<A11yScreen> {
  final a = A11y.instance;
  void _set(VoidCallback f) { setState(f); a.save(); }
  @override
  Widget build(BuildContext c) => Scaffold(appBar: AppBar(title: const Text('Accessibility')), body: ListView(children: [
    ListTile(title: const Text('Text size'), subtitle: Slider(value: a.textScale, min: 0.85, max: 2.0, divisions: 23, label: '${(a.textScale * 100).round()}%',
      semanticFormatterCallback: (v) => '${(v * 100).round()} percent', onChanged: (v) => _set(() => a.textScale = v))),
    Padding(padding: const EdgeInsets.symmetric(horizontal: 16), child: Text('Preview: Messages, meetings and menus use this size.', style: Theme.of(c).textTheme.bodyLarge)),
    SwitchListTile(title: const Text('High contrast'), subtitle: const Text('Stronger colours, borders and focus outlines'), value: a.highContrast, onChanged: (v) => _set(() => a.highContrast = v)),
    SwitchListTile(title: const Text('Bold text'), value: a.boldText, onChanged: (v) => _set(() => a.boldText = v)),
    SwitchListTile(title: const Text('Reduce motion'), subtitle: const Text('No animated transitions or floating reactions'), value: a.reduceMotion, onChanged: (v) => _set(() => a.reduceMotion = v)),
    SwitchListTile(title: const Text('Captions on when I join a call'), subtitle: const Text('Speech is transcribed on this device'), value: a.captionsByDefault, onChanged: (v) => _set(() => a.captionsByDefault = v)),
    SwitchListTile(title: const Text('Underline links'), value: a.underlineLinks, onChanged: (v) => _set(() => a.underlineLinks = v)),
    const ListTile(title: Text('Keyboard shortcuts in calls'), subtitle: Text('Ctrl+D mute or unmute · Ctrl+E camera · Ctrl+Shift+H raise hand · Ctrl+Shift+C captions · Ctrl+Shift+L leave')),
    const ListTile(title: Text('Screen readers'), subtitle: Text('Every button has a spoken label; call events (someone joins, hand raised, recording started) are announced.')),
  ]));
}
