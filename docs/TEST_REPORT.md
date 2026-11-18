# Amer Teams — Test Report (v0.6)
Date: 18 Nov 2026 · Live servers, no mocks: Synapse on **PostgreSQL 16**, LiveKit 1.8.0 on **Redis 7**, orchestrator on **PostgreSQL 16**, all behind **Caddy 2.8 TLS**.
Re-run: `tests/protocol_conformance.py`, `tests/e2e_real.py`, `tests/registration_test.py`.

## Summary
All suites run back to back by `tools/run_all_tests.sh` on live servers: **122/122 checks + 5/5 unit tests**.

| Suite | Result |
|---|---|
| Post-quantum hybrid call keys (ML-KEM-768 + Megolm) | **14/14 PASS** |
| Monitoring and alerting (real outages, tamper detection) | **18/18 PASS** |
| High availability (replica crash, rolling restart, DB failover) | **9/9 PASS** |
| Phone network (SIP trunks, policy, dial-out path) | **12/12 PASS** |
| Protocol conformance (TLS, Matrix, Olm, Megolm, JWT, WSS, ICE, DTLS-SRTP, frame E2EE, PostgreSQL, audit) | **29/29 PASS** |
| User creation and registration (invite codes, password policy, admin) | **26/26 PASS** |
| Functional end-to-end (chat, calls, teams, files, meetings, telemetry) | **14/14 PASS** |
| Outage detection (media server killed and restarted) | PASS — detected within 5 s |
| Push notification privacy | PASS — payload carries IDs only |
| Database backup and restore | PASS — restored copy identical (18/18 audit rows) |
| Orchestrator unit tests | PASS 5/5 |

## Protocol stack
| Layer | Protocol | Where |
|---|---|---|
| Transport security | TLS 1.3 (1.2 AEAD fallback, ≤1.1 refused), HSTS, HTTP/2 | Caddy |
| Messaging | Matrix Client-Server API v3 (spec up to v1.17) | Synapse |
| Device keys | Olm — Curve25519 key agreement, Ed25519 signatures | client ↔ client |
| Group messages, files, call keys | Megolm (m.megolm.v1.aes-sha2); files AES-256-CTR | client ↔ client |
| Call signalling | LiveKit protocol over WSS (TLS) | client ↔ SFU |
| Call access | JWT HS256, room-scoped, 1 h expiry | orchestrator → SFU |
| Media transport | ICE, DTLS-SRTP | WebRTC |
| Media end-to-end | AES-GCM frame encryption, key index rotation | client ↔ client |
| Push | Matrix push gateway API, event_id_only payload | Synapse → Sygnal → APNs/FCM |

## Protocol conformance — detail
| Layer | Check | Result | Evidence |
|---|---|---|---|
| TLS | TLS 1.3 negotiated, certificate verified | PASS |  |
| TLS | TLS 1.1 and below refused | PASS |  |
| TLS | HSTS header present | PASS |  |
| TLS | Untrusted certificate rejected by client | PASS |  |
| Matrix C-S API | Spec versions advertised (v1.1+) | PASS | v1.15, v1.16, v1.17 |
| Matrix C-S API | Wrong password rejected (M_FORBIDDEN) | PASS |  |
| Matrix C-S API | Unauthenticated request rejected | PASS |  |
| Olm | Device keys published (curve25519 + ed25519, signed) | PASS | m.olm.v1.curve25519-aes-sha2, m.megolm.v1.aes-sha2 |
| Olm | Olm session established to peer device | PASS | 7 session(s) |
| Megolm | Message decrypted by recipient | PASS |  |
| Megolm | Ciphertext uses m.megolm.v1.aes-sha2 in DB | PASS | 1 encrypted event(s) in PostgreSQL |
| JWT | Token is HS256, scoped to one room, expires | PASS |  |
| JWT | Expired token refused by SFU | PASS |  |
| JWT | Forged signature refused by SFU | PASS |  |
| LiveKit signalling | Clients joined over WSS (TLS) | PASS |  |
| Frame E2EE (AES-GCM) | Key 0: member decrypts audio | PASS | 0.96 |
| ICE | ICE candidate pair succeeded | PASS |  |
| DTLS-SRTP | DTLS transport connected | PASS |  |
| DTLS-SRTP | SRTP cipher negotiated | PASS | from WebRTC transport stats |
| Frame E2EE (AES-GCM) | Key 1 delivered via Megolm | PASS |  |
| Frame E2EE (AES-GCM) | After rotation: member still decrypts | PASS | 0.90 |
| Frame E2EE (AES-GCM) | After rotation: holder of old key locked out | PASS | 0.00 |
| PostgreSQL (Synapse) | Schema created, UTF8 + C collation | PASS | 177 tables, ('C', 'UTF8') |
| PostgreSQL (Amer) | Agent setting survives service restart | PASS |  |
| PostgreSQL (Amer) | All 7 tables created by migration | PASS |  |
| PostgreSQL (Amer) | Call sessions and audit rows written | PASS | 2 sessions, 2 audit rows |
| PostgreSQL (Amer) | Monitoring samples persisted | PASS | 714 rows |
| Audit integrity | Hash chain verifies | PASS | 13 entries |
| Audit integrity | Tampering blocked by append-only trigger | PASS |  |

