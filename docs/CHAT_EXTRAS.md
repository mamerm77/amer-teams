# Everyday chat features (Phase 3, Chat, files and search)

| Feature | How it works | Where |
|---|---|---|
| **Scheduled send** | Long-press Send, the attach menu, or `/later text`. The message is kept *on this device* in a file (survives restarts) and sent from it at the time. The server never holds the text. If the app was closed at the time, it is sent when the app next opens and labelled "sent late". A *N scheduled* chip above the composer lists them: edit text, change time, send now, cancel. Sends reuse a fixed transaction id, so a retry never duplicates. | `services/later.dart` |
| **Remind me** | Message options → Remind me (20 min, 1 h, 3 h, tomorrow 09:00), or `/remind 30 text`. When due, a banner offers Open, In 1 hour or Done. | `services/later.dart`, home banner |
| **Slash commands** | Typing `/` lists the commands: `/poll`, `/meet`, `/remind`, `/ask`, `/announce`, `/later`, `/canvas`. An unknown command shows suggestions. `//` sends a literal slash. `/ask` answers only you, using the chat's recent messages and its sensitivity label, so Confidential and Restricted chats are blocked by Guardian. | `chat_screen.dart` |
| **Announcements with acknowledgement** | `/announce text` posts a banner card (`com.amerteams.announcement`). Members tap *I acknowledge*, which sends `com.amerteams.ack`, encrypted. The sender sees "N of M acknowledged", who is pending, and *Remind pending*, which @mentions the people who have not acknowledged. | `chat_screen.dart` |
| **Code blocks** | ```` ``` ```` fenced blocks render monospace, scroll sideways, and have a Copy button. Markdown also goes as `formatted_body` (SDK). | `chat_screen.dart` |
| **Translate on tap** | Message options → Translate (Amer). The chat's sensitivity label is passed, so labelled chats are blocked. Each message's translation is cached for the session. | `chat_screen.dart` |
| **Retention timers** | Chat info → Disappearing messages: 24 h, 7 d, 30 d, 90 d, 1 year, 7 years (`m.room.retention`). Synapse purges expired events hourly (`retention.enabled`), every client hides expired messages, and a banner shows the active timer. | `chat_info_screen.dart`, deploy configs |

## Gaps against the requirement (open)
- **Reminders** are per device. The spec wants them synced across devices through *encrypted* account data;
  plain account data would expose the text to the server, so this waits for secret-storage integration.
- **Reminders** are an in-app banner, not an OS notification (no local-notification plugin yet).
- **Translation** runs through the AI engine, not on the device or in an enclave (Encrypted AI item). Labelled
  chats are blocked rather than translated on the device.
- **Syntax highlighting** by language, **tables** in messages, **legal hold**
  on retention, and **tenant retention policy** precedence are not built yet.
- `/premortem` and marketplace commands arrive with those features.

## Tests (in-use, CI)
- `/announce` posts the card with "0 of 1 acknowledged". Bob acknowledges from his device, and the sender
  sees "1 of 1 acknowledged".
- `/later` schedules a message, the chip lists it, *Send now* sends it, and it appears in the chat.

## Quick views and threads (added)
- Chat list chips: **@Mentions** (chats with unread mentions), **Drafts** (unsent text per chat, kept on this device and restored when the chat opens), **Followed threads**.
- In a thread: **Follow** or **Mute** (bell icon). The state is kept in account data (ids and times only). Followed threads list how many replies came since you last opened each. Replies in muted threads are left out of Activity.
- Gap: pop-out threads into their own desktop window are not built.

## Group mentions (added)
- Typing `@` also offers **@channel**, **@here** (everyone in the chat), **@moderators** (power 50+) and **@admins** (power 100).
- @channel / @here are sent as Matrix `@room`. Only members at the room's `notifications.room` power level (default 50) may send them; otherwise the message is not sent and the text is kept.
- Role mentions expand on send into one pill per member holding the role (sender excluded), so each person gets a normal mention.
- Messages with `m.mentions.room` or `@room` count as mentioning you (highlight, Activity, @Mentions chip).
- Logic: `services/group_mentions.dart`, unit tests in `app/test/group_mentions_test.dart`. Custom named roles (beyond power levels) are not built.
