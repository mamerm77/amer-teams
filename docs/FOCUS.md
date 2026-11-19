# Focus guardian

Calendar → **Focus** → 30 min, 1 h, 1.5 h or 2 h.

During a session:
- **Notifications wait**, even mentions. The server's push filter holds them (`focus_until` in your notification settings) except from your priority senders.
- **Your status** reads "Focusing until 11:30".
- **Direct messages** get one automatic reply each: "I am focusing until 11:30 and will reply then. If it is urgent, please call me."
- **Find-a-time** sees you as busy until the end.

When it ends (on its own or with **End focus now**) everything goes back to normal, and you get a summary of what waited ("12 messages in 4 chats, 2 mentioning you: …"). Server rule tested in `services/orchestrator/tests/test_notify_focus.py`.

## Open gaps
- No automatic focus blocks yet (for example, "protect two hours every morning").
- Calls still ring: a call is how someone breaks through for something urgent.
