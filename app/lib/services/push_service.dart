import 'dart:io';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_messaging/firebase_messaging.dart';
import 'package:matrix/matrix.dart';

/// Registers this device with Synapse so new messages and call invites wake the app.
/// Synapse sends each push to our own server's quiet-hours filter (docs/NOTIFICATIONS.md), which forwards only
/// the event and room ids to Sygnal and on to Apple or Google: never the sender or content. The app fetches and
/// decrypts the message on wake. The push key is also registered with the filter so it knows whose device it is.
class PushService {
  static const appId = 'com.amerteams.app';
  static Future<void> register(Client client, {required Uri gateway, Future<void> Function(String pushkey)? registerKey}) async {
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
      data: PusherData(url: gateway.replace(path: '/_matrix/push/v1/notify')),     // our filter reduces it to ids before it leaves
    ), append: false);
    try { await registerKey?.call(token); } catch (_) {}
  }
}
