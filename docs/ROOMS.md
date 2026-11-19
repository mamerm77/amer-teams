# Meeting rooms, booking and room devices

- **Rooms:** administrators add rooms (`POST /v1/rooms`) with name, site, capacity and equipment.
- **Book** (Calendar → Rooms): pick a time, length and number of people. Rooms too small are hidden, and free ones show a Book button. Others see **"Booked"**, not your title, unless you choose to show it. Only the organiser can cancel.
- **No double booking:** a PostgreSQL exclusion constraint on (room, time range). When two people book the same slot at the same instant, exactly one wins.
- **Check-in:** opens 15 minutes before the start. A booking nobody checks in to within **10 minutes** of the start is released, so the room shows free again.
- **Room display:** a tablet by the door, set up from the sign-in screen with **Set up as a room display** and a one-time code from the administrator (`POST /v1/rooms/{id}/pair`; pairing again replaces the old tablet). It needs no account. It shows Free in green or In use in red, the current and next meeting, and today's schedule, with **Check in** and **Book 15 / 30 / 60 min**. Private titles show as "Booked".
- Tested on the real stack: `tests/rooms_test.py`, 12/12, including the simultaneous-booking race and no-show release.

## Open gaps
- No video-room hardware integration (joining the room's own camera and screen to a call).
- Room bookings aren't yet written to connected Outlook or Google calendars (calendar connectors are read only).
- No room-booking admin screen: rooms are added through the API.
