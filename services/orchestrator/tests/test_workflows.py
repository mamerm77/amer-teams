"""Workflows: validation, versioning, run pinning, dry run, rooms, http host approval. Spec acceptance tests marked [A]."""
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app import auth, db, workflows as W
from app.admin import require_admin
from app.main import app

ME = "@moh:amer.test"; rooms = {"!rfp", "!log"}; audits = []
async def fake_user(): return {"user_id": ME, "token": "t"}
async def member(user, room_id):
    if room_id not in rooms: raise HTTPException(403, "Not a member")
async def log_audit(u, a, d=""): audits.append(a)

RFP = {"name": "RFP quote approval", "trigger": {"type": "message", "room": "!rfp", "match": {"has_file": True, "keywords": ["quote"]}},
       "steps": [{"id": "s1", "type": "ask_form", "to": "$trigger.sender", "fields": ["vendor", "amount_aed"]},
                 {"id": "s2", "type": "condition", "if": "$s1.amount_aed > 500000", "then": "s3", "else": "s4"},
                 {"id": "s3", "type": "approval", "approvers": ["@cfo:amer.test"], "timeout_h": 48},
                 {"id": "s4", "type": "post", "room": "!log", "text": "Quote from {{s1.vendor}} logged"}]}

def client(monkeypatch):
    W._mem.__init__(); audits.clear(); rooms.clear(); rooms.update({"!rfp", "!log"})
    app.dependency_overrides[auth.matrix_user] = fake_user
    app.dependency_overrides[require_admin] = fake_user
    monkeypatch.setattr(auth, "assert_room_member", member); monkeypatch.setattr(db, "audit", log_audit)
    return TestClient(app)

def test_spec_example_is_valid():
    assert W.validate(RFP) == []

def test_cycle_without_wait_rejected_at_save(monkeypatch):            # [A]
    c = client(monkeypatch)
    loop = {"name": "loop", "trigger": {"type": "manual"}, "steps": [
        {"id": "a", "type": "post", "room": "!log", "text": "x"}, {"id": "b", "type": "post", "room": "!log", "text": "y", "next": "a"}]}
    r = c.post("/v1/workflows", json={"definition": loop})
    assert r.status_code == 422 and "loop without a wait" in str(r.json())
    ok = {**loop, "steps": [loop["steps"][0], {"id": "w", "type": "wait", "minutes": 60}, {"id": "b", "type": "post", "room": "!log", "text": "y", "next": "a"}]}
    assert c.post("/v1/workflows", json={"definition": ok}).status_code == 200

def test_validation_messages():
    bad = {"name": "", "trigger": {"type": "nope"}, "steps": [{"id": "s1", "type": "approval", "approvers": ["role:finance"]},
                                                              {"id": "s1", "type": "post"}]}
    e = W.validate(bad)
    assert any("name" in x for x in e) and any("Unknown trigger" in x for x in e) and any("unique id" in x for x in e)
    e = W.validate({"name": "n", "trigger": {"type": "manual"}, "steps": [{"id": "s1", "type": "approval", "approvers": ["role:finance"]},
                                                                          {"id": "s2", "type": "condition", "if": "nonsense", "then": "zz"}]})
    assert any("roles are not supported" in x for x in e) and any("condition must" in x for x in e) and any("unknown step 'zz'" in x for x in e)
    e = W.validate({"name": "n", "trigger": {"type": "manual"}, "steps": [{"id": "s1", "type": "post", "room": "!log", "text": "x", "next": "end"},
                                                                          {"id": "s2", "type": "post", "room": "!log", "text": "y"}]})
    assert any("s2: can never be reached" in x for x in e)

def test_dry_run_sends_nothing_and_branches(monkeypatch):           # [A]
    c = client(monkeypatch)
    big = c.post("/v1/workflows/dry-run", json={"definition": RFP, "sample": {"trigger": {"sender": "@sara:amer.test"}, "s1": {"vendor": "Ciena", "amount_aed": 750000}}}).json()
    assert big["sent"] == 0 and [s["step"] for s in big["steps"]] == ["s1", "s2", "s3", "s4"]
    small = c.post("/v1/workflows/dry-run", json={"definition": RFP, "sample": {"s1": {"vendor": "Nokia", "amount_aed": 1000}}}).json()
    assert [s["step"] for s in small["steps"]] == ["s1", "s2", "s4"] and "Quote from Nokia logged" in small["steps"][-1]["would"]
    assert "workflow.save" not in audits

