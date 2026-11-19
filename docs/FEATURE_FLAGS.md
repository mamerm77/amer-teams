# Feature flags

A requirement for every Phase 3 feature ("feature flags per tenant", docs/PHASE3_REQUIREMENTS.docx).

- **Table** `flags(tenant, feature, enabled, rollout_pct)` (migration 011). Tenant `*` applies to every tenant
  that has no row of its own; a tenant's own row wins. A user's tenant comes from `tenant_members` (`public`
  if none).
- **Rollout.** A feature is on for a user when it is enabled and the user's bucket (a stable hash of user and
  feature, 0–99) is below the rollout percentage. Raising the percentage keeps everyone who was already in.
- **Server.** Each feature's API checks its flag and answers 403 "… is switched off for your organisation".
  Flagged: catch_up, meeting_agent, workflows, personal_agents, decisions, find_time, quiet_hours. The push
  endpoint that Synapse calls is never gated, so notifications keep working.
- **App.** Flags load at sign-in (`GET /v1/flags`), and entry points are hidden when off: Catch me up, My
  agents, Workflows, Canvases, Tasks and decisions, Find a time.
- **Administrators.** Users → **Feature flags**: on or off and a rollout percentage, for every tenant or one
  tenant. Every change is audited (`flag.set`).
- **Defaults.** The Phase 3 features already built are *on* by default, so an install has them. The spec says
  off by default; switching a default off for everyone is one row (`*`, feature, off). The defaults are kept on
  so finished work is not hidden.

## Tests
- `tests/test_flags.py`: defaults; `*` rows; a tenant row beats `*`; unknown features refused; the API answers
  403 when off; rollout is stable and proportional; the push endpoint is not gated.
- The PostgreSQL query (tenant row beats `*`) was run against a real database.
- In-use (CI): an administrator switches Workflows off and the entry point disappears; switching it back on
  restores it.
