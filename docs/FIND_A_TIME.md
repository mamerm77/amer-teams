# Find-a-time

Phase 3, Meetings and calendar (docs/PHASE3_REQUIREMENTS.docx). Benchmarks: Outlook Scheduling Assistant, Google
Calendar "Find a time".

## Using it
Calendar → **Find a time**, or a chat's menu → **Find a time** (that chat's members). Choose the duration
(15/30/60/90 min) and how far ahead to look (2–30 days). Amer shows the 3 best times when everyone is free, in
your time, and **Book** posts the meeting into the chat.

Calendar → the clock icon sets:
- working days and hours;
- *keep prayer times free*: a city, plus the method (Muslim World League, UAE 18.2°, Umm al-Qura, Egyptian
  authority);
- *Ramadan working hours*: two hours shorter.

## Logic
- **Free/busy only.** Each app publishes `PUT /v1/calendar/freebusy`: the start and end of its upcoming meetings
  (never titles or chats), plus working hours, IANA time zone and the prayer and Ramadan settings. It does this
  when the app starts and when the Calendar opens.
- **Find** (`POST /v1/calendar/find-time`) checks every quarter-hour start in the window. A slot counts only if
  it is, for every person:
  - inside their working day *in their own time zone*;
  - not on a day off;
  - not overlapping a busy block;
  - with prayers set: not overlapping any prayer (Fajr, Dhuhr, Asr, Maghrib, Isha) plus 20 minutes;
  - in Ramadan, with Ramadan hours set: before the shortened end of day.
- **Ranking.** Earlier is better, the organiser's mid-morning is preferred, back-to-back with another meeting is
  avoided, and the three options are at least an hour apart.
- **People without a calendar** (who have not opened the app's calendar yet) are listed by name as "not
  checked", never assumed free.
- Each search is audited (counts only).

## Prayer times and Ramadan
- **Prayer times:** the standard astronomical method (solar declination and equation of time; Fajr and Isha by
  sun angle, Asr by shadow ratio; Umm al-Qura Isha is 90 minutes after Maghrib).
- **Checked against a published timetable:** for Abu Dhabi on 1 and 15 December 2026 (TrueCalendar, MWL), all
  twelve times are within one minute.
- **Ramadan:** the arithmetical Hijri calendar. It puts 1 Ramadan 1447 on 18 February 2026, but it can differ
  by a day from the local sighting.

## Gaps against the requirement (open)
- Outlook and Google calendars are not read yet (connectors item).
- The scheduler agent does not yet call find-a-time from plain language. *Schedule with Amer* still proposes a
  time itself.
- The time zone comes from the device's UTC offset, mapped to a Gulf zone where it matches.

## Tests
- `services/orchestrator/tests/test_find_time.py`: prayer times against the published timetable; Hijri and
  Ramadan; working hours across Dubai and Cairo; busy blocks; weekend; prayer and Ramadan rules; the API refuses
  bad zones and lists people without calendars.
- In-use (CI): Bob publishes free/busy. From the chat with Bob, Find a time shows "Everyone is free at", with
  Bob checked, and Book posts the meeting.
