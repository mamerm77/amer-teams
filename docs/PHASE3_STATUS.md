# Phase 3 status register

Against docs/PHASE3_REQUIREMENTS.docx (60 features). Updated 20 Nov 2026. Real-stack tests run locally against Synapse, LiveKit, PostgreSQL and the orchestrator; the app itself is compiled and tested in CI.

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
| Video recap with chapters | Built: summary and timed chapters from captions, in the recording's thread; no seek-to-chapter (VIDEO_RECAP.md) |
| Reusable AI skills and custom agents | Built: skills with inputs, custom agents, /skill in chats, Guardian on every run; tested 13/13 (SKILLS.md) |
| In-person meeting notes | Built: on-device transcription, speaker marking, AI minutes, decisions and tasks; no diarisation (IN_PERSON_NOTES.md) |
| No-code workflows | Built |
| Agent messages visible to one user | Built: notes in your own encrypted room, shown inline in the chat on all your devices, share or dismiss; /ask uses it (PRIVATE_AGENT_MESSAGES.md) |
| Canvases / Loop | Built |
| Shared files tab with versions | Built: files grouped by kind, versions by name with history, preview any version; on-device from encrypted history (FILES.md) |
| Drafts, mentions, followed quick views | Built |
| Shared channels across organisations | Built (see top five) |
| Webinars and town halls | Built: registration page with capacity, attendee-only join links, Q&A with votes; tested 12/12 on the real stack with a browser. HLS not built (WEBINARS.md) |
| Breakout rooms | Existing |
| Live translated captions | Built: per-listener language, label-aware AI translation of shared captions, right-to-left lines; AI engine, not on device (TRANSLATED_CAPTIONS.md) |
| Noise suppression, blur, low light | Built, not tested on a real camera: native plugin (ML Kit on Android, Vision on iOS) blurs and brightens before encryption; desktop not available (BACKGROUND_EFFECTS.md) |
| Deepfake detection | Built as impersonation protection: per-tile identity badges from device verification, and a live challenge sent encrypted to the person's own account; no synthetic-media detector, by design (IDENTITY_CHECK.md) |
| AI call handling for phone lines | Partial: inbound calls to the company line reach a hunt group with first-to-answer, and voicemail after 30 s posted encrypted (tested 4/4); the AI receptionist needs server speech-to-text and text-to-speech, not deployed (PHONE_DIALIN.md) |
| Room devices and booking | Built: booking with no double booking (database constraint), private titles, check-in and no-show release, paired room display; tested 12/12 (ROOMS.md) |
| Frontline shifts and walkie-talkie | Built: manager-published shifts, no overlaps, clock in/out, approved swaps (tested 8/8); encrypted push-to-talk with floor control; no background PTT (FRONTLINE.md) |
| DLP and inherited sensitivity labels | Built: labels inherited from the team, labels travel with forwards (no downgrade), on-device DLP in every chat (LABELS.md) |

