# Amer Teams — Test Report (v0.5)
Date: 18 Nov 2026 · Live servers, no mocks: Synapse on **PostgreSQL 16**, LiveKit 1.8.0 on **Redis 7**, orchestrator on **PostgreSQL 16**, all behind **Caddy 2.8 TLS**.
Re-run: `tests/protocol_conformance.py`, `tests/e2e_real.py`, `tests/registration_test.py`.

## Summary
| Suite | Result |
|---|---|
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

## Databases
| Database | Engine | Holds | Verified |
|---|---|---|---|
| `synapse` | PostgreSQL 16, UTF8, C collation | users, devices, rooms, teams, **encrypted** messages/files/meetings/call keys | 177 tables; only ciphertext at rest |
| `amer` | PostgreSQL 16 (migration `001_init.sql`) | audit_log (append-only, SHA-256 hash chain), agent_config, ai_requests, call_sessions, ops_samples, media_samples | 7 tables; settings survive restart; tampering blocked |
| LiveKit state | Redis 7 (AOF persistence) | rooms, participants, node routing | SFU connected to Redis |
| Media files | Synapse media store | **encrypted** attachments | ciphertext only |
| Phone/PC | SQLite (Matrix SDK) | local keys and message cache | — (app build pending) |
Daily `pg_dump` of both databases, 14-day retention (`backup` service). No message text, transcripts or call keys are stored by the AI engine.

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
