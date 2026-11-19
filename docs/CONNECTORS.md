# Calendar connectors

Connect any calendar that publishes an iCalendar (ICS) address: Outlook / Microsoft 365, Google Calendar, iCloud, Exchange, Zoho. Find a time → **Connected calendars** → **Connect calendar**.

- **Private by design:** the secret address is kept on this device only, and the device fetches the calendar itself every 15 minutes. Neither the address nor any event title reaches the Amer server. Find-a-time receives start and end times only, merged with Amer meetings.
- **Out of office from the calendar:** an event happening now that is marked Out of Office (Outlook's `X-MICROSOFT-CDO-BUSYSTATUS:OOF`), or titled out of office / OOO / annual leave / vacation / holiday / on leave / إجازة / خارج المكتب, switches out-of-office on until it ends, then off again. If you set out-of-office yourself, the calendar doesn't override it.
- **Reader** (`app/lib/services/ics.dart`): line folding, UTC, floating and TZID times, all-day events, DURATION, daily/weekly/monthly/yearly rules with INTERVAL, COUNT, UNTIL and BYDAY, EXDATE, cancelled events, and free (TRANSPARENT) events. Tested in `app/test/ics_test.dart`.

## Open gaps
- Read only: Amer meetings are not written back into Outlook or Google. That needs OAuth apps (Microsoft Graph, Google Calendar API) registered by your organisation.
- ICS links refresh on the provider's schedule; Outlook can lag by up to a few hours.
- TZID is resolved for Gulf, Egypt, India and UTC zones; other named zones are read as device-local time.
- Recurrence rules beyond these (BYMONTHDAY, BYSETPOS, RDATE) are not expanded: only the first occurrence counts.
