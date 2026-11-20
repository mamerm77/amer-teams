# Presence, notifications and the chat list (Microsoft Teams rules)

## Presence
- **You choose** Available (automatic), Busy, Do not disturb, Be right back, Appear away or Appear offline, with a message. If you don't pick a duration, Teams' defaults apply: Busy and Do not disturb last 1 day, Appear offline lasts until you change it, and the others last 7 days.
- **The app sets** these whenever you haven't chosen otherwise:
  - **Away** after 5 minutes without keyboard or mouse input, or when the app is in the background.
  - **In a call** or **In a meeting** while you are in one.
  - **Presenting** while you share your screen.
  - Do not disturb and Appear offline that you set still win during calls.
- **Do not disturb and Presenting:** messages still arrive, but no banners show. Calls are declined as busy. Push notifications are held by the server. People on your priority list (Notifications → Priority people) still get through, with banners and calls.
- Everyone sees the same state on all your devices. It is kept in account data and published as Matrix presence, with a tag such as `[meeting]`.

## Chat list
- Order: **Favourites**, then **your own sections** (up to 50; rename, move up, collapse or delete each one; a collapsed section still shows its unread count), then **Chats** by recency, then **Muted** at the bottom.
- **Mute:** you get no notifications except @mentions, and the chat moves to Muted.
- **Hide:** the chat leaves the list until someone sends a new message. "Hidden chats" at the bottom lists them, each with Unhide.
- **Move to a section…** and **Add to Favourites** are in each chat's menu (long press).
- **Keyboard:** Ctrl+N starts a new chat; Ctrl+G goes to any chat or channel by name.

## Channel notifications
Each channel's menu → Channel notifications offers three choices: all new posts and replies, only @mentions (Teams' "off"), or nothing.

## Slash commands (as in Teams)
`/available`, `/busy`, `/dnd`, `/brb`, `/away` and `/offline` set your status, optionally with a message after the command. `/hide` hides the chat until someone posts. `/mute` and `/unmute` change its notifications. `/goto name` opens another chat or channel. `/files` shows the chat's files and `/saved` your saved messages. These sit alongside `/poll`, `/meet`, `/remind`, `/ask`, `/announce`, `/later`, `/canvas`, `/premortem` and `/skill`.

## @team
In a team channel, `@team` notifies everyone in the team. It follows the same rule as `@channel`: the team setting "Members can use @channel" decides whether members may send it, and the server enforces that.

## Missed activity emails
Notifications → Missed activity emails: every hour (default), once a day, or off. An email is sent when messages have been unread for more than an hour. It contains **counts only** ("5 messages in 2 chats"), because messages are end-to-end encrypted and the server cannot read them. The counts come from the push notifications Synapse already sends, and drop to zero when you read. The emails need SMTP on the server, and go to the email on your contact card. Tests: `tests/missed_email_test.py` (5 checks).
