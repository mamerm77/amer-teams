# Phase 3 status register

Against docs/PHASE3_REQUIREMENTS.docx (60 features). Updated 19 Nov 2026.

**Status:**
- **Built** — code, server tests and an in-use (real stack) test step exist.
- **Built, not yet seen passing in use** — the CI run that checks it is still queued.
- **Partial** — part of the spec is built; the gap is named.
- **Existing** — already in Phase 1/2.
- **Not started**.

Each built feature has a doc listing its open gaps.

## Top five
| # | Feature | Status | Doc |
|---|---|---|---|
| 1 | Catch-up digest + ask-the-meeting agent | Built, not yet seen passing in use. Gap: AI runs on the server's AI engine, not an on-device model or enclave | CATCH_UP.md, MEETING_AGENT.md |
| 2 | Workflows from plain language | Built, not yet seen passing in use. Gaps: webhook, alarm and calendar triggers; drag-and-drop editor | WORKFLOWS.md |
| 3 | Canvases | Built, not yet seen passing in use. Own CRDT instead of Yjs; presence and images not yet | CANVAS.md |
| 4 | Secure external collaboration (shared channels) | Built: partner states, Synapse-enforced allow-list, local-by-default rooms, on-device DLP; 8/8 over two real federated servers locally | PARTNERS.md |
| 5 | Agent Ops for everyone (personal team + glass box) | Built, not yet seen passing in use. Gaps: push reminders; resume after restart | PERSONAL_AGENTS.md |

## Competitor parity (20)
| Feature | Status |
|---|---|
| Catch-up digest | Built (see top five) |
| Agent inside a live meeting | Built (see top five) |
| Video recap with chapters | Not started (needs recording) |
| Reusable AI skills and custom agents | Not started |
| In-person meeting notes | Not started |
| No-code workflows | Built |
| Agent messages visible to one user | Partial: meeting answers and `/ask` are private on the asker's screen; the encrypted-to-one-user event is not built |
| Canvases / Loop | Built |
| Shared files tab with versions | Existing files view; versions and grouping not started |
| Drafts, mentions, followed quick views | Built |
| Shared channels across organisations | Built (see top five) |
| Webinars and town halls | Existing webinar mode (attendees cannot publish); registration, Q&A and HLS not started |
| Breakout rooms | Existing |
| Live translated captions | Partial: on-device captions exist; translation not started |
| Noise suppression, blur, low light | Not started |
| Deepfake detection | Not started |
| AI call handling for phone lines | Not started |
| Room devices and booking | Not started |
| Frontline shifts and walkie-talkie | Not started |
| DLP and inherited sensitivity labels | Partial: chat labels block AI (Guardian); DLP not started |

## Creative (15)
| # | Feature | Status |
|---|---|---|
| 1 | Personal agent team | Built |
| 2 | Agent glass box | Built |
| 3 | Encrypted AI (on device or enclave) | Partial: routing table, no silent fallback, server-enforced policy, where-it-ran labels. No on-device model or enclave yet (ENCRYPTED_AI.md) |
| 4 | Decision ledger | Built, not yet seen passing in use (DECISIONS.md) |
| 5 | Meeting digital twin | Not started |
| 6 | Pre-mortem agent | Not started |
| 7 | Network-aware calls | Not started (call trace collects the inputs) |
| 8 | Quantum-safe badge | Built: chat padlock with key types, rotation and verified devices; says plainly that messages are not yet quantum-safe |
| 9 | Arabic-first co-pilot | Partial: prayer times, Ramadan hours and Arabic decision phrases; RTL and Hijri calendar UI not started |
| 10 | Focus guardian | Not started |
| 11 | Wellbeing signals | Not started |
| 12 | Live expertise map | Not started |
| 13 | Ambient presence rooms | Not started |
| 14 | Agent marketplace | Not started |
| 15 | Operator mode for telecoms | Not started |

## Practical (25)
| Feature | Status |
|---|---|
| Scheduled send and reminders | Built (CHAT_EXTRAS.md). Reminders are per device and in-app, not OS notifications |
| Follow, mute, pop-out threads | Built: follow and mute, Followed threads view; pop-out not started |
| Rich text, code blocks, role mentions | Partial: Markdown and code blocks with copy; role and channel mentions not started |
| Translate on tap | Partial: label-aware and cached, via the AI engine |
| Bookmarks and folders | Existing saved messages; folders not started |
| Announcements with acknowledgement | Built |
| Retention and auto-delete timers | Built (1 day to 7 years, server purge, banner); legal hold not started |
| Slash commands | Built |
| Meeting templates with agenda timer | Built: shared timer, 80% warning, parking lot (MEETING_AGENDA.md) |
| Browser join for guests | Not started |
| Phone dial-in | Not started (SIP dial-out exists) |
| Recordings with consent | Not started |
| Whiteboard templates | Built: retro, SWOT, optical/IP network sketch, text labels |
| Automatic follow-up | Built: minutes follow the agenda; decisions become proposals, actions become tasks. Email to external invitees not built |
| Find-a-time | Built (FIND_A_TIME.md), with prayer times and Ramadan hours |
| Out-of-office from calendar | Partial: set by hand (status, automatic reply, delegate); calendar-event trigger waits for connectors |
| Message-to-task and task boards | Built (DECISIONS.md) |
| File previews with comments | Partial: images preview; PDF and Office not started |
| Unified search | Partial: in-chat search exists; cross-chat index not started |
| Notification settings and quiet hours | Built: server push filter, per-chat levels, priority senders (NOTIFICATIONS.md) |
| Accessibility | Not started (beyond tooltips and labels) |
| Multi-device handoff | Not started |
| Calendar and tool connectors | Not started |
| Usage analytics | Not started |
| Guest accounts and UAE data residency | Not started |

## Platform
| Item | Status |
|---|---|
| Modern 3D UI with 2.5D and flat fallbacks | Not started |
| Feature flags per tenant | Built: per tenant, stable rollout %, server-gated, admin screen (FEATURE_FLAGS.md) |
| Arabic and English strings (ARB), RTL | Not started |
