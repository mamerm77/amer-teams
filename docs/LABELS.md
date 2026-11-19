# Sensitivity labels, inheritance and DLP

Labels: **General**, **Confidential**, **Restricted** (set in Chat info).

- **Inherited labels:** a chat without its own label takes the strictest label of the team (space) it belongs to. Chat info says "Inherited from the team", and setting a label there overrides it. Every AI path (Guardian, the encrypted-AI router, skills, captions translation, meeting agents) uses the effective label.
- **Labels travel:** a forwarded message or file carries the label of the chat it came from, and can't be forwarded into a chat with a lower label ("This is labelled Restricted; Project chat is General…").
- **DLP in every chat, on the device, before encryption:** card numbers (Luhn check), IBANs (mod-97 check) and Emirates ID numbers.
  - In a channel shared with another organisation, the message isn't sent.
  - In any chat not labelled Restricted, you're warned and choose **Edit message** or **Send anyway**.

# Legal hold
Administrators place a hold on a **chat** or a **person** for a named matter (`POST /v1/admin/legal-holds`), and release it later. While a hold is active:
- **Synapse refuses** message deletions (redactions) and auto-delete (retention) changes in a held chat, and deletions by a held person anywhere. This is enforced by the Amer Synapse module, within 10 seconds of placing the hold.
- The compliance archive's retention purge skips held chats and people, and the database guard refuses those deletions even if attempted.
- People keep talking normally.

Tested on the real stack: `tests/legal_hold_test.py`, 6/6.

## Open gaps
- No automatic labelling by content.
- Holds stop new deletions; messages deleted before the hold aren't recovered.
- Synapse's own retention purge job for chats that already had auto-delete before the hold: the hold blocks changes and the archive keeps copies, but Synapse's purge of the encrypted originals isn't paused.
