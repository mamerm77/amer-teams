# Calendar and scheduling (Microsoft Teams rules)

- **Views:** Day, Work week (Monday to Friday, the default as in Teams), Week, Month and List, with Today and previous/next. Tap an empty slot to schedule there.
- **New meeting:** title, attendees (the chat's members), date, time and duration. **Repeat** (does not repeat, every day, every weekday, every week, every month), **Show as** (Busy, Tentative, Free), **optional attendees**, and details. Or use "Schedule with Amer" in plain language.
- **Responding:** Accept, Tentative or Decline, with an optional note for the organiser. For a series, respond to this occurrence or the whole series. Declined meetings appear faded and struck through; tentative and "show as tentative" meetings are lighter.
- **Organisers:**
  - **Edit** the title, time or length, then send the update. It is posted in the meeting chat so everyone is told.
  - **Cancel** with an optional message. The meeting leaves everyone's calendar and the card in the chat shows "Cancelled by the organiser".
  - For a series, choose **this occurrence or the whole series**.
- **How it is stored:** the meeting is an end-to-end encrypted event (`com.amerteams.meeting`). Each change is its own event (`com.amerteams.meeting.update`, scoped to the series or one occurrence), and the newest change wins. Only the organiser's changes count. RSVPs are `com.amerteams.meeting.rsvp`, optionally for one occurrence.
- **Not yet:** dragging a meeting to a new time (use Edit), categories, and time-zone display for attendees in other zones.
