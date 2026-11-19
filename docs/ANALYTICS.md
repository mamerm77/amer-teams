# Usage analytics

Admin → **Usage analytics** (`GET /v1/admin/analytics?days=7|30|90`, up to 365).

- **Shows:** active people per day; calls and meetings per day with minutes and average participants; media quality (average MOS and the share of poor samples); AI requests by agent with error rate and median latency; feature adoption (people and uses per feature); workflow runs and success rate; decisions recorded.
- **Privacy:** built only from metadata the server already keeps (audit log, call trace, AI request log). It never uses message content, which is end-to-end encrypted, and shows no ranking of individuals. Any breakdown group of fewer than five people is folded into "Other (small groups)".
- Checked against the real local database (Postgres) with real calls, AI and guest data.

## Open gaps
- Message volume per day is not counted: Synapse doesn't expose it through its admin API, and Amer doesn't read Synapse's database.
- No export (CSV) and no per-tenant filter yet.
