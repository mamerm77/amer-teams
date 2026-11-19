"""Guests and webinars without a database (in-memory path)."""
import pytest
from fastapi.testclient import TestClient
from app import main, guests, auth

@pytest.fixture
def c(monkeypatch):
    async def host(user, room_id): return None
    monkeypatch.setattr(guests, "_host", host)
    async def audit(*a, **k): return None
    monkeypatch.setattr(guests.db, "audit", audit)
    main.app.dependency_overrides[auth.matrix_user] = lambda: {"user_id": "@h:x", "token": "t"}
    guests._mem.update(links={}, webinars={}, regs={})
    yield TestClient(main.app)
    main.app.dependency_overrides.clear()

def test_guest_link_and_join(c):
    r = c.post("/v1/guests/links", json={"room_id": "!r:x", "call_id": "meet-!r:x"}).json()
    j = c.post("/v1/guests/join", json={"code": r["code"], "name": "Sara <b>"}).json()
    assert j["identity"].startswith("guest-") and not j["attendee"] and j["token"]
    import jwt; claims = jwt.decode(j["token"], options={"verify_signature": False})
    assert claims["name"] == "Sara b (guest)" and claims["video"]["canPublish"]
    assert c.post("/v1/guests/join", json={"code": "x" * 20, "name": "a"}).status_code == 403

def test_webinar_registration_gives_attendee_link(c):
    w = c.post("/v1/webinars", json={"room_id": "!r:x", "call_id": "meet-!r:x", "title": "Town hall"}).json()
    assert c.get(f"/v1/webinars/public/{w['slug']}").json()["open"]
    reg = c.post(f"/v1/webinars/public/{w['slug']}/register", json={"name": "Ali", "email": "ali@example.com"}).json()
    assert c.post(f"/v1/webinars/public/{w['slug']}/register", json={"name": "Ali", "email": "bad"}).status_code == 422
    j = c.post("/v1/guests/join", json={"code": reg["code"], "name": "ignored"}).json()
    import jwt; claims = jwt.decode(j["token"], options={"verify_signature": False})
    assert j["attendee"] and not claims["video"]["canPublish"] and claims["name"] == "Ali (guest)"
    assert [r["email"] for r in c.get(f"/v1/webinars/{w['slug']}/registrations").json()["registrations"]] == ["ali@example.com"]
    c.post(f"/v1/webinars/{w['slug']}/close")
    assert c.post(f"/v1/webinars/public/{w['slug']}/register", json={"name": "B", "email": "b@example.com"}).status_code == 404

def test_join_page_served(c):
    assert "Join the meeting" in c.get("/join").text
    assert c.get("/join/join.js").status_code == 200 and c.get("/join/secret.py").status_code == 404
