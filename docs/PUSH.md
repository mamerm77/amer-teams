# Push notifications (incoming calls and messages)

Path: Synapse → Sygnal → APNs (iPhone) / FCM (Android) → app wakes, syncs, decrypts locally.
Payload is `event_id_only`: Apple and Google never see message text or call keys.

1. **Firebase** (console.firebase.google.com): create project, add Android app `com.amerteams.app` and iOS app `com.amerteams.app`.
   - Download `google-services.json` → `app/android/app/`, `GoogleService-Info.plist` → `app/ios/Runner/`.
   - Project settings → Service accounts → Generate key → save as `deploy/push-secrets/fcm-service-account.json`.
2. **Apple** (developer.apple.com → Keys): create an APNs key → save as `deploy/push-secrets/AuthKey.p8`; put Key ID and Team ID in `deploy/sygnal.yaml`.
3. In Xcode enable Push Notifications + Background Modes (Remote notifications, Voice over IP).
4. `docker compose up -d sygnal caddy`, then sign in again on the phone; the app registers its pusher automatically.

Verify: `curl -H "Authorization: Bearer <token>" https://<domain>/_matrix/client/v3/pushers` lists the device.
