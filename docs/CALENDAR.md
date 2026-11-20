# Calendar and scheduling (Microsoft Teams rules)

- **Views:** Day, Work week (Monday to Friday, the default as in Teams), Week, Month and List, with Today and previous/next. Tap an empty slot to schedule there.
- **New meeting:** title, attendees (the chat's members), date, time and duration. **Repeat** (does not repeat, every day, every weekday, every week, every month), **Show as** (Busy, Tentative, Free), **optional attendees**, and details. Or use "Schedule with Amer" in plain language.
- **Responding:** Accept, Tentative or Decline, with an optional note for the organiser. For a series, respond to this occurrence or the whole series. Declined meetings appear faded and struck through; tentative and "show as tentative" meetings are lighter.
- **Organisers:**
  - **Edit** the title, time or length, then send the update. It is posted in the meeting chat so everyone is told.
  - **Cancel** with an optional message. The meeting leaves everyone's calendar and the card in the chat shows "Cancelled by the organiser".
  - For a series, choose **this occurrence or the whole series**.
- **How it is stored:** the meeting is an end-to-end encrypted event (`com.amerteams.meeting`). Each change is its own event (`com.amerteams.meeting.update`, scoped to the series or one occurrence), and the newest change wins. Only the organiser's changes count. RSVPs are `com.amerteams.meeting.rsvp`, optionally for one occurrence.
- **Drag to reschedule** (organisers, Day and Week views): long-press a meeting and drop it on a new time. It snaps to 15 minutes; for a repeating meeting only that occurrence moves. A notice is posted in the meeting chat.
- **Categories:** red, orange, yellow, green, blue and purple, as in Teams and Outlook. The meeting block takes the colour.
- **Attendees' local times:** the meeting details show each attendee's local time when it differs from yours, using the time zone their own app publishes with their working hours (`/v1/calendar/timezones`; `tests/timezones_test.py`, 3 checks).
- **Meeting chat "During the meeting only"** (Meeting options): outside a live meeting only organisers can send. The media server says whether the meeting is live. This is enforced by the app.
