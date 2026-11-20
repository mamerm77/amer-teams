# Meeting options (Microsoft Teams parity)

Organisers open **Meeting options** from the meeting's More menu, or from the chat's menu before the meeting. The options apply to every meeting in that chat and reach people who are already in the meeting straight away.

| Option | Choices | Enforced by |
|---|---|---|
| Who can bypass the lobby | People in this chat · Anyone with the meeting ID can ask to join · Only organisers | Matrix join rules (server) |
| Who can present | Everyone · Only organisers · Specific people | **Server**: non-presenters get a media token that cannot send audio or video |
| Allow mic / camera for attendees | On / off | Each participant's app |
| Meeting chat | On · Only organisers can send · Off | Each participant's app |
| Allow reactions | On / off | Each participant's app |
| Allow Amer minutes and captions | On / off | Each participant's app |

Only organisers (power level 50 or more) can change the options. The server refuses the change from anyone else.

**Do not disturb** (status menu) now also holds back push notifications, using the server's focus mode. People you have marked as priority still get through. Notifications stay held until you change your status or it clears, for up to a week.

Tests: `tests/meeting_options_test.py` (4 checks on the real stack).
