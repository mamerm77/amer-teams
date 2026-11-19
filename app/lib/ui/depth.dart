import 'dart:convert';
import 'dart:io';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:path_provider/path_provider.dart';

/// Modern 3D UI with 2.5D and flat fallbacks (docs/UI_3D.md).
/// - 3D: cards tilt towards the pointer with real perspective and a light that follows; pages turn in depth.
/// - 2.5D: layered cards with directional shadows, no motion.
/// - Flat: no shadows or motion at all.
/// Automatic: 3D on desktop and web with a pointer, 2.5D on phones and tablets, Flat whenever the system or the
/// app's accessibility settings ask for reduced motion or high contrast.
enum DepthMode { auto, d3, d25, flat }

class Depth extends ChangeNotifier {
  Depth._();
  static final instance = Depth._();
  DepthMode mode = DepthMode.auto;
  Future<File> _f() async => File('${(await getApplicationSupportDirectory()).path}/depth.json');
  Future<void> load() async { try { final f = await _f(); if (await f.exists()) { mode = DepthMode.values.byName((jsonDecode(await f.readAsString()) as Map)['mode'] as String); notifyListeners(); } } catch (_) {} }
  Future<void> set(DepthMode m) async { mode = m; notifyListeners(); try { await (await _f()).writeAsString(jsonEncode({'mode': m.name})); } catch (_) {} }

  /// The mode actually used on this screen now.
  DepthMode effective(BuildContext c) {
    final mq = MediaQuery.maybeOf(c);
    if ((mq?.disableAnimations ?? false) || (mq?.highContrast ?? false)) return DepthMode.flat;
    if (mode != DepthMode.auto) return mode;
    final desktop = !(Platform.isAndroid || Platform.isIOS);
    return desktop ? DepthMode.d3 : DepthMode.d25;
  }

  /// For the app-wide theme, where no screen context exists yet.
  DepthMode appMode({required bool reduceMotion, required bool highContrast}) {
    if (reduceMotion || highContrast) return DepthMode.flat;
    if (mode != DepthMode.auto) return mode;
    return (Platform.isAndroid || Platform.isIOS) ? DepthMode.d25 : DepthMode.d3;
  }

  ThemeData theme(ThemeData base, BuildContext? c, DepthMode m) {
    if (m == DepthMode.flat) return base.copyWith(cardTheme: base.cardTheme.copyWith(elevation: 0, shape: RoundedRectangleBorder(side: BorderSide(color: base.colorScheme.outlineVariant), borderRadius: BorderRadius.circular(12))),
      pageTransitionsTheme: const PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: FadeForwardsPageTransitionsBuilder()}));
    if (m == DepthMode.d25) return base.copyWith(cardTheme: base.cardTheme.copyWith(elevation: 3, shadowColor: Colors.black54, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(14))));
    return base.copyWith(cardTheme: base.cardTheme.copyWith(elevation: 6, shadowColor: Colors.black87, shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(16))),
      pageTransitionsTheme: PageTransitionsTheme(builders: {for (final p in TargetPlatform.values) p: const _DepthPageTransition()}));
  }
}

