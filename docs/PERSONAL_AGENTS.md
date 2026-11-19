# Personal agent teams and the agent glass box

Phase 3, top five #5 and creative features 1 and 2 (docs/PHASE3_REQUIREMENTS.docx).

## Using it
Amer tab (or Agent Ops) → **My agents**:
1. Write a goal ("prepare the vendor comparison for Sunday") and tick the chats the team may read. The app
   decrypts their recent messages *on your device* and sends that text with the goal. Nothing else is readable,
   because every other chat is end-to-end encrypted.
2. **Start my team**. Amer plans and delegates to a *researcher* (web search and fetch, attached chats), a
   *writer* (saves deliverables) and a *scheduler* (sends messages and books meetings). Each project shows its
   live steps: handoffs, tool calls, failures, messages, approvals and deliverables. **Stop the team** at any time.
3. **Deliverables** are saved in the project. They are never posted to a chat unless you approve it.
4. A **budget bar** shows this month's tokens. At the cap the team stops at once, and new projects are refused.

## Glass box
Every action that leaves the team (`send_message`, `schedule_meeting`) follows:

`proposed → awaiting_approval → approved | edited → executing → done`, with the exits rejected, expired
(24 h), refused (payload changed), failed and cancelled (server restart).

- The agent's tool **waits inside the session** while the owner decides. Nothing is sent meanwhile.
- **The card** shows the agent, its one-line reason, the target chat, the exact text or meeting, and the data
  touched. Cost reads "not estimated": the SDK gives exact cost only at the end, and none is invented.
- **Reject**, with a reason: the agent receives "rejected by user: <reason>" and must re-plan.
- **Edit**: the edited payload replaces the original, its hash is stored, and the audit log records the edited
  hash.
- **Approve or Edit**: the action is carried out by **the owner's app**, which holds the keys and sends encrypted
  as the owner. It reports back with the SHA-256 of exactly what it sent. If that differs from the approved
  hash, the server refuses and the agent is told. Retries reuse the approval id as the Matrix transaction id,
  so a message is never sent twice.
- A personal agent cannot use a chat its owner is not in: Synapse's 403 becomes a tool error, before any
  approval is created.

## Privacy and limits
- Personal projects (goal, messages, deliverables, events) are visible only to their owner in Agent Ops,
  including the live stream. Administrators see audit entries, not content.
- At most 3 personal projects run at once per user. The monthly token budget is set by
  `AGENTOPS_PERSONAL_TOKENS` (default 300,000) and counts the orchestrator's and sub-agents' reported usage.
- Starting, stopping, every approval decision and every execution are written to the hash-chained audit log.

## Data
- Migration 007: `agent_approvals` (as in the spec, plus owner and payload), `personal_budgets`, and
  `agentops_projects.scope`.
- API: `POST /v1/agentops/personal`, `.../personal/{id}/stop`, `.../personal/{id}/deliverables`,
  `GET /v1/agentops/approvals`, `POST /v1/agentops/approvals/{id}` {approve | edit | reject},
  `POST /v1/agentops/approvals/{id}/done` {payload_hash}, `GET /v1/agentops/budget`.

## Gaps against the requirement (open)
- No push reminders at 1 h and 12 h yet. Pending approvals show on My agents.
- After a server restart, waiting approvals are cancelled (as the spec says), but *resume from the last
  checkpoint* is not built: start the goal again.
- Running agents needs an AI provider key (`ANTHROPIC_API_KEY`). Without it, starting a team says so.
- Deliverables are stored on the server, so their text is not end-to-end encrypted (they come from the
  server-side agents).

## Tests
- `services/orchestrator/tests/test_personal_agents.py` (9), the agent's tools called exactly as the SDK calls
  them. The spec's four acceptance tests:
  1. nothing is delivered until approval, and rejecting delivers nothing;
  2. an edit changes what is sent, and the audit log stores the edited hash (the original is refused);
  3. a room the owner is not in fails with 403;
  4. at the budget cap the project stops and new ones are refused.

  Also: privacy of personal projects, owner-only decisions, 24 h expiry, restart cancels, and the SDK tool
  wiring. The PostgreSQL store was run against a real database.
- `app/test/glass_box_hash_test.dart`: the app's payload hash equals the server's, including Arabic and escapes.
- In-use (CI): the real `glass_box()` runs in the orchestrator container (no LLM) and asks to send a message as
  Moh. The card appears in My agents with the exact text. Approve, and the app sends it encrypted into the chat.
