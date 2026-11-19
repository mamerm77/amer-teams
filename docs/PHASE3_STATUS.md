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
| In-person meeting notes | Built: on-device transcription, speaker marking, AI minutes, decisions and tasks; no diarisation (IN_PERSON_NOTES.md) |
| No-code workflows | Built |
| Agent messages visible to one user | Partial: meeting answers and `/ask` are private on the asker's screen; the encrypted-to-one-user event is not built |
| Canvases / Loop | Built |
| Shared files tab with versions | Existing files view; versions and grouping not started |
| Drafts, mentions, followed quick views | Built |
| Shared channels across organisations | Built (see top five) |
| Webinars and town halls | Built: registration page with capacity, attendee-only join links, Q&A with votes; tested 12/12 on the real stack with a browser. HLS not built (WEBINARS.md) |
| Breakout rooms | Existing |
| Live translated captions | Built: per-listener language, label-aware AI translation of shared captions, right-to-left lines; AI engine, not on device (TRANSLATED_CAPTIONS.md) |
| Noise suppression, blur, low light | Built, not tested on a real camera: native plugin (ML Kit on Android, Vision on iOS) blurs and brightens before encryption; desktop not available (BACKGROUND_EFFECTS.md) |
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
| 6 | Pre-mortem agent | Built: /premortem, ranked plan-specific risks, share or turn mitigations into tasks (PREMORTEM.md) |
| 7 | Network-aware calls | Built: per-tile quality, automatic data saver then audio-only (screen share kept), recovery; manual modes (NETWORK_AWARE.md) |
| 8 | Quantum-safe badge | Built: chat padlock with key types, rotation and verified devices; says plainly that messages are not yet quantum-safe |
| 9 | Arabic-first co-pilot | Partial: Arabic UI with right-to-left layout (navigation and key screens translated), prayer times, Ramadan hours, Arabic decision phrases; full string translation and Hijri calendar view open (ARABIC.md) |
| 10 | Focus guardian | Built: server holds pushes (priority senders only), status, DM auto-reply, busy in find-a-time, summary of what waited (FOCUS.md) |
| 11 | Wellbeing signals | Built: private, on-device weekly signals and nudges; no team view by design (WELLBEING.md) |
| 12 | Live expertise map | Not started |
| 13 | Ambient presence rooms | Not started |
| 14 | Agent marketplace | Not started |
| 15 | Operator mode for telecoms | Built: on-call rotas, incident numbers, encrypted war rooms, paging through quiet hours, forward-only states, MTTA/MTTR, Alertmanager opens and resolves incidents; AI post-incident review; tested 12/12 (OPERATOR_MODE.md) |

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
| Browser join for guests | Built: /join page, lobby, call key wrapped to the guest's one-time key; a real Chromium decrypts real E2EE video locally (GUESTS.md) |
| Phone dial-in | Not started (SIP dial-out exists) |
| Recordings with consent | Built, not tested on a device: everyone agrees first, recorded on the host's phone, shared encrypted, audit trail (RECORDINGS.md) |
| Whiteboard templates | Built: retro, SWOT, optical/IP network sketch, text labels |
| Automatic follow-up | Built: minutes follow the agenda; decisions become proposals, actions become tasks. Email to external invitees not built |
| Find-a-time | Built (FIND_A_TIME.md), with prayer times and Ramadan hours |
| Out-of-office from calendar | Built: leave or OOF events in a connected calendar switch it on and off; manual setting wins (CONNECTORS.md) |
| Message-to-task and task boards | Built (DECISIONS.md) |
| File previews with comments | Built: PDF (pdfium), Word, Excel, PowerPoint and text previewed on the device; threaded encrypted comments. Layout not reproduced (FILE_PREVIEWS.md) |
| Unified search | Built: on-device FTS index, filters, people (SEARCH.md); transcripts not indexed |
| Notification settings and quiet hours | Built: server push filter, per-chat levels, priority senders (NOTIFICATIONS.md) |
| Accessibility | Built: text size, high contrast, bold, reduce motion, captions by default, call shortcuts, screen-reader announcements; not yet audited with assistive-technology users (ACCESSIBILITY.md) |
| Multi-device handoff | Built for meetings and group calls: other devices offer "Move it here", old device disconnects; 1:1 calls not yet (HANDOFF.md) |
| Calendar and tool connectors | Partial: any calendar by ICS (Outlook, Google, iCloud), fetched on the device, busy times only to find-a-time; read only, no tool connectors yet (CONNECTORS.md) |
| Usage analytics | Built: active people, calls, quality, AI, feature adoption; small groups folded (k = 5); checked on the real database (ANALYTICS.md) |
| Guest accounts and UAE data residency | Built: guest accounts limited by the server (no rooms, no invites, invited rooms only), expiry; tested 10/10 on the real stack. Residency report from declared locations (GUEST_ACCOUNTS.md, DATA_RESIDENCY.md) |

## Platform
| Item | Status |
|---|---|
| Modern 3D UI with 2.5D and flat fallbacks | Not started |
| Feature flags per tenant | Built: per tenant, stable rollout %, server-gated, admin screen (FEATURE_FLAGS.md) |
| Arabic and English strings (ARB), RTL | Partial: locale switch, RTL, Flutter widgets localised, key strings translated |
