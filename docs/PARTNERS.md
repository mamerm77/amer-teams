# Partner organisations: shared channels across servers

Phase 3, top five #4 (docs/PHASE3_REQUIREMENTS.docx). Benchmarks: Slack Connect, Teams shared channels.

## Using it
- **Administrator:** Users → **Partners** → *Add partner*: their server name and a note. That approves them on
  our side and shows a **one-time code** for their administrator.
  - If they run Amer Teams, their server confirms with the code (`POST /v1/federation/handshake`) and the
    connection becomes **active**.
  - If they run another Matrix server, choose *They confirmed: activate* once they have allowed your server.
  - *Suspend*, *Resume* and *Disconnect* at any time.
- **Anyone:** Chats → the handshake icon → **New shared channel**: name, the partner, the people to invite. The
  channel is end-to-end encrypted and invite-only.

## How it is enforced
- **States:** requested → approved_by_us → active (both sides) → suspended | disconnected
  (`services/orchestrator/app/partners.py`, migration 012). The one-time code is stored hashed and works once.
- **Synapse itself enforces the list.** The module `deploy/synapse-modules/amer_federation.py` (loaded by
  setup.sh and setup-local.ps1) reads the active partners from the orchestrator every 10 seconds, with a shared
  secret.
  - It refuses every event arriving from any other server: joins, invites and messages (third-party rules plus
    the spam checker, which runs on every federated event).
  - With the orchestrator unreachable it keeps the last known list; with no list, nothing from outside is
    accepted.
- **Local by default.** Rooms are created with `m.federate: false` unless they carry `com.amerteams.shared`. An
  ordinary chat cannot even invite a partner ("This room has been marked as unfederatable").
- **Disconnect.** The partner drops off the list. Their new messages are refused, and local members keep the
  channel and its history.
- **Data-loss prevention, on the device.** Before a message goes to a shared channel, the app checks it for card
  numbers (Luhn check), IBANs (mod-97 check) and Emirates ID numbers. If it finds one, the message is **not
  sent** and the text stays in the box. The server cannot do this check, because it only ever sees ciphertext;
  the check runs before encryption.

## Tested on two real servers (local)
`tests/federation_test.py` runs against two real Synapse servers on one machine: amer.test with the module and
the real orchestrator, and partner.test as plain Synapse. TLS goes through a proxy between them, and the clients
on each side are real end-to-end encrypted ones (matrix-nio). **8/8 passed**:
1. a server that is not an approved partner cannot join a shared channel ("This event is not allowed");
2. approval on our side alone is not enough;
3. the partner confirms with the one-time code and becomes active;
4. the partner's user then joins;
5. encrypted messages flow both ways;
6. an ordinary chat stays local;
7. after disconnecting, the partner's messages no longer arrive;
8. local members keep the channel and history.

Two things only the local test needs: `federation_verify_certificates: false` (the proxy uses a local CA) and
`ip_range_whitelist: ['127.0.0.0/8']` (both servers are on 127.0.0.1). A real deployment uses real certificates
and public addresses.

Also: `services/orchestrator/tests/test_partners.py` (state machine, one-time code, module secret, the module's
decisions with the orchestrator up and down) and `app/test/dlp_test.dart`.

## Gaps against the requirement (open)
- **The partner's own data-loss policy** (their side's DLP) applies only if they run Amer Teams.
- **Kubernetes:** the module must be mounted into the Synapse pods (a ConfigMap and PYTHONPATH). It is wired for
  Docker and Windows setups only so far.
- **Reaching a partner** needs federation on port 8448 (or `.well-known` delegation) and a public certificate.
  The LAN test setup does not expose this.
