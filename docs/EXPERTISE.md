# Live expertise map

Amer → **Who knows about…**: search a topic ("ROADM", "800G ZR+", "vendor SLAs") and get the people in your organisation who have published it, best match first, with a button to message them.

- **Opt-in, self-published:** each person lists their own topics and a one-line "about". **Suggest from my messages** looks at the words you use most in what you wrote over the last 90 days. It runs on this device, from the on-device search index, with stop words removed in English and Arabic. Nothing is shared until you add a suggestion and press **Publish**.
- The server never reads messages to build the map (they are end-to-end encrypted anyway). It stores only what was published, within the same tenant. An empty list withdraws you at once.
- Tested on the real stack: `tests/expertise_test.py` 3/3 and `services/orchestrator/tests/test_expertise.py`.

## Open gaps
- "Live" means as fresh as people republish. There's no automatic refresh, by design (nothing goes out without the person's approval).
- Ranking is word matching, not semantic: "optical transport" won't find "DWDM".