/// A card that is 3D (tilts to the pointer), 2.5D (layered shadow) or flat, by the effective mode.
class DepthCard extends StatefulWidget {
  const DepthCard({super.key, required this.child, this.color, this.margin});
  final Widget child; final Color? color; final EdgeInsetsGeometry? margin;
  @override State<DepthCard> createState() => _DepthCardState();
}
class _DepthCardState extends State<DepthCard> {
  Offset tilt = Offset.zero;               // -1..1 in each axis
  @override
  Widget build(BuildContext c) {
    final m = Depth.instance.effective(c); final cs = Theme.of(c).colorScheme;
    final card = Card(color: widget.color, margin: widget.margin, child: widget.child);
    if (m == DepthMode.flat) return card;
    if (m == DepthMode.d25) {
      return Container(margin: widget.margin ?? const EdgeInsets.all(4), decoration: BoxDecoration(borderRadius: BorderRadius.circular(14), boxShadow: [
        BoxShadow(color: cs.shadow.withValues(alpha: 0.18), offset: const Offset(6, 8), blurRadius: 0), BoxShadow(color: cs.shadow.withValues(alpha: 0.10), offset: const Offset(2, 3), blurRadius: 6)]),
        child: Card(color: widget.color, margin: EdgeInsets.zero, elevation: 0, child: widget.child));
    }
    return MouseRegion(
      onHover: (e) { final b = c.size; if (b == null || b.isEmpty) return; setState(() => tilt = Offset((e.localPosition.dx / b.width) * 2 - 1, (e.localPosition.dy / b.height) * 2 - 1)); },
      onExit: (_) => setState(() => tilt = Offset.zero),
      child: TweenAnimationBuilder<Offset>(tween: Tween(end: tilt), duration: const Duration(milliseconds: 160), builder: (c, t, child) {
        final mtx = Matrix4.identity()..setEntry(3, 2, 0.0012)..rotateX(-t.dy * 0.12)..rotateY(t.dx * 0.12);
        return Transform(alignment: Alignment.center, transform: mtx, child: DecoratedBox(
          decoration: BoxDecoration(borderRadius: BorderRadius.circular(16), boxShadow: [BoxShadow(color: cs.shadow.withValues(alpha: 0.25), blurRadius: 24, offset: Offset(-t.dx * 10, 12 - t.dy * 8))]),
          child: Stack(children: [child!, Positioned.fill(child: IgnorePointer(child: DecoratedBox(decoration: BoxDecoration(borderRadius: BorderRadius.circular(16),
            gradient: RadialGradient(center: Alignment(t.dx, t.dy), radius: 1.2, colors: [Colors.white.withValues(alpha: 0.10), Colors.transparent])))))])));
      }, child: Card(color: widget.color, margin: widget.margin, elevation: 0, child: widget.child)));
  }
}

/// Pages turn in depth (3D mode only).
class _DepthPageTransition extends PageTransitionsBuilder {
  const _DepthPageTransition();
  @override
  Widget buildTransitions<T>(PageRoute<T> route, BuildContext context, Animation<double> a, Animation<double> b, Widget child) =>
    AnimatedBuilder(animation: a, child: child, builder: (_, child) {
      final v = Curves.easeOutCubic.transform(a.value);
      return Opacity(opacity: v, child: Transform(alignment: Alignment.centerLeft,
        transform: Matrix4.identity()..setEntry(3, 2, 0.0015)..rotateY((1 - v) * -math.pi / 9)..multiply(Matrix4.translationValues(0, 0, (1 - v) * -80)), child: child));
    });
}

/// Settings tile.
class DepthSetting extends StatelessWidget {
  const DepthSetting({super.key});
  @override
  Widget build(BuildContext c) => ListenableBuilder(listenable: Depth.instance, builder: (c, _) => ListTile(leading: const Icon(Icons.view_in_ar_outlined), title: const Text('Look'),
    subtitle: Text('Now: ${{DepthMode.d3: '3D', DepthMode.d25: '2.5D', DepthMode.flat: 'Flat', DepthMode.auto: ''}[Depth.instance.effective(c)]}. Flat is used automatically with reduced motion or high contrast.'),
    trailing: DropdownButton<DepthMode>(value: Depth.instance.mode, underline: const SizedBox(), onChanged: (v) => Depth.instance.set(v!), items: const [
      DropdownMenuItem(value: DepthMode.auto, child: Text('Automatic')), DropdownMenuItem(value: DepthMode.d3, child: Text('3D')),
      DropdownMenuItem(value: DepthMode.d25, child: Text('2.5D')), DropdownMenuItem(value: DepthMode.flat, child: Text('Flat'))])));
}
