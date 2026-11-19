# Ambient presence rooms

Every encrypted team chat has an always-open **team room**, like walking past a colleague's desk. A bar at the top of the chat shows who is in it now ("Team room: Amira, Bilal · Drop in"), checked every 30 seconds.

- **Drop in** joins with the microphone and camera **off**, with no pre-join screen. Unmute when you want to talk. Everything else (encryption, captions, network-aware video) is the same as a meeting.
- **Who's here** comes from the media server's participant list: names only, never media. Only members of the chat can ask (`GET /v1/ambient/{room}`).
- The room is a meeting with call id `meet-ambient-<room>`, so the call key is wrapped to members' devices like any meeting, and nothing rings.
- Tested on the real stack: `tests/ambient_test.py`, 4/4. A real LiveKit participant shows up for a teammate, and a non-member is refused.

## Open gaps
- The first person to open the room posts a "voice call" line in the chat (the normal call record).
- No "knock" or quiet-hours awareness: the bar shows the room regardless of focus sessions.
