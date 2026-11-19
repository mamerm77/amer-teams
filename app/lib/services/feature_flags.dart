import 'package:flutter/foundation.dart';
import 'api_service.dart';

/// Feature flags for this user (docs/FEATURE_FLAGS.md). Until they load, features show (the server still
/// refuses a switched-off feature's API, so a stale screen cannot use it).
class Flags extends ChangeNotifier {
  Flags._();
  static final instance = Flags._();
  Map<String, bool> _f = {};
  bool on(String feature) => _f[feature] ?? true;
  Future<void> load(ApiService api) async {
    try { _f = (await api.flags()).map((k, v) => MapEntry(k, v == true)); notifyListeners(); } catch (_) {}
  }
}
