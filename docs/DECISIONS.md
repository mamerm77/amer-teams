# Decision ledger and tasks

Phase 3: creative feature 4 (decision ledger) and practical feature "message-to-task and task boards"
(docs/PHASE3_REQUIREMENTS.docx).

## Decisions
- **Detection, on the device.** A message with decision language ("we agreed", "decided", "go with",
  "تم الاتفاق", "اتفقنا", "قررنا") shows *Looks like a decision · propose it*. Any message can also be
  proposed with Message options → *Mark as decision*. Nothing is posted until someone proposes.
- **Proposal.** An encrypted event `com.amerteams.decision.proposal` {decision_id, version, text, owner, due,
  source_event, supersedes}, shown as a card.
- **Quorum, checked by the server.** Each person taps **Confirm**. That sends an encrypted
  `com.amerteams.decision.confirm` (so everyone sees who confirmed) and calls `POST /v1/decisions/confirm`
  *with their own sign-in*, presenting the SHA-256 of the text they saw.
  - The server accepts only room members and only the same text, owner and due date as the others.
  - The decision enters the ledger when the owner plus at least one other member have confirmed, within 72
    hours of the proposal. After 72 hours the proposal is dropped.
- **Ledger.** `decision_ledger` holds metadata only: room hash, event id, owner, due, status, version, who
  confirmed, and the text hash. Each row is SHA-256 chained to the previous one; `GET /v1/decisions/verify`
  (administrators) finds any altered row. The text never leaves the chat.
- **Changes.** *Change (new version)* proposes version N+1. Once confirmed, version N is marked superseded and
  stays visible, struck through.
- **Status.** The owner marks it done (`POST /v1/decisions/{id}/status`); this is also a chained entry.
- **My decisions** (Activity): the ledger's metadata for decisions I own, with the text found on this device.
  The app matches each entry's room hash against its own chats and opens the encrypted proposal.
- A confirmed decision with an owner and a due date **creates a linked task** for the owner.

## Tasks
- `com.amerteams.task` {task_id, title, owner, due, status, reason, source_event, decision_id}, an encrypted
  room event. An update is a new event with the same task id, and the newest wins. Only the newest is shown in
  the chat.
- **States:** open → in progress → done, plus blocked (with a reason), and reopen.
- **Creating one:** Message options → *Create task* (title from the message), the chat menu → *Tasks* → *New
  task*, a confirmed decision, or a workflow `create_task` step (now enabled).
- **Boards:** the chat menu → *Tasks* gives the chat's board by state. Activity → *My tasks* gives my tasks
  across chats, overdue first.
- **Reminders:** 24 h and 1 h before the due date (17:00 that day), through the reminder service.

## Gaps against the requirement (open)
- The minutes agent does not yet extract decisions from meeting minutes; detection is on chat messages.
- The quorum is fixed (owner plus one other); it is not configurable per chat yet.
- The 5-second task sync across two devices is not measured in CI. Tasks are ordinary encrypted room events,
  so they sync like messages.
- Rejected options (`options_rejected`) are not captured yet.

## Tests
- `services/orchestrator/tests/test_decisions.py` (6), with the spec's acceptance tests:
  - a decision needs the quorum before it appears in the ledger;
  - editing creates version 2 and keeps version 1 visible (superseded);
  - tampering with a stored row makes verification fail.

  Also: a different text, a non-member, 72-hour expiry, and owner-only status. The PostgreSQL store was run
  against a real database: quorum across two users, status, verify and tamper detection. This found and fixed
  dates coming back from PostgreSQL as date objects, which had broken hashing and the second confirmation.
- In-use (CI):
  - the app detects "We agreed to go with Ciena…", proposes it, and Moh (the owner) confirms; the card says it
    still needs one member. Bob confirms from his device with his own sign-in, and the card shows "in the
    ledger".
  - a task is created from a message and marked done.
