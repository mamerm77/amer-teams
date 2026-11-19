# UAE data residency

Admin → **Guests and residency** (`GET /v1/admin/residency`) lists each kind of data, where it is stored or processed, whether the server can read it, and a status against the required region (`DATA_REGION`, default `AE`).

The server cannot see which data centre its own disks are in, so whoever deploys declares each location with `RESIDENCY_DATABASE`, `RESIDENCY_MEDIA`, `RESIDENCY_FILES`, `RESIDENCY_BACKUPS`, `RESIDENCY_AI` and `RESIDENCY_PUSH`, for example `Azure uaenorth`, `AWS me-central-1`, `Core42 Abu Dhabi` or `on-premises Dubai`. Anything undeclared shows as "not declared", never as passing.

## Keeping everything in the UAE
- Run Synapse, PostgreSQL, LiveKit, the orchestrator and backups in a UAE region or on premises (setup.sh and deploy/k8s work unchanged).
- **AI:** point `ANTHROPIC_BASE_URL` at an in-region endpoint, or switch `ai_plain_server` off so no encrypted chat's text leaves.
- **Push:** Apple and Google push services are outside the UAE. Push carries only an event id, never content; to avoid it entirely, turn push off (the app syncs when opened).
- Messages, files and media are end-to-end encrypted, so even data in transit or at rest abroad couldn't be read by the server operator.

## Open gaps
- Locations are declared, not detected.
- No geo-fenced sign-in (blocking log-ins from outside the UAE).
