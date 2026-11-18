# Feature logic register

**In-use test, build 39: 43 of 43 steps pass.** The real app was driven against the real server stack with a real end-to-end encrypted peer.

For every feature: the rule competitors use, the rule Amer Teams implements, where it is **enforced**, the test that
proves it, and the status. Enforcement levels:
- **Server**: Synapse, LiveKit or the orchestrator refuses violations, so a modified app cannot bypass the rule.
- **App**: only the app enforces it.

**Status:**
- **Verified in use**: passed the in-use test, where the real app was driven against the real server with a real peer.
- **Server-tested**: proven by a live API or protocol test, but not yet driven through the app.
- **Gap**: logic missing or wrong. Being fixed.

## Messaging
| Feature | Competitor rule | Amer Teams rule | Enforced | Test | Status |
|---|---|---|---|---|---|
| Encrypted 1:1 and group chat | WhatsApp, Signal: end-to-end by default | Every room has `m.room.encryption`. The server policy forces it, and the app refuses to send if it is missing. The database stores ciphertext only. | Server + app | e2e_real 2–4; in-use "Open chat", "Send and get reply" | **Verified in use** |
| Delivery ticks | WhatsApp: 1 grey = sent, 2 grey = delivered, 2 blue = read | 🕓 sending · ✓ stored on server for all recipients · ✓✓ (blue) read. A receipt on a later message implies earlier ones were read. Matrix has no per-device delivery receipt, so "delivered" and "sent" are the same tick. | Server (receipts) + app (display) | in-use "Read receipt ticks" | **Verified in use** |
| Failed send | WhatsApp: red ⚠, tap to retry | ⚠ Not sent · tap → Retry / Delete. The message is kept on the device until resolved. | App | none yet | Gap: no test |
| Reply / quote | All four | Reply shows the quoted original and keeps the link to it (`m.in_reply_to`) | App + protocol | in-use "Reply" | **Verified in use** |
| Reactions | All four | One emoji per user per message. Counts are aggregated from the timeline. | Protocol | in-use "React" | **Verified in use** |
| Edit | WhatsApp: 15 min · Telegram: 48 h · Teams: any time, marked "Edited" | Own text messages only, **within 24 h**, marked "edited". Edits are re-encrypted. | App (Synapse has no edit window) | in-use "Edit" | **Verified in use** (24 h rule implemented) |
| Delete for everyone | WhatsApp: own messages within 2 days; admins can delete others' messages, shown as "deleted by admin" | Own messages: within 2 days. Moderators (power ≥ 50): any member's message, shown as "Deleted by <name>". | Server (redaction power level) + app (time window) | in-use "Delete" | **Verified in use** (2-day / moderator rule implemented) |
| Forward | All four, marked "Forwarded" | Re-encrypted into the target room, marked "Forwarded" | App | none yet | Gap: no test |
| Saved / starred | WhatsApp ★, Teams "Save" | Per-user list kept in encrypted account data and synced across the user's devices | Server (account data) | in-use "Save" | **Verified in use** |
| Polls | All four | Single choice. One vote per user, and the latest vote counts. Results are live. | Protocol (MSC3381 poll events) | in-use "Create a poll" | **Verified in use** |
| Checklists | Telegram, Teams Loop | Any member can tick items. The latest tick per item wins. | Protocol | in-use "Checklist" | **Verified in use** |
| Typing indicator | All four | Sent while typing, stops after 30 s or on send | Server | none yet | Gap: no test |
| Search in chat | All four | Searches decrypted messages on the device. The server cannot search ciphertext, by design. | App | in-use "Search" | **Verified in use** |
| Scheduled send | Telegram, Teams | Stored on the device and sent at the chosen time **only while the app is running**. Labelled as such. | App | none yet | Partial (by design) |
| Disappearing messages | WhatsApp: 24 h / 7 d / 90 d | Room retention policy. The server purges expired events. | Server (retention) | chat_features_test | Server-tested |
| Block | All four | Blocked user's messages and calls are hidden and never ring (`m.ignored_user_list`) | Server + app | none yet | Gap: no test |
| Mentions, Activity feed | Teams | @mention pill. Activity lists mentions, replies to me, reactions to me and missed calls. | App | none yet | Gap: no test |

