"""Feature flags: defaults, tenant overrides, '*' rows, stable percentage rollout, server-side gating."""
from fastapi.testclient import TestClient
from app import auth, db, flags as F
from app.admin import require_admin
from app.main import app

who = {"u": "@moh:amer.test"}
async def me(): return {"user_id": who["u"], "token": "t"}
async def noop(*a, **k): pass

def client(monkeypatch):
    F._mem.clear(); monkeypatch.setattr(db, "audit", noop)
    app.dependency_overrides[auth.matrix_user] = me; app.dependency_overrides[require_admin] = me
    return TestClient(app)

def test_defaults_and_overrides(monkeypatch):
    c = client(monkeypatch)
    assert c.get("/v1/flags").json()["workflows"] is True
    c.put("/v1/admin/flags", json={"tenant": "*", "feature": "workflows", "enabled": False})
    assert c.get("/v1/flags").json()["workflows"] is False
    assert c.get("/v1/workflows").status_code == 403 and "switched off" in c.get("/v1/workflows").json()["detail"]
    F._mem[("_member", "@moh:amer.test")] = {"tenant": "etisalat"}
    c.put("/v1/admin/flags", json={"tenant": "etisalat", "feature": "workflows", "enabled": True})
    assert c.get("/v1/flags").json()["workflows"] is True                      # the tenant's own row wins over '*'
    assert c.put("/v1/admin/flags", json={"tenant": "*", "feature": "nope", "enabled": True}).status_code == 422

def test_rollout_is_stable_and_proportional():
    users = [f"@u{i}:amer.test" for i in range(2000)]
    inside = [u for u in users if F.bucket(u, "search") < 30]
    assert 500 < len(inside) < 700                                              # about 30 %
    assert all(F.bucket(u, "search") < 50 for u in inside)                      # growing to 50 % keeps everyone already in

def test_push_endpoint_is_never_gated(monkeypatch):
    c = client(monkeypatch)
    c.put("/v1/admin/flags", json={"tenant": "*", "feature": "quiet_hours", "enabled": False})
    assert c.get("/v1/notify/settings").status_code == 403
    from app import notify as N
    async def fwd(b): return {"rejected": []}
    monkeypatch.setattr(N, "_forward", fwd)
    assert c.post("/_matrix/push/v1/notify", json={"notification": {"devices": [{"pushkey": "x"}]}}).status_code == 200

def test_plain_server_policy_blocks_encrypted_ai(monkeypatch):
    c = client(monkeypatch)
    from app import agents
    async def run(*a, **k): return {"answer": "ok", "agent": "Amer", "trace": []}
    async def noop2(*a, **k): pass
    monkeypatch.setattr(agents, "run", run); monkeypatch.setattr(db, "ai_request", noop2)
    assert c.post("/v1/ai/ask", json={"prompt": "hi", "context": "chat text", "encrypted": True}).status_code == 200
    c.put("/v1/admin/flags", json={"tenant": "*", "feature": "ai_plain_server", "enabled": False})
    assert c.post("/v1/ai/ask", json={"prompt": "hi", "context": "chat text", "encrypted": True}).status_code == 403
    assert c.post("/v1/ai/ask", json={"prompt": "hi"}).status_code == 200                   # not chat content: allowed
    assert c.post("/v1/ai/digest", json={"rooms": []}).status_code == 403
    assert c.get("/v1/ai/enclave/attestation").status_code == 503
