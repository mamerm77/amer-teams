# Wellbeing signals

Calendar → Focus → **Your last 7 days**. Worked out **on this device** from your connected calendar, Amer meetings, the times of messages you sent (from the on-device search index) and your focus sessions. Nothing is sent anywhere, and nobody else, your manager included, can see it.

Signals: meeting hours, back-to-back meetings (under 5 minutes apart), longest run of meetings, working days with no 30-minute lunch gap between 12:00 and 14:00, messages sent outside working hours and at the weekend, and focus time. A plain-language nudge appears only when a signal crosses a line (for example, more than 20 meeting hours, or ten or more after-hours messages). Tested in `app/test/wellbeing_test.dart`.

## Open gaps
- Working hours are fixed at 08:00–17:00, Monday to Friday, for these signals. The find-a-time working hours aren't used yet.
- No team-level view, by design. An aggregate, anonymous view would need opt-in and minimum group sizes.
