# Pre-mortem agent

In any chat: `/premortem <the plan>`, or `/premortem` on its own to use the recent conversation.

The pre-mortem agent imagines it is six months later and the plan has failed, then works back to why. It returns 4–7 plan-specific risks, each with likelihood, impact, why it fails, an early warning sign and a mitigation, ranked by likelihood × impact.

- The result is shown only to you first. **Share in chat** posts it as a normal encrypted message. **Make tasks** turns the risks you tick into mitigation tasks (owner you), linked to the risk.
- It goes through the encrypted-AI router like every AI feature: sensitivity labels are honoured and the route is shown.
- The agent replies as JSON; the app parses it, tolerating a Markdown fence, and refuses an answer with no risks (`app/test/premortem_test.dart`).

## Open gaps
- No pre-mortem inside meetings yet (use it in the meeting chat).
- Not yet re-run automatically when the plan changes.
