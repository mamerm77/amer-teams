"""Ask-the-meeting agent: host switch read from room state, 20-minute window, label to Guardian, audit."""
import time
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app import agents, auth, db, meeting_ai
from app.main import app

ME = "@moh:amer.test"; calls = []; audits = []; state = {}
async def fake_user(): return {"user_id": ME, "token": "t"}
async def member(user, room_id):
    if room_id.startswith("!not"): raise HTTPException(403, "Not a member")
async def fake_state(user, room_id, typ): return state.get(typ, {})
async def fake_run(prompt, context="", labels=None, agent=None):
    calls.append({"prompt": prompt, "context": context, "labels": labels}); return {"answer": "Sara pushed back on slide 4.", "agent": "Amer"}
async def noop(*a, **k): pass
async def log_audit(u, a, d=""): audits.append(f"{a} {d}")

def client(monkeypatch):
    calls.clear(); audits.clear(); state.clear()
    app.dependency_overrides[auth.matrix_user] = fake_user
    monkeypatch.setattr(auth, "assert_room_member", member); monkeypatch.setattr(meeting_ai, "_state", fake_state)
    monkeypatch.setattr(agents, "run", fake_run); monkeypatch.setattr(db, "ai_request", noop); monkeypatch.setattr(db, "audit", log_audit)
    return TestClient(app)

now = lambda m=0: int(time.time() * 1000) - m * 60_000
def body(**k): return {"room_id": "!r", "question": "Which slide got the most pushback?",
                       "transcript": [{"speaker": "Sara", "text": "I disagree with slide 4", "ts": now(5)},
                                      {"speaker": "Omar", "text": "old line", "ts": now(45)}], **k}

def test_refused_unless_host_switched_on(monkeypatch):
    c = client(monkeypatch)
    assert c.post("/v1/meetings/meet-1/ask", json=body()).status_code == 403
    state[meeting_ai.STATE] = {"enabled": True, "call_id": "other-call"}
    assert c.post("/v1/meetings/meet-1/ask", json=body()).status_code == 403
    assert calls == []

def test_answers_from_last_20_minutes_only(monkeypatch):
    c = client(monkeypatch); state[meeting_ai.STATE] = {"enabled": True, "call_id": "meet-1"}
    r = c.post("/v1/meetings/meet-1/ask", json=body()).json()
    assert r["answer"].startswith("Sara") and r["lines_used"] == 1
    assert "slide 4" in calls[0]["context"] and "old line" not in calls[0]["context"]
    assert "Which slide" in calls[0]["prompt"] and audits[-1].startswith("ai.meeting_ask call=meet-1 lines=1")

def test_label_goes_to_guardian(monkeypatch):
    c = client(monkeypatch); state[meeting_ai.STATE] = {"enabled": True, "call_id": "meet-1"}
    state["com.amerteams.sensitivity"] = {"label": "Confidential"}
    c.post("/v1/meetings/meet-1/ask", json=body())
    assert calls[0]["labels"] == ["Confidential"]

def test_not_member_and_empty_transcript(monkeypatch):
    c = client(monkeypatch); state[meeting_ai.STATE] = {"enabled": True, "call_id": "meet-1"}
    assert c.post("/v1/meetings/meet-1/ask", json=body(room_id="!notmine")).status_code == 403
    r = c.post("/v1/meetings/meet-1/ask", json=body(transcript=[])).json()
    assert r["lines_used"] == 0 and "Captions" in r["answer"] and calls == []