## Calls (protocol v2, docs/CALL_PROTOCOL.md)
| Feature | Competitor rule | Amer Teams rule | Enforced | Test | Status |
|---|---|---|---|---|---|
| Ringing | All: ring for about 30–60 s, then missed | Rings for 45 s. "Ringing…" appears only when the callee's device confirms it is ringing. "Calling… (not reachable)" after 6 s with no confirmation. | Protocol | 11 unit tests (CI); in-use "Calling then Ringing" | **Verified in use** + unit-tested |
| Answer / timer | Timer starts on connect | Media connects only after answer. The timer starts when the other side's media arrives. | Protocol | unit + in-use | **Verified in use** + unit-tested |
| Decline / busy / cancel / no answer | All | Each has a distinct outcome, recorded on both sides and in the chat | Protocol | unit + in-use | **Verified in use** + unit-tested |
| Answered elsewhere | All multi-device apps | Ringing stops on the other devices | Protocol | unit | Unit-tested |
| Encryption | WhatsApp, Signal: always | AES-GCM frames with a post-quantum hybrid key. The server refuses calls in unencrypted rooms. The trace flags any unencrypted track. | Server + protocol | e2e_real 7–8, pq_hybrid_test, call_trace_test | Server-tested |
| Call history | All | Built only from signalling events, so every device shows the same outcome | App | in-use "Call history" | **Verified in use** |

## Meetings
| Feature | Competitor rule | Amer Teams rule | Enforced | Test | Status |
|---|---|---|---|---|---|
| Lobby / waiting room | Teams: default "People who were invited" bypass; organisers, co-organisers and presenters admit | Invited members join directly. Anyone else knocks and waits. Hosts (power ≥ 50) admit or decline. | **Server** (Matrix `knock` join rule + power levels) | meetings_test | Server-tested |
| Lock meeting | Zoom, Teams | Join rule becomes `invite`, so nobody new can knock | Server | meetings_test | Server-tested |
| Host controls | Teams, Zoom | Mute, mute all, stop video, remove, end. Host = power ≥ 50 or room owner. | **Server** (orchestrator → LiveKit) | host_controls_test 1–5 | Server-tested |
| Webinar | Teams town hall | Attendees cannot publish media. The media server enforces this through the token. | **Server** | host_controls_test 6–8 | Server-tested |
| Live participant count | Teams "Meeting in progress" | Counted from the media server, not from chat events | Server | none yet | Gap: no test |
| Raise hand, reactions, meeting chat, whiteboard | Teams, Zoom | Data channel inside the encrypted call; whiteboard strokes are encrypted room events | Protocol | in-use meeting steps | **Verified in use** |

## Administration and security
| Feature | Competitor rule | Amer Teams rule | Enforced | Test | Status |
|---|---|---|---|---|---|
| Invite-only sign-up | Teams (tenant), Zoom (account) | Registration token required, with a password policy | **Server** | registration_test (26) | Server-tested |
| Admin-only tools | All | Users, invites, audit, agent switches and call trace need server-admin rights | **Server** | registration_test, call_trace_test 3, 17, 18 | Server-tested |
| Call trace | Teams Call Quality Dashboard | Signalling, media events, quality and MOS, metadata only. Opening a trace is itself audited. | **Server** | call_trace_test (18) | Server-tested |
| Compliance archiving per tenant | Teams Purview | Off for public users (enforced). Opt-in for business tenants, and users are told. | **Server** | call_trace_test 13–16 | Server-tested; archiver service is a gap |
| Device verification, key backup, app lock | WhatsApp, Signal | Emoji verification (SAS), recovery key (SSSS), PIN after 1 min in the background | Protocol + app | none yet | Gap: no in-use test |

## Sources
- WhatsApp edit window, 15 min: [TechCrunch](https://techcrunch.com/2023/05/22/whatsapp-now-lets-you-edit-messages-with-a-15-minute-time-limit)
- WhatsApp delete for everyone, 2 days, admin deletes: [Kanal](https://getkanal.com/blog/delete-whatsapp-message-for-everyone.md)
- WhatsApp ticks: [Tech Advisor](https://www.techadvisor.com/article/727095/what-are-the-two-blue-ticks-in-whatsapp.html)
- Telegram deletion rules: [The Star](https://www.thestar.com.my/tech/tech-news/2019/03/25/delete-any-message-on-telegram/)
- Teams lobby bypass and admit roles: [Microsoft Learn](https://learn.microsoft.com/en-us/microsoftteams/who-can-bypass-meeting-lobby), [Microsoft Support](https://support.microsoft.com/teams/meetings/using-the-lobby-in-microsoft-teams-meetings)
