"""Decision ledger. Spec acceptance tests marked [A]."""
import asyncio, hashlib, time
from fastapi import HTTPException
from fastapi.testclient import TestClient
from app import auth, db, decisions as D
from app.admin import require_admin
from app.main import app

who = {"u": "@moh:amer.test"}; members = {"!ops": {"@moh:amer.test", "@sara:amer.test", "@omar:amer.test"}}
async def fake_user(): return {"user_id": who["u"], "token": "t"}
async def member(user, room_id):
    if user["user_id"] not in members.get(room_id, set()): raise HTTPException(403, "Not a member")
async def noop(*a, **k): pass
TXT = hashlib.sha256("Go with Ciena for the Dubai ring".encode()).hexdigest()
def body(**k): return {"room_id": "!ops", "decision_id": "dec_ring1", "version": 1, "event_id": "$p1", "owner": "@sara:amer.test",
                       "due": "2026-12-01", "text_hash": TXT, "proposed_at": int(time.time() * 1000), **k}
def client(monkeypatch):
    D._mem.__init__(); app.dependency_overrides[auth.matrix_user] = fake_user; app.dependency_overrides[require_admin] = fake_user
    monkeypatch.setattr(auth, "assert_room_member", member); monkeypatch.setattr(db, "audit", noop); return TestClient(app)
def as_(u, c, b): who["u"] = u; return c.post("/v1/decisions/confirm", json=b)

def test_needs_owner_and_one_other_before_the_ledger(monkeypatch):                 # [A]
    c = client(monkeypatch)
    assert as_("@moh:amer.test", c, body()).json()["status"] == "proposed"            # another member, not the owner
    who["u"] = "@moh:amer.test"; assert c.get("/v1/decisions?room_id=!ops").json() == []
    assert as_("@sara:amer.test", c, body()).json()["status"] == "confirmed"          # the owner completes the quorum
    led = c.get("/v1/decisions?room_id=!ops").json()
    assert len(led) == 1 and led[0]["confirmed_by"] == ["@moh:amer.test", "@sara:amer.test"] and led[0]["status"] == "confirmed"

def test_owner_alone_is_not_enough_and_text_must_match(monkeypatch):
    c = client(monkeypatch)
    assert as_("@sara:amer.test", c, body()).json()["status"] == "proposed"
    other = hashlib.sha256(b"Go with Nokia").hexdigest()
    assert as_("@omar:amer.test", c, body(text_hash=other)).status_code == 409        # confirming a different text
    assert as_("@eve:amer.test", c, body()).status_code == 403                         # not in the chat

def test_proposal_older_than_72h_is_dropped(monkeypatch):
    c = client(monkeypatch)
    assert as_("@sara:amer.test", c, body(proposed_at=int((time.time() - 73 * 3600) * 1000))).status_code == 410

def test_edit_creates_v2_and_keeps_v1_visible(monkeypatch):                         # [A]
    c = client(monkeypatch)
    as_("@moh:amer.test", c, body()); as_("@sara:amer.test", c, body())
    v2 = body(version=2, event_id="$p2", supersedes=1, text_hash=hashlib.sha256(b"Go with Ciena, phase 1 only").hexdigest())
    as_("@moh:amer.test", c, v2); as_("@sara:amer.test", c, v2)
    who["u"] = "@moh:amer.test"; led = {d["version"]: d for d in c.get("/v1/decisions?room_id=!ops").json()}
    assert led[1]["status"] == "superseded" and led[2]["status"] == "confirmed" and led[2]["supersedes"] == 1

def test_status_by_owner_only_and_listing_by_owner(monkeypatch):
    c = client(monkeypatch)
    as_("@moh:amer.test", c, body()); as_("@sara:amer.test", c, body())
    who["u"] = "@moh:amer.test"; assert c.post("/v1/decisions/dec_ring1/status", json={"room_id": "!ops", "version": 1, "status": "done"}).status_code == 403
    who["u"] = "@sara:amer.test"; assert c.post("/v1/decisions/dec_ring1/status", json={"room_id": "!ops", "version": 1, "status": "done"}).json()["status"] == "done"
    mine = c.get("/v1/decisions?owner=@sara:amer.test").json(); assert mine[0]["status"] == "done"
    assert c.get("/v1/decisions?owner=@moh:amer.test").status_code == 400            # only your own

def test_tampering_breaks_verification(monkeypatch):                                 # [A]
    c = client(monkeypatch)
    as_("@moh:amer.test", c, body()); as_("@sara:amer.test", c, body())
    who["u"] = "@sara:amer.test"; c.post("/v1/decisions/dec_ring1/status", json={"room_id": "!ops", "version": 1, "status": "done"})
    assert c.get("/v1/decisions/verify").json() == {"ok": True, "checked": 2}
    D._mem.ledger[0]["due"] = "2027-06-01"                                              # someone edits a stored row
    v = c.get("/v1/decisions/verify").json(); assert v["ok"] is False and v["broken_at_seq"] == 1