## Creative (15)
| # | Feature | Status |
|---|---|---|
| 1 | Personal agent team | Built |
| 2 | Agent glass box | Built |
| 3 | Encrypted AI (on device or enclave) | Partial: routing with no silent fallback, server-enforced policy, where-it-ran labels, and an enclave proxy (sealed X25519 + AES-GCM requests, measurement pinned) used when policy allows; no hardware attestation (needs a confidential VM) and no on-device model (ENCRYPTED_AI.md) |
| 4 | Decision ledger | Built, not yet seen passing in use (DECISIONS.md) |
| 5 | Meeting digital twin | Built: on-device view of all minutes, decisions, open/overdue actions, recurring topics, and ask-the-history with dates (MEETING_TWIN.md) |
| 6 | Pre-mortem agent | Built: /premortem, ranked plan-specific risks, share or turn mitigations into tasks (PREMORTEM.md) |
| 7 | Network-aware calls | Built: per-tile quality, automatic data saver then audio-only (screen share kept), recovery; manual modes (NETWORK_AWARE.md) |
| 8 | Quantum-safe badge | Built: chat padlock with key types, rotation and verified devices; says plainly that messages are not yet quantum-safe |
| 9 | Arabic-first co-pilot | Partial: Arabic UI with right-to-left layout (navigation and key screens translated), prayer times, Ramadan hours, Arabic decision phrases; Hijri dates in the calendar (tabular, matching the server); about 180 more buttons and titles translated across the Phase 3 screens; body texts and messages still English (ARABIC.md) |
| 10 | Focus guardian | Built: server holds pushes (priority senders only), status, DM auto-reply, busy in find-a-time, summary of what waited (FOCUS.md) |
| 11 | Wellbeing signals | Built: private, on-device weekly signals and nudges; no team view by design (WELLBEING.md) |
| 12 | Live expertise map | Built: opt-in self-published topics, on-device suggestions from your own messages, ranked search; tested 3/3 (EXPERTISE.md) |
| 13 | Ambient presence rooms | Built: always-open team room, who's-here bar from the media server, drop in muted; tested 4/4 (AMBIENT.md) |
| 14 | Agent marketplace | Built: submit, administrator review with notes, tenant marketplace, install counts, re-review on edit (SKILLS.md) |
| 15 | Operator mode for telecoms | Built: on-call rotas, incident numbers, encrypted war rooms, paging through quiet hours, forward-only states, MTTA/MTTR, Alertmanager opens and resolves incidents; AI post-incident review; tested 12/12 (OPERATOR_MODE.md) |

## Practical (25)
| Feature | Status |
|---|---|
| Scheduled send and reminders | Built (CHAT_EXTRAS.md). Reminders are per device and in-app, not OS notifications |
| Follow, mute, pop-out threads | Built: follow and mute, Followed threads view; threads open beside the chat on wide screens (side panel, not a separate OS window) |
| Rich text, code blocks, role mentions | Built: Markdown, code blocks with copy, @channel/@here and @moderators/@admins mentions (CHAT_EXTRAS.md); syntax highlighting and tables not started |
| Translate on tap | Partial: label-aware and cached, via the AI engine |
| Bookmarks and folders | Built: saved messages in your own folders (create, move, filter, delete), synced through account data |
| Announcements with acknowledgement | Built |
| Retention and auto-delete timers | Built (1 day to 7 years, server purge, banner); legal hold built: Synapse refuses deletions and retention changes, archive purge skips held items; tested 6/6 (LABELS.md) |
| Slash commands | Built |
| Meeting templates with agenda timer | Built: shared timer, 80% warning, parking lot (MEETING_AGENDA.md) |
| Browser join for guests | Built: /join page, lobby, call key wrapped to the guest's one-time key; a real Chromium decrypts real E2EE video locally (GUESTS.md) |
| Phone dial-in | Built: number + PIN per meeting (LiveKit SIP dispatch rule) into a labelled phone bridge; tested 9/9 with real LiveKit API and webhooks, not with a carrier (PHONE_DIALIN.md) |
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
| Calendar and tool connectors | Partial: any calendar by ICS (Outlook, Google, iCloud), fetched on the device, busy times only to find-a-time; read only. Tool connectors built: Jira, GitHub, GitLab, Alertmanager, Grafana, ServiceNow, Jenkins and generic webhooks posted end-to-end encrypted into chats (tested 7/7); outgoing actions not built (CONNECTORS.md, TOOL_CONNECTORS.md) |
| Usage analytics | Built: active people, calls, quality, AI, feature adoption; small groups folded (k = 5); checked on the real database (ANALYTICS.md) |
| Guest accounts and UAE data residency | Built: guest accounts limited by the server (no rooms, no invites, invited rooms only), expiry; tested 10/10 on the real stack. Residency report from declared locations (GUEST_ACCOUNTS.md, DATA_RESIDENCY.md) |

## Platform
| Item | Status |
|---|---|
| Modern 3D UI with 2.5D and flat fallbacks | Built: 3D pointer-tilt cards and depth page turns, 2.5D layered cards, flat with reduced motion or high contrast; automatic by device (UI_3D.md) |
| Feature flags per tenant | Built: per tenant, stable rollout %, server-gated, admin screen (FEATURE_FLAGS.md) |
| Arabic and English strings (ARB), RTL | Partial: locale switch, RTL, Flutter widgets localised; navigation, titles and buttons translated (about 200 strings); longer help texts still English |
