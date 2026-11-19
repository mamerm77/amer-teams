"""Quiet hours filter between Synapse and Sygnal."""
from datetime import datetime
from zoneinfo import ZoneInfo
from fastapi.testclient import TestClient
from app import auth, db, notify as N
from app.main import app

D = ZoneInfo("Asia/Dubai")
def at(h, m=0, day=23): return datetime(2026, 11, day, h, m, tzinfo=D)       # 23 Nov 2026 is a Monday

def test_quiet_hours_over_midnight_and_days():
    q = N.Quiet(enabled=True, start="22:00", end="07:00", days=[0, 1, 2, 3])     # Mon–Thu evenings
    assert N.in_quiet(q, at(23)) and N.in_quiet(q, at(6, 59, day=24))          # Mon night, early Tue
    assert not N.in_quiet(q, at(7, 0, day=24)) and not N.in_quiet(q, at(21, 59))
    assert not N.in_quiet(q, at(23, day=27))                                    # Friday evening: not a quiet day
    assert N.in_quiet(q, at(3, day=27))                                         # early Friday belongs to Thursday night
    assert not N.in_quiet(N.Quiet(enabled=False), at(23))
    assert N.in_quiet(N.Quiet(enabled=True, start="12:00", end="13:00"), at(12, 30)) and not N.in_quiet(N.Quiet(enabled=True, start="12:00", end="13:00"), at(13))

def test_hold_rules():
    s = N.Settings(quiet=N.Quiet(enabled=True, start="22:00", end="07:00"), priority_senders=["@boss:amer.test"])
    assert N.hold(s, "@sara:amer.test", "low", at(23))
    assert not N.hold(s, "@boss:amer.test", "low", at(23))                     # priority sender
    assert not N.hold(s, "@sara:amer.test", "high", at(23))                    # mention or call
    assert N.hold(N.Settings(quiet=N.Quiet(enabled=True, start="22:00", end="07:00", allow_high=False)), "@sara:amer.test", "high", at(23))
    assert not N.hold(s, "@sara:amer.test", "low", at(12))

def test_filter_forwards_ids_only_and_never_rejects_held(monkeypatch):
    N._mem.clear(); sent = []
    async def fwd(body): sent.append(body); return {"rejected": []}
    async def me(): return {"user_id": "@moh:amer.test", "token": "t"}
    async def noop(*a, **k): pass
    monkeypatch.setattr(N, "_forward", fwd); monkeypatch.setattr(db, "audit", noop)
    app.dependency_overrides[auth.matrix_user] = me
    c = TestClient(app)
    always = {"enabled": True, "start": "00:00", "end": "23:59", "allow_high": True}
    assert c.put("/v1/notify/settings", json={"quiet": always, "pushkeys": ["PK_MOH"], "priority_senders": ["@boss:amer.test"]}).status_code == 200
    push = lambda sender, prio, keys: c.post("/_matrix/push/v1/notify", json={"notification": {"event_id": "$e", "room_id": "!r", "sender": sender, "prio": prio,
        "type": "m.room.encrypted", "content": {"ciphertext": "x"}, "counts": {"unread": 2}, "devices": [{"app_id": "a", "pushkey": k} for k in keys]}}).json()
    assert push("@sara:amer.test", "low", ["PK_MOH"]) == {"rejected": []} and sent == []              # held, not rejected
    push("@sara:amer.test", "low", ["PK_MOH", "PK_OTHER"])                                          # another user's device still gets it
    assert [d["pushkey"] for d in sent[-1]["notification"]["devices"]] == ["PK_OTHER"]
    assert set(sent[-1]["notification"]) == {"event_id", "room_id", "counts", "prio", "devices"}   # no sender, type or content leaves
    push("@boss:amer.test", "low", ["PK_MOH"]); assert sent[-1]["notification"]["devices"][0]["pushkey"] == "PK_MOH"
    # a second device adds its key without dropping the first
    c.put("/v1/notify/settings", json={"quiet": always, "pushkeys": ["PK_MOH_2"]})
    assert set(c.get("/v1/notify/settings").json()["pushkeys"]) == {"PK_MOH", "PK_MOH_2"}
