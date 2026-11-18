import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'services/matrix_service.dart';
import 'services/api_service.dart';
import 'services/call_manager.dart';
import 'screens/login_screen.dart';
import 'screens/home_screen.dart';
import 'theme.dart';

final navigatorKey = GlobalKey<NavigatorState>();

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  final matrix = MatrixService();
  await matrix.init();
  runApp(MultiProvider(providers: [
    ChangeNotifierProvider.value(value: matrix),
    ProxyProvider<MatrixService, ApiService>(update: (_, m, __) => ApiService(m)),
    Provider<CallManager>(create: (_) => CallManager(matrix, navigatorKey)..start(), dispose: (_, cm) => cm.dispose()),
  ], child: const AmerTeamsApp()));
}

class AmerTeamsApp extends StatelessWidget {
  const AmerTeamsApp({super.key});
  @override
  Widget build(BuildContext context) {
    final m = context.watch<MatrixService>();
    return MaterialApp(
      navigatorKey: navigatorKey,
      title: 'Amer Teams',
      debugShowCheckedModeBanner: false,
      theme: amerTheme(Brightness.light),
      darkTheme: amerTheme(Brightness.dark),
      home: m.isLoggedIn ? const HomeScreen() : const LoginScreen(),
    );
  }
}
