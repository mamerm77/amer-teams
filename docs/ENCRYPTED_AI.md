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

## What is not built (open)
- **No on-device model** is installed yet. Choosing one (a small quantised model for translation and short
  summaries, through a native runtime on iOS, Android and Windows) is the next step.
- **No enclave.** The spec's design (confidential VMs, AMD SEV-SNP or Intel TDX, in a UAE region, running a
  pinned inference proxy; HPKE to the enclave key; attestation checked against a pinned measurement and under
  24 h old; no content logs) needs confidential-computing hardware. Neither this build environment nor CI has
  it, so none of it can be honestly tested here. Until it exists, Confidential chats get no AI, and General chats
  get AI only where the organisation allows the plain path.
- **Default.** `ai_plain_server` is *on*, so today's AI features keep working. Switching it off for every tenant
  is one row (`*`, `ai_plain_server`, off).

## Tests
- `app/test/ai_router_test.dart`: the routing table row by row, including the spec's acceptance tests:
  - Restricted content never leaves the device (refused without a model);
  - when the enclave is down, no plain request is made unless the policy allows it.
- `services/orchestrator/tests/test_flags.py`: with the policy off, encrypted-chat AI requests and Catch me up
  are refused, plain prompts still work, and attestation answers 503.
