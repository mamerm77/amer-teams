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

Tests: `tests/meeting_options_test.py` (7 checks on the real stack, including roles).

## Roles (Teams parity)
| Right | Organiser | Co-organiser | Presenter | Attendee |
|---|---|---|---|---|
| Speak, video, share | ✓ | ✓ | ✓ | only if allowed in the options |
| Mute others, remove people, admit from the lobby, make someone a presenter | ✓ | ✓ | ✓ | ✗ |
| Record (always with everyone's consent) | ✓ | ✓ | ✓ unless "Who can record" says otherwise | ✗ |
| Change meeting options, breakout rooms, end the meeting for everyone | ✓ | ✓ | ✗ | ✗ |

- Organiser means power level 100. Co-organisers are chosen in the options and given power level 50, so the server enforces their rights. Presenters means everyone when "Who can present" is Everyone (the Teams default), otherwise the people listed.
- The server checks the role on mute, remove and end (`/v1/meetings/control`); `/v1/meetings/role/{room}` reports it.
- Further options: who can admit from the lobby (presenters too, or only organisers), Q&A on/off, hide attendee names (attendees see other attendees as "Attendee"), attendance report on/off (enforced by the server), record automatically (consent is asked as soon as someone who may record joins), and who can record.
