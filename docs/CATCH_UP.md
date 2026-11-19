# Catch-up digest ("what did I miss")

Phase 3, AI and agents, item 1 (docs/PHASE3_REQUIREMENTS.docx). Benchmarks: Teams Copilot "catch me up",
Slack AI recaps.

## Trigger
- **Catch me up** on the Activity tab, at any time.
- On opening or returning to the app after 4 hours or more away, with unread chats: a banner offers
  *Catch me up* or *Later*. It never opens by itself.

## Logic
1. **On the device** (`app/lib/services/catch_up.dart`): for every joined chat with unread messages, read the
   timeline back to the user's read marker (fully-read marker or own read receipt), at most 60 messages, skipping
   own and deleted messages. Messages are decrypted here, as for normal reading. Each message carries whether it
   mentions the user (`m.mentions`, user ID or `@name`).
2. Chats labelled **Confidential** or **Restricted** (Chat info → sensitivity label) are sent with name and count
   only. Their text is not read into the request at all.
3. **Orchestrator** `POST /v1/ai/digest` (`services/orchestrator/app/digest.py`):
   - refuses any chat the caller is not a member of (checked against Synapse);
   - ranks: mentions of the user, then direct chats, then priority senders, then unread count;
   - summarises the top 30 (4 at a time) through the normal AI engine path: Guardian policy check and redaction,
     then the Digest agent; the rest are listed as "more chats";
   - each card: summary (≤ 2 sentences), decisions, items waiting for the user's reply, unread and mention counts,
     and a link to the chat;
   - caches the digest per user for 30 minutes; the same unread set returns the cached digest with no second AI
     call; *Refresh* forces a new one;
   - writes one audit entry (`ai.digest`, counts only) and one AI request record.
4. Without an AI provider key the chats are still listed by priority with counts, and the screen says summaries
   are not set up.

## Guards
- Membership check per chat; label withholding on the device and again on the server.
- Nothing is stored on the server except the 30-minute in-memory cache of the summaries (not the messages).

## Gap against the requirement (open)
The requirement says the summariser must be an on-device model or a confidential-computing enclave, *never the
plain server*. Neither exists yet. Today the unread text of non-labelled chats goes, when the user asks, to the
orchestrator and on to the configured AI provider, the same path as thread summaries and the Amer co-pilot. The
screen tells the user this. Closing the gap is the "Encrypted AI" item (creative feature 3), which needs the
enclave research spike planned for weeks 1 to 4.

Not yet built: muting and quiet-hours rules (they depend on the per-chat notification settings item).

## Tests
- `services/orchestrator/tests/test_digest.py`: ranking, label withholding, membership refusal, top 30 plus
  more, caching and refresh, no-key path, free-text fallback.
- In-use (CI, real stack): Bob posts three messages, one mentioning Moh, while the chat is closed; the app opens
  Catch me up and must show the totals, Bob's card and the mention count.