def test_cannot_use_a_room_the_owner_left(monkeypatch):              # [A]
    c = client(monkeypatch)
    w = c.post("/v1/workflows", json={"definition": RFP, "enabled": True}).json()
    rooms.discard("!log")                                               # owner leaves #rfp-log
    assert c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "message"}}).status_code == 403
    assert c.post(f"/v1/workflows/{w['id']}/enable", json={"enabled": True}).status_code == 403
    assert c.post("/v1/workflows", json={"definition": RFP}).status_code == 403

def test_new_version_does_not_change_runs_in_progress(monkeypatch):  # [A]
    c = client(monkeypatch)
    w = c.post("/v1/workflows", json={"definition": RFP, "enabled": True}).json()
    run = c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "message", "room": "!rfp", "sender": "@sara:amer.test"}}).json()
    v2 = {**RFP, "steps": [{**RFP["steps"][3], "id": "s1", "text": "changed"}]}
    w2 = c.post("/v1/workflows", json={"definition": v2, "id": w["id"], "enabled": True}).json()
    assert w2["version"] == 2 and run["version"] == 1 and run["definition"]["steps"][0]["type"] == "ask_form"
    assert W._mem.runs[run["id"]]["version"] == 1
    assert c.get(f"/v1/workflows/{w['id']}").json()["versions"] == [1, 2]

def test_run_lifecycle_idempotency_and_metadata_only(monkeypatch):
    c = client(monkeypatch)
    w = c.post("/v1/workflows", json={"definition": RFP, "enabled": True}).json()
    h = {"Idempotency-Key": "evt-1"}
    r1 = c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "message", "body": "secret quote text"}}, headers=h).json()
    r2 = c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "message"}}, headers=h).json()
    assert r1["id"] == r2["id"] and len(W._mem.runs) == 1
    assert "body" not in W._mem.runs[r1["id"]]["trigger"]                # message text is never stored
    assert c.post(f"/v1/workflows/runs/{r1['id']}/steps", json={"step_id": "s1", "status": "succeeded", "fields": ["vendor", "amount_aed"]}).json()["ok"]
    assert W._mem.runs[r1["id"]]["step_results"]["s1"]["fields"] == ["vendor", "amount_aed"]
    c.post(f"/v1/workflows/runs/{r1['id']}/finish", json={"status": "succeeded"})
    assert c.post(f"/v1/workflows/runs/{r1['id']}/steps", json={"step_id": "s2", "status": "succeeded"}).status_code == 409
    assert "workflow.run.succeeded" in audits

def test_disabled_workflow_only_runs_manually(monkeypatch):
    c = client(monkeypatch)
    w = c.post("/v1/workflows", json={"definition": RFP}).json()
    assert c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "message"}}).status_code == 409
    assert c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "manual"}}).status_code == 200

def test_http_needs_admin_approved_host(monkeypatch):
    c = client(monkeypatch)
    d = {"name": "hook", "trigger": {"type": "manual"}, "steps": [{"id": "h", "type": "http", "url": "https://hooks.example.com/x"}]}
    w = c.post("/v1/workflows", json={"definition": d}).json()
    run = c.post(f"/v1/workflows/{w['id']}/runs", json={"trigger": {"type": "manual"}}).json()
    r = c.post(f"/v1/workflows/runs/{run['id']}/http", json={"step_id": "h"})
    assert r.status_code == 403 and "not approved" in r.json()["detail"]
    assert "hooks.example.com" in c.post("/v1/admin/workflow-hosts", json={"host": "hooks.example.com"}).json()["hosts"]

def test_conditions_and_templates():
    ctx = {"s1": {"amount_aed": "600000", "vendor": "Ciena"}, "trigger": {"sender": "@sara"}}
    assert W.evaluate("$s1.amount_aed > 500000", ctx) and not W.evaluate("$s1.amount_aed <= 500000", ctx)
    assert W.evaluate("$s1.vendor == 'Ciena'", ctx) and W.evaluate("$s1.vendor contains cie", ctx)
    assert not W.evaluate("$s1.missing > 3", ctx)
    assert W.render("From {{s1.vendor}} by {{trigger.sender}}", ctx) == "From Ciena by @sara"

def test_not_yet_available_steps_are_refused():
    e = W.validate({"name": "n", "trigger": {"type": "manual"}, "steps": [{"id": "t", "type": "create_task", "title": "x"}]})
    assert any("not available yet" in x for x in e)

def test_only_owner(monkeypatch):
    c = client(monkeypatch)
    w = c.post("/v1/workflows", json={"definition": RFP}).json()
    W._mem.wf[w["id"]][-1]["owner"] = "@other:amer.test"
    assert c.get(f"/v1/workflows/{w['id']}").status_code == 403