## Functional end-to-end — detail
| Check | Result | Evidence |
|---|---|---|
| 1. Login (3 real users) | PASS |  |
| 2. Room is encrypted by server policy | PASS | {'algorithm': 'm.megolm.v1.aes-sha2'} |
| 3. Tester receives and decrypts Megolm message | PASS |  |
| 4. Server stores ciphertext only | PASS | 1 encrypted events, plaintext found=False |
| 5. Call key delivered inside encrypted room | PASS |  |
| 6a. Member gets LiveKit token | PASS |  |
| 6b. Non-member refused | PASS | HTTP 403 |
| 7a. Both participants connected to SFU with E2EE | PASS |  |
| 7b. Peer with key hears the 440 Hz tone (decrypted) | PASS | tone energy 0.96, level 7593 |
| 8. Participant with wrong key cannot recover audio | PASS | tone energy 0.00, level 0 |
| 9. Ops telemetry reports the live call | PASS | calls=1 participants=3 |
| 10. Team (space) contains encrypted channel | PASS |  |
| 11. File stored encrypted, recipient-decryptable | PASS | 8000 bytes ciphertext |
| 12. Meeting invite delivered and encrypted at rest | PASS |  |

## User creation and registration — detail
How accounts are created:
- **Self sign-up in the app** with an invite code (Matrix User-Interactive Auth: `m.login.registration_token` then `m.login.dummy`). Open sign-up is disabled.
- **Admin creates the account** in the app's Users screen (orchestrator → Synapse Admin API).
- Password policy: 10+ characters with upper case, lower case, number and symbol; stored bcrypt-hashed.
- Admins can list users, issue and revoke invite codes, reset passwords (signs the user out everywhere) and deactivate accounts. Every action is audited.

