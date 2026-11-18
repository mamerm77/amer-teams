# Amer Teams — Encryption Model

End-to-end encryption (E2EE) is the base of the product, not an option. There is no "unencrypted call" code path.

## 1. Chat and files
- Matrix rooms are created with `m.room.encryption` (`m.megolm.v1.aes-sha2`) at creation time. The app refuses to create an unencrypted room.
- Device keys use Olm (Curve25519 / Ed25519) via the vodozemac library. Room messages use Megolm (AES-256-CBC + HMAC-SHA-256, ratcheting).
- Files are encrypted client-side (AES-256-CTR) before upload; the server stores ciphertext only.

## 2. Calls and meetings (WebRTC + LiveKit SFU)
| Layer | Mechanism |
|---|---|
| Transport (hop-by-hop) | DTLS-SRTP, TLS 1.3 for signalling |
| Media (end-to-end) | **SFrame-style frame encryption** via WebRTC Insertable Streams, AES-GCM-256, implemented by LiveKit E2EE |
| Key distribution | Per-call 256-bit key generated on the caller's device, sent **only inside the Megolm-encrypted Matrix room** as event `com.amerteams.call.key` |
| Rotation | New key whenever a participant leaves or every 10 min (`keyIndex` increments; clients ratchet) |

The SFU forwards encrypted frames it cannot decrypt. The orchestrator issues LiveKit join tokens but **never sees the media key**.

Call flow:
1. Caller's app generates `callId` and fresh key material (K_c, K_pq).
2. App posts `com.amerteams.call.key` (protocol amer-pq-hybrid-v1, section 2b) to the encrypted room → each member device receives it via Megolm and derives K with its ML-KEM key.
3. App asks orchestrator `POST /v1/calls/token` with its Matrix access token. Orchestrator verifies identity with Synapse `/whoami` and room membership, then signs a LiveKit JWT.
4. App joins LiveKit with `E2EEOptions(keyProvider)` set to `K`. A client without `K` sees black frames / silence.
5. UI shows a lock badge and a **safety code** (first 6 hex of SHA-256(K‖callId)) participants can compare verbally.

## 2b. Post-quantum hybrid call keys (amer-pq-hybrid-v1) — implemented
Protects call media against "harvest now, decrypt later" by a future quantum computer.
- Every device creates an **ML-KEM-768** (NIST FIPS 203) key pair and publishes the public key in the encrypted room (`com.amerteams.pq.device`; Megolm authenticates the sender).
- Each call key is `K = HKDF-SHA256(salt = call_id, ikm = K_c ‖ K_pq, info = "amer-call-key-v1|index")`.
  - `K_c` travels inside Megolm (classical Curve25519 / AES-256).
  - `K_pq` is wrapped separately for each member device: `(ct, ss) = ML-KEM-768.Encaps(pk)`, `okm = HKDF(ss, call|index|user|device)`, `w = K_pq ⊕ okm[0:32]`, `tag = HMAC-SHA256(okm[32:64], ct ‖ w)`.
- An attacker needs to break **both** Megolm/Curve25519 **and** ML-KEM-768. Same hybrid principle as Signal PQXDH and TLS X25519MLKEM768.
- Re-keyed when a device joins or leaves and every 10 minutes; the wrap is bound to call, index, user and device, so it cannot be replayed.
- Implementations: Dart `pqcrypto` 0.4.4 (app) and `kyber-py` (reference, `tools/pq_hybrid.py`). CI checks both produce byte-identical keys, ciphertexts and call keys from shared vectors.
- Size: about 1.5 KB per device per key event; fits ~40 devices in one Matrix event. Larger meetings: MLS (below).
- Limits: chat messages themselves are still classical Megolm until the Matrix ecosystem ships PQ Olm; the device ML-KEM secret key is stored in the app's private storage (move to the OS keychain/keystore before production).

## 3. AI under E2EE (Phase 2)
The server cannot hear an encrypted call, so the AI cannot either — by design.
- **Live captions & translation** run on-device (platform speech recognition). Text never leaves the device unless the user enables Amer.
- **Minutes / summaries**: the user explicitly invites Amer. The client then sends the locally produced transcript (TLS) to the orchestrator for that one request. A banner tells all participants "Amer is taking notes". Transcripts are not stored server-side.
- Guardian agent blocks any agent tool call that would export content marked Confidential.

## 4. Roadmap to carrier grade
- MLS (RFC 9420) group key agreement for meetings > 50 participants (replaces key-in-room fan-out).
- HSM-backed signing keys for the token service; key-transparency log for device keys.
- Independent cryptographic audit before production.
