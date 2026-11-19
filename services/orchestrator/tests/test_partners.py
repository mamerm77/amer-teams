"""Partner organisations: state machine, handshake, the module's list, and the Synapse module's decisions."""
import asyncio, importlib.util, pathlib
from fastapi.testclient import TestClient
from app import auth, db, partners as P
from app.admin import require_admin
from app.main import app

async def admin(): return {"user_id": "@admin:amer.test", "token": "t"}
async def noop(*a, **k): pass
def client(monkeypatch):
    P._mem.clear(); monkeypatch.setattr(db, "audit", noop); monkeypatch.setattr(P, "MODULE_SECRET", "s3cret")
    app.dependency_overrides[require_admin] = admin; return TestClient(app)
allowed = lambda c: c.get("/v1/federation/allowed", headers={"X-Amer-Federation": "s3cret"}).json()["servers"]

def test_lifecycle_and_list(monkeypatch):
    c = client(monkeypatch)
    r = c.post("/v1/admin/partners", json={"server": "partner.test", "note": "Vendor"}).json()
    assert r["state"] == "approved_by_us" and len(r["code"]) > 10 and allowed(c) == []       # one side only: not yet
    assert c.post("/v1/federation/handshake", json={"server": "partner.test", "code": "wrong-code-123"}).status_code == 403
    assert c.post("/v1/federation/handshake", json={"server": "partner.test", "code": r["code"]}).json()["state"] == "active"
    assert allowed(c) == ["partner.test"]
    assert c.post("/v1/federation/handshake", json={"server": "partner.test", "code": r["code"]}).status_code == 403          # one-time
    c.post("/v1/admin/partners/partner.test", json={"action": "suspend"}); assert allowed(c) == []
    c.post("/v1/admin/partners/partner.test", json={"action": "resume"}); assert allowed(c) == ["partner.test"]
    c.post("/v1/admin/partners/partner.test", json={"action": "disconnect"}); assert allowed(c) == []
    assert c.post("/v1/admin/partners/partner.test", json={"action": "resume"}).status_code == 409

def test_manual_confirmation_and_secret(monkeypatch):
    c = client(monkeypatch)
    c.post("/v1/admin/partners", json={"server": "plainmatrix.example:8448"})
    assert c.post("/v1/admin/partners/plainmatrix.example:8448", json={"action": "confirmed"}).json()["state"] == "active"
    assert c.get("/v1/federation/allowed", headers={"X-Amer-Federation": "nope"}).status_code == 401
    assert c.post("/v1/admin/partners", json={"server": "Bad Server!"}).status_code == 422

def _module():
    spec = importlib.util.spec_from_file_location("amer_federation", pathlib.Path(__file__).resolve().parents[3] / "deploy" / "synapse-modules" / "amer_federation.py")
    m = importlib.util.module_from_spec(spec); spec.loader.exec_module(m); return m

class FakeApi:
    server_name = "amer.test"
    def __init__(self, servers): self.servers = servers; self.calls = 0; self.cb = {}
    def register_third_party_rules_callbacks(self, **k): self.cb = k
    def register_spam_checker_callbacks(self, **k): self.spam = k
    @property
    def http_client(self):
        outer = self
        class H:
            async def get_json(self, url, headers=None):
                outer.calls += 1
                if outer.servers is None: raise ConnectionError("orchestrator down")
                return {"servers": outer.servers}
        return H()

class Ev:
    def __init__(self, sender): self.sender = sender

def test_synapse_module_refuses_non_partners_and_keeps_rooms_local():
    m = _module(); api = FakeApi(["partner.test"]); mod = m.AmerFederation({"secret": "s"}, api)
    run = lambda e: asyncio.run(mod.check_event_allowed(Ev(e), {}))[0]
    assert run("@moh:amer.test") and run("@sara:partner.test") and not run("@eve:stranger.test")
    assert asyncio.run(mod.check_event_for_spam(Ev("@sara:partner.test"))) == "NOT_SPAM" and asyncio.run(mod.check_event_for_spam(Ev("@eve:stranger.test"))) != "NOT_SPAM"
    content = {"initial_state": []}; asyncio.run(mod.on_create_room(None, content, False)); assert content["creation_content"]["m.federate"] is False
    shared = {"initial_state": [{"type": "com.amerteams.shared", "state_key": "", "content": {"partners": ["partner.test"]}}]}
    asyncio.run(mod.on_create_room(None, shared, False)); assert shared["creation_content"]["m.federate"] is True

def test_module_with_orchestrator_down_accepts_nothing_new():
    m = _module(); api = FakeApi(None); mod = m.AmerFederation({}, api)
    assert asyncio.run(mod.check_event_allowed(Ev("@sara:partner.test"), {}))[0] is False
