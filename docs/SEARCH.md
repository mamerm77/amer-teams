# Search everywhere

Phase 3, practical feature "unified search" (docs/PHASE3_REQUIREMENTS.docx).

- **Where.** Chats → the search icon (*Search everywhere*). Type two or more letters. Words match as prefixes:
  "vend" finds "vendor".
- **What it searches.**
  - *Messages and file names* in every chat, from this device's index.
  - *People*, from the directory, shown when no type filter is set. Tap a person to start an encrypted chat.
- **Filters.** Type (all, files, photos, voice), chat, sender (anyone, me, or a person you chat with directly),
  and time (any, 7 days, 30 days). Results are newest first; tap one to open the chat.
- **How.** Messages are end-to-end encrypted, so the **server never builds a content index**. Each device keeps
  its own full-text index (SQLite FTS4, `services/search_index.dart`) of the messages it has decrypted:
  - new messages are added as they arrive, and edits replace the old row;
  - deleted messages (redactions) are removed;
  - on start, the most recent 300 events of each chat are backfilled.

## Gaps (open)
- The index file lives in the app's private storage but is not itself encrypted (no SQLCipher yet). It relies on
  the device's storage protection and the app lock.
- Meeting transcripts are not indexed (they are not stored).
- Older history beyond 300 events per chat is indexed only once the chat has been scrolled back.

## Tests (in-use, CI)
"vendo" finds "Send the vendor comparison" from the chat with Bob.
