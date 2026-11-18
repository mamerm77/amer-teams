import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:matrix/matrix.dart';

/// Registers this device with Synapse so new messages and call invites wake the app.
/// Push payloads carry only event/room IDs (Sygnal "event_id_only"), never message content,
/// so encryption is preserved; the app fetches and decrypts on wake.
class PushService {
  static const appId = 'com.amerteams.app';
  static Future<void> register(Client client, {required Uri gateway}) async {
    if (!(Platform.isAndroid || Platform.isIOS)) return;      // desktop: app keeps its own sync open
    try { await Firebase.initializeApp(); } catch (_) { return; }  // Firebase not configured yet
    final fm = FirebaseMessaging.instance;
    await fm.requestPermission(alert: true, sound: true, criticalAlert: false);
    final token = Platform.isIOS ? await fm.getAPNSToken() : await fm.getToken();
    if (token == null) return;
    await client.postPusher(Pusher(
      pushkey: token, kind: 'http',
      appId: Platform.isIOS ? '$appId.ios' : '$appId.android',
      appDisplayName: 'Amer Teams', deviceDisplayName: Platform.localHostname, lang: 'en',
      data: PusherData(url: gateway.replace(path: '/_matrix/push/v1/notify'), format: 'event_id_only'),
    ), append: false);
  }
}
