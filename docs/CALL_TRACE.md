# Call trace, quality and compliance

## What administrators see (all tenants)
Admin app → Users → **Call trace** (`GET /v1/admin/calls`, `GET /v1/admin/calls/{id}/trace`, server admins only).

| Data | Source | Stored in |
|---|---|---|
| Every signalling step, both directions: invite, ringing, answer, reject, hangup, end, state changes, errors, with device ID, reason, outcome | each device reports what it sends and receives (`POST /v1/calls/trace`) | `call_events` (source `client`) |
| Media-server events: room started/finished, participant joined/left, track published/unpublished, codec (mime type), **whether each track is encrypted** | LiveKit webhooks, verified with the API secret and a SHA-256 of the body | `call_events` (source `media`) |
| Audio/video quality per participant and direction: codec, bitrate, packets, loss %, jitter, RTT, **MOS** (ITU-T G.107 E-model) | WebRTC `getStats` every 10 s and at hang-up (`POST /v1/calls/quality`) | `call_quality` |
| One row per call: caller, callee, start, answer, end, outcome, duration, participants, tenant | derived from the above | `call_records` |

Every time an administrator opens a trace, that access is written to the hash-chained audit log.

## What nobody sees by default
Message text, files, voice and video content are end-to-end encrypted on the devices. The server stores and
forwards only ciphertext, so the trace cannot contain content. This is the default for every user and the only
mode for **public** users.

## Business tenants: compliance archiving (opt-in, per tenant)
`/v1/admin/tenants` creates a tenant, `/v1/admin/tenants/members` assigns users. With `compliance_enabled`, the
tenant names an **archiving account**. That account is a member of the tenant's conversations, so the standard
Matrix key sharing gives it the keys like any other participant. The organisation holds content keys, not the
server operator.
- Users are told: `GET /v1/compliance/me` drives a visible notice in the app.
- Cannot be enabled for the `public` tenant (enforced by the API).
- Retention per tenant (1–3650 days).

Status: the tenant model, API, enforcement and user notice are implemented and tested. Still to build:
- automatic membership of the archiving account in tenant rooms
- the archiver service that stores decrypted content for e-discovery

## Retention
`call_events`, `call_quality` and `call_records` follow the tenant's `retention_days`. An hourly purge runs on one replica at a time (PostgreSQL advisory lock). `POST /v1/admin/calls/purge` runs it on demand, and that run is audited.
