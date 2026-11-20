import 'services/availability.dart';
import 'package:media_kit/media_kit.dart';
import 'ui/depth.dart';
import 'services/accessibility.dart';
import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'services/locale.dart';
import 'package:provider/provider.dart';
import 'services/matrix_service.dart';
import 'services/api_service.dart';
import 'services/call_manager.dart';
import 'services/app_lock.dart';
import 'screens/security_screen.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  MediaKit.ensureInitialized();                                  // Stream video playback
  final matrix = MatrixService();
  await matrix.init();
  await AppLocale.instance.load();
  await A11y.instance.load();
  await Depth.instance.load();
  runApp(MultiProvider(providers: [
    ChangeNotifierProvider.value(value: matrix),
    ProxyProvider<MatrixService, ApiService>(update: (_, m, __) => ApiService(m)),
    Provider<CallManager>(create: (_) => CallManager(matrix, navigatorKey, ApiService(matrix))..start(), dispose: (_, cm) => cm.dispose()),
  ], child: const AmerTeamsApp()));
}

class AmerTeamsApp extends StatelessWidget {
  const AmerTeamsApp({super.key});
  @override
  Widget build(BuildContext context) {
    final m = context.watch<MatrixService>();
    return ListenableBuilder(listenable: Listenable.merge([AppLocale.instance, A11y.instance, Depth.instance]), builder: (_, __) => MaterialApp(
      locale: AppLocale.instance.locale,
      supportedLocales: const [Locale('en'), Locale('ar')],
      localizationsDelegates: const [GlobalMaterialLocalizations.delegate, GlobalWidgetsLocalizations.delegate, GlobalCupertinoLocalizations.delegate],
      navigatorKey: navigatorKey,
      title: 'Amer Teams',
      debugShowCheckedModeBanner: false,
      theme: Depth.instance.theme(A11y.instance.theme(amerTheme(Brightness.light), Brightness.light), null, Depth.instance.appMode(reduceMotion: A11y.instance.reduceMotion, highContrast: A11y.instance.highContrast)),
      darkTheme: Depth.instance.theme(A11y.instance.theme(amerTheme(Brightness.dark), Brightness.dark), null, Depth.instance.appMode(reduceMotion: A11y.instance.reduceMotion, highContrast: A11y.instance.highContrast)),
      builder: (ctx, child) => PresenceActivity(child: A11y.instance.apply(ctx, LockGate(child: child!))),
      home: m.isLoggedIn ? const _VerificationListener(child: HomeScreen()) : const LoginScreen(),
    ));
  }
}

/// Pops up the emoji check when another device asks to verify.
class _VerificationListener extends StatefulWidget { const _VerificationListener({required this.child}); final Widget child; @override State<_VerificationListener> createState() => _VL(); }
class _VL extends State<_VerificationListener> {
  StreamSubscription? sub;
  @override void initState() { super.initState(); sub = context.read<MatrixService>().client.onKeyVerificationRequest.stream.listen((v) { if (mounted) showVerification(navigatorKey.currentContext ?? context, v); }); }
  @override void dispose() { sub?.cancel(); super.dispose(); }
  @override Widget build(BuildContext c) => widget.child;
}
