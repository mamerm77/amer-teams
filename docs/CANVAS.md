# Canvases

Phase 3, top five #3 (docs/PHASE3_REQUIREMENTS.docx). Benchmarks: Slack canvases, Microsoft Loop.

## Using it
In any chat, the **Canvases** button lists the chat's canvases; **New canvas** creates one, and a card appears in
the chat. Blocks: **heading**, **text**, **checklist** item, **table** (add rows and columns), and an **embedded
message** from the chat. The block menu deletes a block or adds table rows and columns. Tap the title to rename.
**Version history** lists every edit (who and when) and shows the canvas as it was after any of them.

## Logic
- **CRDT** (`app/lib/services/canvas_crdt.dart`). Every member's device merges; there is no server merge.
  - *Lists* (RGA): the block list, each block's characters, a table's rows and columns. Each element has an id
    `[lamport, device]`; concurrent inserts at the same place are ordered by id, and deletes leave tombstones.
    So two people typing in the same paragraph, even offline, both keep their text.
  - *Registers* (last writer wins by id): checked, table cells, title, block properties. Two people editing the
    same table cell at once: the later edit wins (whole cell).
  - Ops that arrive before what they refer to wait until it arrives, so any delivery order converges. Duplicates
    are harmless.
- **Transport.** Edits are batched every 400 ms into an encrypted room event `com.amerteams.canvas.update
  {canvas_id, device, ops}`. Every 200 updates a member posts `com.amerteams.canvas.snapshot {canvas_id, state}`,
  so a new joiner loads the latest snapshot and replays only what came after. Snapshots are capped at 5 MB.
- **Guards.** Same membership and encryption as the chat. A removed member's devices stop receiving the room's
  Megolm keys, so they cannot decrypt later updates.

## Deviations from the spec (open)
- The spec names **Yjs**. No Yjs implementation for Dart could be checked from here, so the canvas uses its own
  CRDT, built on the same principles (sequence CRDT plus registers). Its convergence is proved by a reference
  implementation (`tests/canvas_crdt_ref.py`, 500 random trials with any delivery order and duplicates) and the
  same cases in Dart (`app/test/canvas_crdt_test.dart`, 300 trials). Ops are JSON, not binary Yjs deltas.
- **Presence** (other people's cursors) over to-device messages is not built yet.
- **Images** in canvases (encrypted media, referenced) are not built yet.

## Tests
- `tests/canvas_crdt_ref.py`:
  - two offline edits to the same paragraph converge and both are kept;
  - concurrent inserts at the same place;
  - a delete against an insert inside it;
  - out-of-order delivery;
  - last writer wins;
  - snapshot replay;
  - 500 random trials.
- `app/test/canvas_crdt_test.dart`: the same cases through JSON, plus 300 random trials.
- In-use (CI, real server, end-to-end encrypted): the app creates a canvas and writes "Ring ready". Bob, running
  the *Python* reference CRDT on his own device, appends " for traffic" to the same paragraph. The app must show
  "Ring ready for traffic", so two independent implementations converge over real encrypted events.
