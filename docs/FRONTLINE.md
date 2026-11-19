# Frontline shifts and walkie-talkie

Both live in a team chat's menu.

## Shifts
- **Publishing:** team managers, the chat's hosts (power level 50+), publish shifts: who, day, from–to (night shifts past midnight are fine), and role or site.
- **No double shifts:** a database exclusion constraint stops anyone holding two overlapping shifts.
- **Clocking:** the assignee clocks in from 15 minutes before the start until the end, then clocks out. Times are kept.
- **Swaps:** the assignee **offers** the shift, a teammate **takes it**, and a manager **approves** or declines. Approval moves the shift, unless it would double-book the new person.
- Tested on the real stack: `tests/shifts_test.py`, 8/8 (real Synapse power levels).

## Walkie-talkie
- **The channel:** push to talk, audio only, on the team's end-to-end encrypted call (the same quantum-safe key exchange as meetings). Everyone stays connected with the microphone off.
- **Talking:** hold the button to talk. One person at a time: pressing claims the floor over the data channel, and if someone else is talking you're told who. Nobody holds the floor for more than a minute.
- **Who spoke:** screen readers announce who is talking, and a short log shows who spoke when.

## Open gaps
- Walkie-talkie works while the screen is open. Background push-to-talk (a hardware button, or the lock screen) needs platform push-to-talk support (iOS PushToTalk framework, Android foreground service), which isn't built.
- The floor is claimed on the data channel, which isn't a server-arbitrated lock: two people pressing within the same instant can both talk briefly.
- No shift-pattern templates or availability preferences yet; no payroll export.
