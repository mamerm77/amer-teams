"""Glass box and personal agent teams. Spec acceptance tests marked [A]. No LLM: the agent's tools are called
exactly as the SDK would call them, and the owner's app is played by API calls."""
import asyncio, time
from pathlib import Path
from fastapi.testclient import TestClient
from app import auth, config, db
from app.agentops import personal as P, store as S
from app.main import app

OWNER = {"user_id": "@moh:amer.test", "token": "t-moh"}; OTHER = {"user_id": "@eve:amer.test", "token": "t-eve"}
audits: list[str] = []; who = {"u": OWNER}
async def fake_user(): return who["u"]
async def log_audit(u, a, d=""): audits.append(f"{a} {d}")
async def member(token, room_id):
    if room_id != "!team": raise PermissionError(f"403 from the server: the owner is not a member of {room_id}")

def setup(monkeypatch, tmp_path):
    P._mem.__init__(); P._signals.clear(); audits.clear(); S.use(S.MemoryStore()); who["u"] = OWNER
    app.dependency_overrides[auth.matrix_user] = fake_user
    monkeypatch.setattr(db, "audit", log_audit); monkeypatch.setattr(P, "member", member)
    return P.PersonalRun("Prepare the vendor comparison for Sunday", tmp_path, "Vendor comparison", OWNER["user_id"], OWNER["token"],
                         [{"room_id": "!team", "name": "Optical team", "text": "Sara: Ciena is 10% cheaper"}], "pp-test")

def run(coro): return asyncio.run(coro)

def test_send_waits_for_approval_and_reject_delivers_nothing(monkeypatch, tmp_path):     # [A]
    r = setup(monkeypatch, tmp_path); c = TestClient(app)
    async def go():
        await r.start()
        t = asyncio.create_task(r.t_send({"room_id": "!team", "text": "Draft attached", "reason": "share the draft"}))
        await asyncio.sleep(0.1)
        a = (await P.store().list(OWNER["user_id"], "awaiting"))[0]
        assert not t.done() and a["preview"]["text"] == "Draft attached" and a["est_cost_usd"] is None
        await P.store().update(a["id"], status="rejected", reason="not yet"); P._signal(a["id"])
        out = await asyncio.wait_for(t, 2)
        assert out["is_error"] and "rejected by user: not yet" in out["content"][0]["text"]
        return a["id"]
    aid = run(go())
    assert c.post(f"/v1/agentops/approvals/{aid}/done", json={"payload_hash": "x"}).status_code == 409   # nothing to carry out
    evs = [e.type for e in S.store().events]
    assert P.APPROVAL_REQUESTED in evs and P.APPROVAL_DECIDED in evs

def test_edit_changes_what_is_sent_and_audit_has_edited_hash(monkeypatch, tmp_path):     # [A]
    r = setup(monkeypatch, tmp_path)
    original = {"room_id": "!team", "text": "Ciena wins"}
    edited = {"room_id": "!team", "text": "Ciena is 10% cheaper; decision on Sunday"}
    async def flow():
        t = asyncio.create_task(r.t_send({**original, "reason": "share result"}))
        await asyncio.sleep(0.1)
        a = (await P.store().list(OWNER["user_id"], "awaiting"))[0]
        await P.decide(a["id"], P.Decide(decision="edit", edited_payload=edited), OWNER)
        await asyncio.sleep(0.1)
        x = await P.store().get(a["id"])
        assert x["status"] == "executing" and x["payload"] == edited        # the app is handed the edited text
        try:                                                                 # sending the original is refused
            await P.done(a["id"], P.Done(payload_hash=P.phash(original)), OWNER); raise AssertionError("not refused")
        except Exception as e: assert "does not match" in str(getattr(e, "detail", e))
        out = await asyncio.wait_for(t, 2)
        return a["id"], out
    aid, out = asyncio.run(flow())
    assert out["is_error"] and "refused" in out["content"][0]["text"]
    assert asyncio.run(P.store().get(aid))["status"] == "refused"
    assert any(x.startswith(f"agent.approval.edited {aid} hash={P.phash(edited)[:16]}") for x in audits)

def test_approved_action_completes_with_matching_hash(monkeypatch, tmp_path):
    r = setup(monkeypatch, tmp_path)
    async def flow():
        t = asyncio.create_task(r.t_meet({"room_id": "!team", "title": "Vendor review", "start": "2026-11-22T09:00", "duration_min": 30, "reason": "decide"}))
        await asyncio.sleep(0.1)
        a = (await P.store().list(OWNER["user_id"], "awaiting"))[0]
        await P.decide(a["id"], P.Decide(decision="approve"), OWNER); await asyncio.sleep(0.1)
        await P.done(a["id"], P.Done(payload_hash=a["payload_hash"], result="booked"), OWNER)
        return await asyncio.wait_for(t, 2)
    out = asyncio.run(flow())
    assert not out.get("is_error") and "done: booked" in out["content"][0]["text"]
    assert any(x.startswith("agent.action.done") for x in audits)

