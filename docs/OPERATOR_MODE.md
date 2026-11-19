# Operator mode for telecoms

A NOC workspace in the app (navigation → **Operator**).

- **On call:** weekly (or N-day) rotas per service, with an escalation person. Everyone can see who is on call now and next. Administrators set rotas with `PUT /v1/oncall/rotas`.
- **Declare incident:** choose P1–P4, describe it, name the service and the customer impact. The server issues the next number (`INC-2026-0042`, sequential per year). The app creates an **end-to-end encrypted war room** named after it, invites the on-call engineer (and the escalation person for P1), and posts the page. The page is a mention, so it rings through quiet hours.
- **War-room banner:** number, severity, state and impact, with **Acknowledge**, **Mark identified / mitigated / resolved** and **Resolve**. States only move forward. Each change is posted in the chat, so the chat is the timeline.
- **Post-incident review:** Amer drafts a blameless review from the war room's timeline (summary, impact, UTC timeline, root cause or "not yet known", what went well or badly, actions). You see it first and share it if you choose; it goes through the encrypted-AI router.
- **From monitoring:** Alertmanager (`deploy/monitoring/alertmanager.yml`) posts to `/v1/alerts/webhook` with a shared secret. A firing critical alert opens a P1 incident, and a major alert a P2, once per alert, waiting for the on-call engineer to **Open war room**. When the alert clears, that incident resolves.
- **MTTA / MTTR** by severity over 90 days.
- **What the server keeps:** number, severity, service, state and times only. It never sees the war room's content, only a hash of its room id.
- Tested on the real stack: `tests/operator_test.py`, 12/12.

## Open gaps
- No automatic escalation yet if nobody acknowledges within 10 minutes (the escalation person is shown and paged for P1).
- No SMS or voice paging: push and in-app only. Phone paging could use the SIP gateway.
- No link to inventory or OSS (affected NEs, circuits); impact is typed in by hand.
- Rotas are set by API; there is no rota editor screen.
