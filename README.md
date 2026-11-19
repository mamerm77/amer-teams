# Amer Teams — Phase 1 + 2

Teams-style collaboration where **end-to-end encryption is the foundation** and an **AI agent engine** powers summaries, translation, minutes and control.

| Part | Path | Tech |
|---|---|---|
| Apps (iOS, Android, Windows, macOS, Linux) | `app/` | Flutter · Matrix SDK (Olm/Megolm) · LiveKit E2EE |
| Chat server | `deploy/` | Synapse (Matrix), encryption forced on every room |
| Call/meeting media relay | `deploy/` | LiveKit SFU — forwards encrypted frames only |
| AI engine + call token service | `services/orchestrator/` | FastAPI · Claude API · Guardian policy · Prometheus metrics |

Encryption design: see **docs/SECURITY.md**.

## Verified
See **docs/TEST_REPORT.md** — 29/29 protocol, 26/26 registration and 14/14 functional checks against live servers on PostgreSQL, Redis and TLS.

## Features
| Area | What you can do |
|---|---|
| Calls | Voice or video call from any chat or from **Calls → New call**; incoming-call ringing with Accept / Decline; call history with missed calls and redial |
| Meetings | **Meet now** with a 9-digit meeting ID; **Join with ID** through a waiting room the host controls (Admit / Decline); **Schedule** with date, time, duration and invitees; meetings appear in Calendar with a Join button |
| In a call | Grid or speaker view, active-speaker highlight, participant list, meeting chat, raise hand, emoji reactions, screen share, front/back camera, mute, on-device captions, Amer minutes, safety code |
| Chat | People search (organisation directory), 1:1 and group chats, replies, reactions, edit, delete for everyone, typing indicator, read receipts (✓✓), photo previews, files, voice messages, polls, message search, pinned chats, status message and online presence |
| Teams | Teams with channels |
| Phone | Calls to ordinary phone numbers through a company SIP trunk (admin enabled) |
| AI | Amer co-pilot, thread summaries, translation, meeting minutes, scheduling |
| Agent Ops | A team of AI agents (analyst, architect, developer, tester, reviewer, documenter) delivers a project while the **Agent Ops** tab shows each agent's real status live — see docs/AGENT_OPS.md |
| Admin | Invite codes, create / reset / deactivate users, agent control, health and alerts |

Everything except phone-network calls is end-to-end encrypted; call keys are post-quantum hybrid (ML-KEM-768).

## What works in this release
- Encrypted 1:1 and group chat, file-ready, unencrypted rooms refused
- Encrypted video/voice calls and meetings: per-call AES-GCM-256 key, shared only through the encrypted room, rotated on leave and every 10 min, **safety code** to verify
- Screen share, mute, camera
- On-device live captions (speech never leaves the phone)
- Amer co-pilot (real LLM), thread summaries, translation, opt-in meeting minutes posted back into the encrypted room
- Control centre: agents on/off, latency, call counts, audit log
- Account sign-up with invite codes, password policy, admin user management (create, reset password, deactivate)
- Teams (Matrix spaces) with encrypted channels
- Encrypted file sharing (AES-256-CTR, decrypted on the device)
- Calendar: meetings are encrypted events; Scheduler agent turns plain language into a meeting
- Health screen: live service probes, latency, availability, active calls (real telemetry, no simulation)
- Push notifications via Sygnal (APNs/FCM), content-free payloads — see docs/PUSH.md
- GitHub Actions builds Android, Windows and Linux apps
- `/metrics` endpoint for Prometheus

## Windows 11 installer
`AmerTeams-Setup-<version>.exe` installs the desktop app and, optionally, the local server. See **docs/WINDOWS.md**.

## 0. Quick real-call test on your Wi-Fi (no domain needed)
On a Windows PC with Docker Desktop:
```powershell
cd deploy
powershell -ExecutionPolicy Bypass -File .\setup-local.ps1
```
It detects your PC's Wi-Fi IP, starts every service and creates the administrator account.
Then run the app on two devices (e.g. Windows desktop + Android phone on the same Wi-Fi) and sign in with server `http://<PC-IP>`.
For Android test builds over HTTP add `android:usesCleartextTraffic="true"` to the `<application>` tag.

## 1. Run the server (one Linux VM, 4 vCPU / 8 GB)
Needs Docker, a domain pointing at the VM, and ports 80, 443, 7881/tcp, 50000-50100/udp open.
```bash
cd deploy
./setup.sh                 # first run creates .env
nano .env                  # set DOMAIN, SERVER_NAME, ANTHROPIC_API_KEY
./setup.sh                 # generates Synapse config + LiveKit keys
docker compose up -d
./create-admin.sh          # first administrator; connects the AI engine to it
```
Then sign in to the app as the admin, open **Users** and create invite codes. Colleagues choose **Create account** in the app and enter the code.
Caddy obtains TLS certificates automatically.

## 2. Build the apps
Install Flutter 3.24+ then:
```bash
cd app
flutter create . --org com.amerteams --platforms=ios,android,windows,macos,linux   # generates native folders
flutter pub get
flutter run                          # pick a device
```
Add these native permissions once (calls need camera/mic):
- **iOS** `ios/Runner/Info.plist`: `NSCameraUsageDescription`, `NSMicrophoneUsageDescription`, `NSSpeechRecognitionUsageDescription`; enable Background Modes → Audio, VoIP.
- **Android** `android/app/src/main/AndroidManifest.xml`: `CAMERA`, `RECORD_AUDIO`, `INTERNET`, `BLUETOOTH_CONNECT`, `FOREGROUND_SERVICE_MEDIA_PROJECTION`; set `minSdkVersion 24`.
- **macOS** entitlements: `com.apple.security.device.camera`, `com.apple.security.device.audio-input`, `com.apple.security.network.client`.

Release builds: `flutter build ipa`, `flutter build appbundle`, `flutter build windows|macos|linux`.
Store publishing needs an Apple Developer account and a Google Play Console account.

## 3. Test the backend
```bash
cd services/orchestrator && pip install -r requirements.txt && pytest -q
```

## Next (Phase 3–4)
Push notifications (APNs/FCM + VoIP push), MLS for large meetings, post-quantum key transport, Kubernetes multi-region HA, SIP/IMS gateway, Grafana dashboards fed into the Control centre, external crypto audit.
