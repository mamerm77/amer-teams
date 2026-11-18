# Amer Teams vs Microsoft Teams, Zoom, WhatsApp and Telegram

Research: November 2026, from current vendor and review sources. ✓ available · ◐ partial · ✗ not available · — not offered by that product.

> **Status of the Amer Teams column (corrected 19 Nov 2026):** these features are written in the app code and their server side passes automated tests, but **none has yet been verified by using the app on a real device**. Treat every Amer Teams ✓ as "built, not yet verified in use" until the on-device UI test run with screenshots is complete.

## Chat
| Feature | Teams | Zoom | WhatsApp | Telegram | Amer Teams |
|---|---|---|---|---|---|
| 1:1 and group chat | ✓ | ✓ | ✓ | ✓ | ✓ end-to-end encrypted by default |
| Teams / channels | ✓ | ✓ | communities | topics | ✓ |
| Threads | ✓ | ✓ | — | topics | ✓ |
| @mentions, activity feed | ✓ | ✓ | ◐ | ✓ | ✓ |
| Replies, reactions, edit, delete | ✓ | ✓ | ✓ | ✓ | ✓ |
| Typing, read receipts, presence, status | ✓ | ✓ | ✓ | ✓ | ✓ |
| Forward, saved/starred messages | ✓ | ✓ | ✓ | ✓ | ✓ |
| Formatting (bold, italic, code, quote, lists) | ✓ | ✓ | ✓ | ✓ | ✓ |
| Photos, files, voice messages | ✓ | ✓ | ✓ | ✓ | ✓ encrypted on device |
| Polls, checklists | ✓ | ✓ | polls | ✓ | ✓ |
| Scheduled send | ✓ | ✓ | — | ✓ | ◐ while the app is open |
| Disappearing messages | — | — | ✓ | ✓ | ✓ |
| Announcement-only groups | ✓ | — | ✓ | channels | ✓ |
| Chat filters, pin, mute, archive | ✓ | ✓ | ✓ | folders | ✓ |
| Group admin roles, add/remove members | ✓ | ✓ | ✓ | ✓ | ✓ |
| Block contact | ✓ | ✓ | ✓ | ✓ | ✓ |
| Message search | ✓ | ✓ | ✓ | ✓ | ✓ in the open chat |
| AI summary, translation, suggested reply | Copilot | AI Companion | Meta AI | AI summaries | ✓ Amer (opt-in; Confidential content blocked) |

## Calls and meetings
| Feature | Teams | Zoom | WhatsApp | Telegram | Amer Teams |
|---|---|---|---|---|---|
| Voice and video calls, ringing, history | ✓ | ✓ | ✓ | ✓ | ✓ |
| End-to-end encrypted calls | ◐ 1:1 only | ◐ optional | ✓ | ✓ | ✓ always, post-quantum hybrid keys |
| Meet now, meeting ID, schedule, calendar | ✓ | ✓ | links | links | ✓ |
| Recurring meetings, RSVP | ✓ | ✓ | — | — | ✓ |
| Waiting room, lock meeting | ✓ | ✓ | ✓ | — | ✓ |
| Host controls (mute, mute all, remove, end) | ✓ | ✓ | ◐ | ✓ | ✓ |
| Webinar / town hall (attendees view only) | ✓ | ✓ | — | live streams | ✓ |
| Breakout rooms | ✓ | ✓ | — | — | ✓ |
| Whiteboard | ✓ | ✓ | — | — | ✓ encrypted |
| Screen share, raise hand, reactions, meeting chat | ✓ | ✓ | ◐ | ✓ | ✓ |
| Live captions | ✓ | ✓ | — | — | ✓ on-device |
| Meeting notes / recap | ✓ | ✓ | — | — | ✓ Amer minutes (opt-in) |
| Noise suppression | ✓ | ✓ | ✓ | ✓ | ✓ plus voice isolation |
| Cloud recording | ✓ | ✓ | — | ✓ | ✗ by design (would break end-to-end encryption) |
| Virtual backgrounds | ✓ | ✓ | ✓ | — | ✗ planned |
| Calls to phone numbers | Teams Phone | Zoom Phone | — | — | ✓ SIP trunk, admin controlled |
| Auto attendant, call queues, voicemail | ✓ | ✓ | — | — | ✗ planned (phone phase) |

## Security and administration
| Feature | Teams | Zoom | WhatsApp | Telegram | Amer Teams |
|---|---|---|---|---|---|
| Device list, sign out devices | ✓ | ✓ | ✓ | ✓ | ✓ |
| Verify devices (emoji / safety code) | — | ◐ | ✓ | ✓ | ✓ emoji + in-call safety code |
| Encrypted key backup / restore on new device | — | — | ✓ | — | ✓ recovery key |
| App lock (PIN) | — | — | ✓ | ✓ | ✓ |
| Invite-only sign-up, admin user management | ✓ | ✓ | — | — | ✓ |
| Tamper-evident audit log | ✓ Purview | ◐ | — | — | ✓ hash-chained |
| Self-hosted, data stays in-country | ✗ | ✗ | ✗ | ✗ | ✓ |
| Post-quantum protection | ✗ | ◐ | ◐ | ✗ | ✓ ML-KEM-768 hybrid |

## Not included, with reasons
- **Cloud recording**: the server would have to decrypt calls. A future option is local recording on the host's device with all participants' consent.
- **Virtual backgrounds**: needs on-device video processing; planned.
- **Stickers and GIF stores, gifts, payments, Stars, Meta AI image generation**: consumer features outside an encrypted business tool.
- **Teams Rooms / Zoom Rooms hardware, workspace booking**: hardware products.
- **Auto attendants, call queues, voicemail**: belong to a full phone-system phase on top of the SIP gateway.
- **Office co-authoring (Loop, SharePoint, OneDrive)**: files are shared encrypted; live co-editing is a separate product.

## Sources
- [40 Microsoft Teams Features for Business 2026 — Stanfield IT](https://www.stanfieldit.com/blog/microsoft-teams/)
- [What's New in Microsoft Teams — Microsoft Tech Community](https://techcommunity.microsoft.com/blog/microsoftteamsblog/what%E2%80%99s-new-in-microsoft-teams--june-2026-%E2%80%93-infocomm-edition/4531968)
- [Zoom Workplace Review — GetVoIP](https://getvoip.com/blog/zoom-workplace/)
- [What's New at Zoom](https://www.zoom.com/en/products/whats-new/)
- [WhatsApp New Features 2026 — Roklo](https://www.roklo.ai/blog/whatsapp-new-features-2026)
- [The Evolution of Telegram — Telegram](https://telegram.org/evolution)