def test_cannot_read_a_room_the_owner_is_not_in(monkeypatch, tmp_path):               # [A]
    r = setup(monkeypatch, tmp_path)
    out = asyncio.run(r.t_read_room({"room_id": "!secret"}))
    assert out["is_error"] and "403" in out["content"][0]["text"]
    ok = asyncio.run(r.t_read_room({"room_id": "!team"}))
    assert "Ciena is 10% cheaper" in ok["content"][0]["text"]
    assert asyncio.run(r.t_send({"room_id": "!secret", "text": "x"}))["is_error"]
    assert asyncio.run(P.store().list(OWNER["user_id"])) == []                           # no approval was even created

def test_budget_stops_the_project(monkeypatch, tmp_path):                              # [A]
    r = setup(monkeypatch, tmp_path); monkeypatch.setattr(P, "MONTHLY_TOKENS", 1000)
    async def flow():
        async def forever(): await asyncio.sleep(60)
        r.task = asyncio.create_task(forever())
        await r.emit(S.AGENT_USAGE, "orchestrator", delta=True, tokens=600)
        assert not r.task.cancelled() and not r.task.done()
        await r.emit(S.AGENT_USAGE, "researcher", delta=False, total_tokens=500)       # sub-agent running total
        await asyncio.sleep(0)
        return r.task.cancelled() or r.task.done(), await P.store().tokens(OWNER["user_id"])
    stopped, used = asyncio.run(flow())
    assert stopped and used == 1100
    monkeypatch.setattr(config, "ANTHROPIC_API_KEY", "k")
    res = TestClient(app).post("/v1/agentops/personal", json={"goal": "Another goal please"})
    assert res.status_code == 429 and "Budget reached" in res.json()["detail"]

def test_personal_projects_are_private(monkeypatch, tmp_path):
    r = setup(monkeypatch, tmp_path); asyncio.run(r.start()); c = TestClient(app)
    assert any(p["project_id"] == "pp-test" for p in c.get("/v1/agentops/projects").json())
    who["u"] = OTHER
    assert all(p["project_id"] != "pp-test" for p in c.get("/v1/agentops/projects").json())
    assert all(e["project_id"] != "pp-test" for e in c.get("/v1/agentops/events").json())
    assert c.get("/v1/agentops/events?project_id=pp-test").status_code == 404

def test_only_owner_decides_and_expiry(monkeypatch, tmp_path):
    r = setup(monkeypatch, tmp_path); c = TestClient(app)
    a = {"id": "ap_1", "project_id": "pp-test", "owner": OWNER["user_id"], "agent": "scheduler", "tool": "send_message", "category": "write_external",
         "payload": {"room_id": "!team", "text": "x"}, "payload_hash": P.phash({"room_id": "!team", "text": "x"}), "preview": {"text": "x"},
         "status": "awaiting", "created_at": time.time() - 90000, "expires_at": time.time() - 3600}
    asyncio.run(P.store().add(a))
    who["u"] = OTHER; assert c.post("/v1/agentops/approvals/ap_1", json={"decision": "approve"}).status_code == 404
    who["u"] = OWNER; assert c.post("/v1/agentops/approvals/ap_1", json={"decision": "approve"}).status_code == 409   # expired after 24 h
    assert c.get("/v1/agentops/approvals").json()[0]["status"] == "expired"

def test_restart_cancels_waiting_approvals(monkeypatch, tmp_path):
    setup(monkeypatch, tmp_path)
    asyncio.run(P.store().add({"id": "ap_2", "project_id": "p", "owner": "@moh:amer.test", "status": "awaiting", "created_at": time.time(), "expires_at": time.time() + 10}))
    asyncio.run(P.store().cancel_waiting())
    assert asyncio.run(P.store().get("ap_2"))["status"] == "cancelled"

def test_sdk_tools_build(monkeypatch, tmp_path):
    r = setup(monkeypatch, tmp_path)
    cfg = r.mcp(); o = r.options()
    assert cfg["name"] == "amer" and "mcp__amer__send_message" in o.allowed_tools and set(o.agents) == {"researcher", "writer", "scheduler"}
    saved = asyncio.run(r.t_save({"title": "Vendor comparison", "markdown": "# Ciena vs Nokia"}))
    assert "Saved Vendor-comparison.md" in saved["content"][0]["text"] and (tmp_path / "deliverables" / "Vendor-comparison.md").read_text() == "# Ciena vs Nokia"
