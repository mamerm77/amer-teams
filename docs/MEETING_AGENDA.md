# Meeting agenda, parking lot, automatic follow-up and whiteboard templates

## Agenda with a timer
In a meeting, the host opens More → **Agenda and timer**, then picks a template or writes their own (one item
per line: "Title, minutes"). Templates: Weekly sync, Vendor review, Incident review, Retrospective.
- **Shared state.** The agenda is room state `com.amerteams.meeting.agenda`: items, current index and when the
  item started, tied to the meeting's call ID. Only the host can change it, because Synapse power levels enforce
  that.
- **What everyone sees.** A banner shows "Item 2 of 4: Pricing · 3:12 left" with a progress bar. It turns
  orange at 80% and red when over, showing "over by 1:05", and names the next item.
- **Moving on.** The host taps **Next item** or **Finish**. Back is available after finishing.
- **Parking lot.** `/park text` in the meeting chat adds an off-agenda topic, as encrypted event
  `com.amerteams.meeting.parking`. The banner counts them and **Parking lot** lists them.

## Minutes and automatic follow-up
With *Amer minutes* on, at the end of the meeting:
1. the minutes agent writes minutes with the agenda as its outline and the parking lot included, and posts them
   to the meeting chat;
2. Amer then extracts **decisions** and **actions** (JSON, names matched to participants).
   - Each decision becomes a **proposed decision** card. It still needs the owner and one more member to confirm
     it before it enters the ledger (docs/DECISIONS.md).
   - Each action becomes a **task** with an owner and, if one was said, a due date.

## Whiteboard templates
Whiteboard → **Templates**: Retrospective (three columns), SWOT (four quadrants), and a **Network sketch**: a
ROADM ring on the optical (DWDM/OTN) layer, PE routers on the IP/MPLS layer, and client links between them.
- A template is one encrypted event `com.amerteams.wb.template` with its strokes and labels. It replaces the board
  for everyone (after a confirmation).
- The new **Text** tool adds labels (`com.amerteams.wb.text`).

## Gaps (open)
- Agenda templates are built in; saving your own as a reusable template is not built yet.
- The follow-up email to external invitees is not built (no email integration).
- Moving and editing labels after placing them is not built.

## Tests (in-use, CI)
- **Meeting:** the host sets Weekly sync and sees "Item 1 of 3: Updates". `/park Pricing model` gives "Parking lot
  (1)". Next item gives "Item 2 of 3: Blockers".
- **Whiteboard:** apply the network template, then add a label with the Text tool.
