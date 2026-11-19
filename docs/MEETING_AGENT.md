# Ask-the-meeting agent

Phase 3, AI and agents, item 2 (docs/PHASE3_REQUIREMENTS.docx). Benchmark: Teams interactive meeting agents
("which slide got the most pushback?").

## Trigger
- **Ask Amer** button in the meeting controls (or in the AI-listening banner), or
- `/ask <question>` typed in the meeting chat. It is never posted to the chat.

## Logic
1. **Host switch.** Only the host (power level ≥ 50) can switch Amer on, from *More → Amer in this meeting*. That
   writes room state `com.amerteams.meeting.ai` = `{enabled, call_id, by}`. The server checks this state itself,
   so the app cannot fake it, and it is tied to this meeting's call ID.
2. **Everyone sees it.** While it is on, every participant sees the *AI listening* banner.
3. **Transcript, on devices only.** Each participant's device transcribes *its own* microphone on the device
   (Captions). Only while Amer is on, each final line is shared with the other participants over the meeting's
   end-to-end encrypted LiveKit data channel. Each device keeps the combined transcript in memory only. A
   participant who has not turned on Captions shares nothing, and the banner tells them so (*Share my speech*).
4. **Question.** The asker's device sends the question and the transcript to `POST /v1/meetings/{call_id}/ask`.
   The server:
   - checks membership and the host switch;
   - keeps only lines from the last 20 minutes;
   - passes the chat's sensitivity label to Guardian, so Confidential and Restricted block it;
   - answers through the AI engine and audits `ai.meeting_ask` (counts only).
   Nothing is stored.
5. **Private answer.** The answer opens on the asker's screen only ("Only you can see this"), with *Share to
   everyone*, which posts question and answer to the encrypted meeting chat.
6. **Minutes.** *Amer minutes* now uses the combined transcript (every sharing participant), not only the
   leaver's own speech.

## Retention
The transcript lives in the meeting screen's memory and is gone when the screen closes. Minutes, when the
participant switched them on, go to the encrypted chat.

## Gaps against the requirement (open)
- Shared slide text is accepted by the API (`shared_text`) but the app does not extract text from a shared
  screen yet.
- As with the digest, the question and transcript go to the configured AI provider, not an on-device model or
  enclave (Encrypted AI item).
- Speech recognition quality and languages are the platform's on-device recogniser (Arabic availability varies by
  device).

## Tests
- `services/orchestrator/tests/test_meeting_ai.py`: refused without the host switch or for another call;
  20-minute window; label passed to Guardian; membership; empty transcript.
- In-use (CI): the host switches Amer on, the AI-listening banner shows, `/ask` opens the private answer with
  Share to everyone.
