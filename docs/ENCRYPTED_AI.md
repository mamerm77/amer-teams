# Encrypted AI

Phase 3, creative feature 3, and the foundation behind every AI feature (docs/PHASE3_REQUIREMENTS.docx).

## What is built
- **The routing table, decided on the device for every AI request** (`app/lib/services/ai_router.dart`).

  | Content | Route |
  |---|---|
  | Restricted chat | On this device only; refused if there is no on-device model |
  | Small task (translate, classify, short summary) | On this device if a model is installed and the battery is above 20% |
  | Larger task, Confidential or below | The enclave, after its attestation verifies |
  | Confidential, no enclave | **Refused**: never the plain server |
  | General, no enclave | The organisation's AI service **only if** the policy `ai_plain_server` allows it; otherwise refused |
  | Not end-to-end encrypted | The normal AI service |

- **Every answer says where it ran**: "Ran on this device", "Ran in the attested enclave", or "Ran on your
  organisation's AI service (not end-to-end encrypted)". A refusal says why. This covers translate, suggest a
  reply, `/ask`, Summarise, Catch me up, Ask Amer in meetings, and minutes with their follow-up.
- **The server enforces the policy too**, so a modified app cannot bypass it. With `ai_plain_server` off for a
  tenant (Users → Feature flags):
  - `/v1/ai/ask` refuses requests marked as encrypted-chat content;
  - Catch me up and the meeting agent answer 403;
  - the Amer chat bot declines.

  Confidential and Restricted are blocked by Guardian as before.
- **The attestation endpoint** `GET /v1/ai/enclave/attestation` answers 503 "No attested enclave is deployed".
  The app treats that as *enclave unavailable* and never falls back silently.
- **Fixed while doing this:** *Summarise with Amer* and the meeting follow-up did not pass the chat's sensitivity
  label, so Guardian could not block them on Confidential chats. Both now pass it.

## The AI proxy (enclave software), built and running locally
`services/enclave/enclave.py` is a separate service (Docker Compose `enclave`; `ENCLAVE_URL` for the
orchestrator).
- **Keys.** An X25519 key pair is made at start and kept in memory only. `/attestation` gives the public key, the
  **measurement** (SHA-256 of `enclave.py`) and the attestation type.
- **The app encrypts each request to the proxy.** X25519 with a one-time key, HKDF-SHA256 (salt = both public
  keys) and AES-256-GCM. The orchestrator relays **ciphertext only** (`/v1/ai/enclave/infer`) and records only
  sizes and token counts. The answer comes back encrypted to the app's one-time key.
- **The proxy** applies Guardian's redaction (card numbers, IBANs, Emirates IDs), calls the model, and logs one
  line of sizes, tokens and time. No content.
- **The app checks the attestation before sending.**
  - The measurement must equal the one **pinned in this build**: CI computes the SHA-256 of `enclave.py` from git
    and passes it as `ENCLAVE_MEASUREMENT`. A changed proxy is refused.
  - On ordinary hardware the type is `none`. The app then uses the proxy only if the organisation allows it (flag
    `ai_unattested_enclave`, off by default) and labels answers "🔐 Ran in the AI proxy: encrypted past this
    server, not hardware-attested".
  - It is never used for Confidential or Restricted chats.
- **Checked:**
  - `services/enclave/test_enclave.py`: a real round trip, no content in the ciphertext or the logs, a tampered
    request refused, redaction applied.
  - **On the local stack**: through the real orchestrator, which relayed ciphertext only; its log contains
    neither the text nor the card number.

## What is not built (open)
- **No on-device model** is installed yet. Choosing one (a small quantised model for translation and short
  summaries, through a native runtime on iOS, Android and Windows) is the next step.
- **No hardware enclave.** The proxy above is the software that would run in it. The spec's design (confidential VMs, AMD SEV-SNP or Intel TDX, in a UAE region, running a
  pinned inference proxy; HPKE to the enclave key; attestation checked against a pinned measurement and under
  24 h old; no content logs) needs confidential-computing hardware. Neither this build environment nor CI has
  it, so hardware attestation cannot be honestly tested here; the app refuses hardware reports until it can verify them. Until it exists, Confidential chats get no AI, and General chats
  get AI only where the organisation allows the plain path.
- **Default.** `ai_plain_server` is *on*, so today's AI features keep working. Switching it off for every tenant
  is one row (`*`, `ai_plain_server`, off).

## Tests
- `app/test/ai_router_test.dart`: the routing table row by row, including the spec's acceptance tests:
  - Restricted content never leaves the device (refused without a model);
  - when the enclave is down, no plain request is made unless the policy allows it.
- `services/orchestrator/tests/test_flags.py`: with the policy off, encrypted-chat AI requests and Catch me up
  are refused, plain prompts still work, and attestation answers 503.
