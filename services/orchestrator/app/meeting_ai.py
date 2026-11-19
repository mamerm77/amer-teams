"""Ask-the-meeting agent (docs/MEETING_AGENT.md): questions about a live meeting, answered from its transcript.

The transcript never lives on the server. Each participant's device transcribes its own speech on the device and
shares final lines with the others over the meeting's end-to-end encrypted data channel. The asker's device sends
the last 20 minutes with the question; this module checks, answers and forgets.

Checks, in order:
1. the asker is a member of the meeting's chat (Synapse);
2. the host has switched Amer on for this meeting: room state `com.amerteams.meeting.ai` with enabled=true and
   the same call_id. Only users with the host power level can set that state, so the app cannot fake it;
3. the chat's sensitivity label goes to Guardian (Confidential and Restricted block the AI);
4. only transcript lines from the last 20 minutes are used.
Each question is audited (counts only). The answer is returned to the asker alone; sharing it is their choice.
"""
import time
import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import agents, auth, config, db

router = APIRouter()
WINDOW_S, MAX_LINES = 20 * 60, 600
STATE = "com.amerteams.meeting.ai"

class Line(BaseModel):
    speaker: str
    text: str = Field(max_length=2000)
    ts: int                                  # ms since epoch, when the line was spoken

class AskMeeting(BaseModel):
    room_id: str
    question: str = Field(min_length=1, max_length=1000)
    transcript: list[Line] = Field(default=[], max_length=5000)
    shared_text: str = Field(default="", max_length=20000)     # text of a shared slide or document, if any

PROMPT = ("You are Amer, answering a question from one participant during a live meeting. Use ONLY the transcript "
          "and shared text given. If the answer is not in them, say so plainly. Name speakers as given. Quote "
          "briefly when it helps. At most 6 sentences. British English.")

async def _state(user: dict, room_id: str, typ: str) -> dict:
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/rooms/{room_id}/state/{typ}/",
                        headers={"Authorization": f"Bearer {user['token']}"})
    return r.json() if r.status_code == 200 else {}

def window(lines: list[Line], now_ms: int) -> list[Line]:
    keep = [l for l in lines if now_ms - l.ts <= WINDOW_S * 1000 and l.ts <= now_ms + 60_000]
    return sorted(keep, key=lambda l: l.ts)[-MAX_LINES:]

@router.post("/v1/meetings/{call_id}/ask")
async def ask_meeting(call_id: str, req: AskMeeting, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, req.room_id)
    st = await _state(user, req.room_id, STATE)
    if not (st.get("enabled") is True and st.get("call_id") == call_id):
        raise HTTPException(403, "The host has not switched Amer on for this meeting")
    label = (await _state(user, req.room_id, "com.amerteams.sensitivity")).get("label")
    lines = window(req.transcript, int(time.time() * 1000))
    if not lines and not req.shared_text:
        return {"answer": "Nothing has been transcribed in the last 20 minutes yet. Participants need to share their "
                          "speech (Captions) for me to follow the meeting.", "agent": "Amer", "lines_used": 0}
    text = "\n".join(f"[{time.strftime('%H:%M', time.gmtime(l.ts / 1000))}] {l.speaker}: {l.text}" for l in lines)
    ctx = f"Transcript (last 20 minutes, UTC times):\n{text}" + (f"\n\nShared text:\n{req.shared_text}" if req.shared_text else "")
    t0 = time.perf_counter()
    res = await agents.run(f"{PROMPT}\nQuestion: {req.question}", ctx, [label] if label else [], "assist")
    status = "blocked" if res.get("blocked") else "error" if res.get("error") else "ok"
    await db.ai_request(user["user_id"], "Meeting agent", status, int((time.perf_counter() - t0) * 1000))
    await db.audit(user["user_id"], "ai.meeting_ask", f"call={call_id} lines={len(lines)} status={status}")
    ans = res["answer"]
    if status == "error":
        ans = ("AI is not set up on this server: an administrator needs to add an AI provider key."
               if "ANTHROPIC_API_KEY is not set" in ans else "I couldn't reach the AI service just now.")
    return {"answer": ans, "agent": res.get("agent", "Amer"), "status": status, "lines_used": len(lines)}
