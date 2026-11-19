"""Catch-up digest: ranking, label withholding, membership check, caching, AI output parsing. No database or LLM:
the AI engine and Synapse are replaced at their boundaries only."""
from fastapi import HTTPException
from fastapi.testclient import TestClient

from app import agents, auth, db, digest
from app.main import app

ME = "@moh:amer.test"
calls: list[dict] = []
audits: list[str] = []

async def fake_user(): return {"user_id": ME, "token": "t"}
async def member(user, room_id):
    if room_id.startswith("!not"): raise HTTPException(403, "Not a member")
async def fake_run(prompt, context="", labels=None, agent=None):
    calls.append({"prompt": prompt, "context": context, "agent": agent})
    return {"answer": '{"summary": "Sara asked for the OTN report.", "decisions": ["Ship Friday"], "needs_reply": ["Send the report"]}', "agent": "Digest"}
async def noop(*a, **k): pass
async def log_audit(u, a, d=""): audits.append(f"{a} {d}")

def client(monkeypatch, run=fake_run):
    calls.clear(); audits.clear(); digest._cache.clear()
    app.dependency_overrides[auth.matrix_user] = fake_user
    monkeypatch.setattr(auth, "assert_room_member", member)
    monkeypatch.setattr(agents, "run", run)
    monkeypatch.setattr(db, "ai_request", noop)
    monkeypatch.setattr(db, "audit", log_audit)
    return TestClient(app)

def room(rid, name, kind="group", n=2, mention=False, labels=()):
    return {"room_id": rid, "name": name, "kind": kind, "labels": list(labels), "unread": n,
            "messages": [{"sender": "Sara", "body": f"msg {i}", "mentions_me": mention and i == 0, "event_id": f"$e{i}"} for i in range(n)]}

def test_ranking_mentions_then_direct_then_volume(monkeypatch):
    c = client(monkeypatch)
    r = c.post("/v1/ai/digest", json={"rooms": [room("!a", "Big group", n=9), room("!b", "Sara", kind="direct"),
                                                room("!c", "Ops", mention=True)]}).json()
    assert [x["name"] for x in r["cards"]] == ["Ops", "Sara", "Big group"]
    assert r["cards"][0]["mentions"] == 1 and r["totals"] == {"rooms": 3, "messages": 13, "mentions": 1}

def test_confidential_room_is_listed_but_never_sent(monkeypatch):
    c = client(monkeypatch)
    r = c.post("/v1/ai/digest", json={"rooms": [room("!s", "M&A", labels=["Confidential"]), room("!o", "Lunch")]}).json()
    card = next(x for x in r["cards"] if x["name"] == "M&A")
    assert card["status"] == "label" and "not sent to the AI" in card["summary"]
    assert all("M&A" not in x["context"] for x in calls) and len(calls) == 1
    assert "label_withheld=1" in audits[-1]

def test_not_a_member_is_refused(monkeypatch):
    c = client(monkeypatch)
    assert c.post("/v1/ai/digest", json={"rooms": [room("!notmine", "X")]}).status_code == 403
    assert calls == []

def test_parsed_output_and_cache(monkeypatch):
    c = client(monkeypatch)
    body = {"rooms": [room("!b", "Sara", kind="direct")]}
    r1 = c.post("/v1/ai/digest", json=body).json()
    assert r1["cards"][0]["decisions"] == ["Ship Friday"] and r1["cards"][0]["needs_reply"] == ["Send the report"]
    assert r1["cards"][0]["first_unread"] == "$e0" and r1["cached"] is False
    r2 = c.post("/v1/ai/digest", json=body).json()
    assert r2["cached"] is True and len(calls) == 1                      # no second AI call
    c.post("/v1/ai/digest", json={**body, "refresh": True})
    assert len(calls) == 2
    assert calls[0]["agent"] == "digest" and "Reply ONLY with JSON" in calls[0]["prompt"]

def test_top_30_then_more(monkeypatch):
    c = client(monkeypatch)
    r = c.post("/v1/ai/digest", json={"rooms": [room(f"!r{i}", f"R{i}", n=1 + i % 5) for i in range(35)]}).json()
    assert len(r["cards"]) == 30 and len(r["more"]) == 5 and len(calls) == 30

def test_no_ai_key_is_reported_plainly(monkeypatch):
    async def nokey(*a, **k): return {"answer": "ANTHROPIC_API_KEY is not set", "agent": "Digest", "error": True}
    c = client(monkeypatch, nokey)
    r = c.post("/v1/ai/digest", json={"rooms": [room("!b", "Sara", kind="direct")]}).json()
    assert r["cards"][0]["status"] == "no_ai" and r["cards"][0]["unread"] == 2

def test_free_text_answer_still_shown(monkeypatch):
    async def prose(*a, **k): return {"answer": "They discussed the RFP.", "agent": "Digest"}
    c = client(monkeypatch, prose)
    r = c.post("/v1/ai/digest", json={"rooms": [room("!b", "Sara", kind="direct")]}).json()
    assert r["cards"][0]["summary"] == "They discussed the RFP." and r["cards"][0]["decisions"] == []
