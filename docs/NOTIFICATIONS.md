# Notifications, quiet hours and out of office

## Per chat
Chat info → **Notifications**: All messages, Mentions only, or Off. These are Synapse push rules, so they apply on
the server to all your devices.

## Quiet hours and priority senders
Chat list → bell icon:
- quiet hours: start, end and days; they can run over midnight;
- *let mentions, direct messages and calls through*;
- priority senders, chosen from your direct chats, who always notify.

The settings are kept on the server's **push filter** (`services/orchestrator/app/notify.py`):
- Synapse sends every push for your devices to the filter at `/_matrix/push/v1/notify` (Caddy and the Kubernetes
  ingress now route it there instead of straight to Sygnal).
- For each device, the filter checks its owner's settings and *holds* the push in quiet hours, unless it is from a
  priority sender, or Synapse marked it high priority (mentions, direct messages, calls) and you allow those.
- Held devices are never reported as "rejected", so pushers are not deleted.
- The rest goes to Sygnal with **event id, room id, counts and priority only**. The sender, event type and the
  (already encrypted) content never leave the server. The phone fetches and decrypts the message on wake.
- Each phone registers its push key with the filter, so the filter knows whose device it is.
- Held pushes are not lost: the messages are in the chat and the unread counts.

## Out of office
Calendar → beach icon: dates, an automatic reply and a delegate, kept in account data (shared by your devices).
While it is on:
- your status reads "Out of office until <date> · contact <delegate>" (presence: unavailable);
- a direct message gets the automatic reply once a day per person (`m.notice`);
- the status returns automatically when the period ends.

## Gaps against the requirement (open)
- Out of office is set by hand. Calendar events of type "OOO" from Outlook or Google arrive with connectors.
- The automatic reply is sent by whichever of your devices is open, so two open devices could each reply once.
- Quiet hours apply to pushes (phones). Desktop apps keep their own sync open and do not show OS notifications
  yet.

## Tests
- `services/orchestrator/tests/test_notify.py`:
  - quiet hours over midnight and by day; the hold rules;
  - the filter holds without rejecting, forwards ids only and passes priority senders;
  - a second device adds its key.
- The PostgreSQL push-key lookup was run against a real database.
- In-use (CI): a chat set to Mentions only; quiet hours saved; out of office on, Bob writes, and the automatic
  reply appears; then out of office is switched off.