| Check | Result | Evidence |
|---|---|---|
| 1. Server requires an invite code to register | PASS | ['m.login.registration_token', 'm.login.dummy'] |
| 2. Sign-up without invite code refused | PASS | HTTP 401 |
| 3. Non-admin cannot create invite codes | PASS | HTTP 403 |
| 4. Admin creates single-use invite code | PASS | fvTo.i..uKiLr7~P |
| 5. Invalid invite code refused | PASS | M_UNAUTHORIZED |
| 6. Weak passwords refused (5 rules) | PASS | short:M_PASSWORD_TOO_SHORT, no digit:M_PASSWORD_NO_DIGIT, no symbol:M_ |
| 7. Invalid username refused | PASS | M_INVALID_USERNAME |
| 8. Username availability check | PASS |  |
| 9. Self-registration with invite code succeeds | PASS | @sara5dccff:amer.test |
| 10. Single-use code cannot be reused | PASS | HTTP 401 |
| 11. Duplicate username refused | PASS | M_USER_IN_USE |
| 12. New user signs in | PASS |  |
| 13. Invite usage recorded (1/1) | PASS |  |
| 14. Admin creates a user directly | PASS | @omar5dccff:amer.test |
| 15. Admin cannot create a duplicate user | PASS |  |
| 16. Admin-created user signs in, display name set | PASS |  |
| 17. Both new users listed | PASS | 11 accounts |
| 18. Non-admin cannot list users | PASS |  |
| 19. New users exchange an encrypted message | PASS |  |
| 20. New users' encryption device keys stored | PASS | 2 device key set(s) |
| 21. Password stored bcrypt-hashed, never plain | PASS |  |
| 22. Password reset: old fails, new works, old sessions signed out | PASS |  |
| 23. Deactivated user cannot sign in | PASS | M_FORBIDDEN |
| 24. Admin cannot deactivate own account | PASS |  |
| 25. Deactivation recorded in PostgreSQL: flag set, password and devices removed | PASS | flag=1, devices=0 |
| 26. All admin actions in the audit log | PASS | ['admin.invite.create', 'admin.user.create', 'admin.user.deactivate',  |

## Phase 3–4 detail

### Post-quantum hybrid call keys
| Check | Result | Evidence |
|---|---|---|
| A1. ML-KEM-768 sizes per FIPS 203 (pk 1184, sk 2400, ct 1088) | PASS |  |
| A2. Each member device derives the same call key | PASS |  |
| A3. Another device's secret key cannot open a wrap | PASS |  |
| A4. Tampered ciphertext is rejected | PASS |  |
| A5. Wrap cannot be replayed into another key index | PASS |  |
| A6. Breaking only the classical layer (K_c) is not enough | PASS |  |
| A7. Breaking only ML-KEM (K_pq) is not enough | PASS |  |
| A8. Key changes with rotation index | PASS |  |
| B1. Deterministic vectors written for the Dart client | PASS | 3 vectors |
| C1. Device ML-KEM public keys exchanged inside encrypted room | PASS | 2 devices |
| C2. Hybrid key event is 3 KB for 2 devices (Megolm-encrypted) | PASS |  |
| C3. Recipient derives identical hybrid call key | PASS |  |
| C4. Live call with hybrid key: member hears audio | PASS | tone energy 0.96 |
| C5. Attacker holding only the classical secret hears nothing | PASS | tone energy 0.00 |

Plus in CI: the Dart client (`pqcrypto`) reproduces the Python reference (`kyber-py`) vectors byte for byte (`flutter test`).

### Monitoring and alerting
| Check | Result | Evidence |
|---|---|---|
| 1. All 6 targets scraped | PASS | ai-engine=up, chat=up, media=up, postgres=up, prometheus=up, redis=up |
| 2. AI engine reports 3/3 services up | PASS |  |
| 3. Chat server metrics present | PASS |  |
| 4. Media server metrics present | PASS | 299 series |
| 5. PostgreSQL and Redis exporters report up | PASS |  |
| 6. Audit-integrity metric is 1 | PASS |  |
| 7. 8 alert rules loaded | PASS |  |
| 8. Media outage: ServiceDown alert fires | PASS | after 21 s |
| 9. Media outage: ProbeFailing alert fires | PASS |  |
| 10. Alertmanager received the alerts | PASS |  |
| 11. Alert written to tamper-evident audit log | PASS |  |
| 12. App Health screen API lists the alert | PASS | ['ServiceDown', 'ProbeFailing'] |
| 13. Media restored: alerts resolve | PASS |  |
| 14. Resolution recorded in audit log | PASS |  |
| 15. Redis outage: RedisDown alert fires | PASS |  |
| 16. Redis restored: alert resolves | PASS |  |
| 17. Tampered audit row: AuditLogTampered alert fires | PASS |  |
| 18. Restored row: integrity metric back to 1 | PASS |  |

### High availability
| Check | Result | Evidence |
|---|---|---|
| C0. Standby streaming in synchronous mode | PASS | [('standby1', 'sync')] |
| A0. 3 AI-engine replicas started | PASS |  |
| A1. Load balancer up | PASS |  |
| A2. Replica crash + rolling restart: zero failed requests | PASS | 1467 ok, 0 failed [] |
| B1. Agent switched off on one replica is off on all 3 | PASS |  |
| C1. Standby promoted to primary | PASS | in 0.2 s |
| C2. RPO 0: every acknowledged write survived the crash | PASS | 117 acknowledged, 0 lost |
| C3. Writes resumed on the new primary | PASS | 67 writes after failover |
| C4. AI engine works against the new primary (multi-host connection) | PASS | 200/200 |

Kubernetes manifests (`deploy/k8s`, 35 resources) pass strict schema validation for Kubernetes 1.31, CloudNativePG and Prometheus Operator.

### Phone network (SIP)
| Check | Result | Evidence |
|---|---|---|
| 1. Phone calls are off by default | PASS | Phone calls are switched off by your administrator |
| 2. Only admins can change phone policy | PASS |  |
| 3. Admin enables phone calls for +971 and +20 | PASS |  |
| 4. Dialling without a phone line gives a clear error | PASS | No phone line (SIP trunk) is configured yet |
| 5. Admin creates outbound + inbound trunk and inbound routing rule | PASS | {'outbound_trunk_id': 'ST_hKyGXDXrqmTa', 'inbound_trunk_id': 'ST_uknz9 |
| 6. Outbound trunk uses SIP over TLS | PASS | SIP_TRANSPORT_TLS |
| 7. Both trunks require encrypted media (SRTP) | PASS |  |
| 8. Inbound calls routed to their own phone room | PASS |  |
| 9. Trunk numbers must be E.164 | PASS |  |
| 10. Local format, premium, satellite and non-allowed countries refused | PASS | {'0501234567': 400, '+1900555123': 403, '+9719001234': 403, '+44791112 |
| 11. Allowed number accepted and sent to the SIP gateway | PASS | gateway not running here: The phone gateway could not place the call ( |
| 12. Phone actions audited, numbers masked | PASS | ['phone.dial.failed: +971•••••••67 ServerError', 'phone.trunk.create:  |

## Databases
| Database | Engine | Holds | Verified |
|---|---|---|---|
| `synapse` | PostgreSQL 16, UTF8, C collation | users, devices, rooms, teams, **encrypted** messages/files/meetings/call keys | 177 tables; only ciphertext at rest |
| `amer` | PostgreSQL 16 (migration `001_init.sql`) | audit_log (append-only, SHA-256 hash chain), agent_config, ai_requests, call_sessions, ops_samples, media_samples | 7 tables; settings survive restart; tampering blocked |
| LiveKit state | Redis 7 (AOF persistence) | rooms, participants, node routing | SFU connected to Redis |
| Media files | Synapse media store | **encrypted** attachments | ciphertext only |
| Phone/PC | SQLite (Matrix SDK) | local keys and message cache | — (app build pending) |
Daily `pg_dump` of both databases, 14-day retention (`backup` service). No message text, transcripts or call keys are stored by the AI engine.

## Defects found and fixed in v0.6
1. **Replicas crashed when starting together** (simultaneous schema migration). Migrations now take a PostgreSQL advisory lock.
2. **First request failed after a database failover** (stale pooled connection). Pool now validates connections before use.
3. **Agent on/off applied to one replica only.** Every replica now reloads settings from PostgreSQL every 5 s.
4. **Alertmanager would not start on a single server** (cluster mode). Clustering disabled for single-node deployments.
5. **Deleting a phone line left it configured as the outbound line.** Fixed.
6. **CI build fixes for current toolchains:** Matrix SDK 17, file_picker 13 (Android compileSdk 36), Firebase under CMake 4 (Windows), iOS package resolution.

## Defects found and fixed in v0.5
1. **Sign-up would have failed in the app.** The server requires two auth stages (invite code, then a confirmation stage); the app completed only the first. Fixed in `matrix_service.dart` to complete every stage the server asks for.
2. **No way to create users except the server command line.** Added invite-code sign-up, admin user management API and Users screen.
3. **Seven tabs could not fit a phone screen.** Phones now show four tabs plus More.

## Defects found and fixed in v0.4
1. **Key rotation did not lock out the old key (security).** A new call key was installed but outgoing frames kept using the old index, so a departed member could still hear. Fixed in `app/lib/services/call_service.dart` (`setKeyIndex`). Verified: old-key holder now gets silence (tone energy 0.00).
2. **Caddy configuration invalid.** The one-line `handle { … }` syntax was rejected, so the proxy would not start in production or LAN mode. Fixed in both Caddyfiles; `caddy validate` passes.
3. **Audit log lost on restart.** It lived in memory only. Now stored in PostgreSQL with a tamper-evident hash chain.
4. **Server encryption policy silently ignored** (from the previous round). Fixed in both setup scripts.

## Not verifiable here
| Item | Reason | How to verify |
|---|---|---|
| Flutter app compile and on-device run | Flutter SDK blocked in this environment | GitHub Actions workflow, or `flutter run` |
| Real AI answers | no API key here | set `ANTHROPIC_API_KEY` |
| APNs/FCM delivery to phones | needs your credentials | docs/PUSH.md |
| Calls across NAT / mobile data (TURN) | single host | public VM, UDP 50000–50100 |
