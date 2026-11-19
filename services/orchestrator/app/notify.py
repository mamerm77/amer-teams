"""Notification quiet hours and priority senders (docs/NOTIFICATIONS.md).

Synapse sends each push to this filter (the pusher URL ends in /_matrix/push/v1/notify, as Synapse requires).
For each device in the push, the filter looks up its owner's settings. It holds the push during their quiet hours,
unless the sender is a priority sender, or it is a mention or call (Synapse marks those prio "high") and the
user allows those. It forwards the rest to Sygnal with event and room ids only: no sender, no content. The
message itself is fetched and decrypted on the phone.

Held pushes are not lost: the messages are in the chat and in the unread counts when the person opens the app.
"""
from __future__ import annotations
import json, os, time
from datetime import datetime
from zoneinfo import ZoneInfo
import httpx
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from . import auth, db, flags

router = APIRouter()
SYGNAL = os.getenv("SYGNAL_URL", "http://sygnal:5000/_matrix/push/v1/notify")

class Quiet(BaseModel):
    enabled: bool = False
    start: str = Field(default="22:00", pattern=r"^\d{2}:\d{2}$")
    end: str = Field(default="07:00", pattern=r"^\d{2}:\d{2}$")
    days: list[int] = [0, 1, 2, 3, 4, 5, 6]          # Monday = 0; the day the quiet period starts
    tz: str = "Asia/Dubai"
    allow_high: bool = True                           # mentions, direct messages and calls still come through

class Settings(BaseModel):
    quiet: Quiet = Quiet()
    priority_senders: list[str] = Field(default=[], max_length=50)
    pushkeys: list[str] = Field(default=[], max_length=20)   # this user's devices' push keys (so the filter knows whose they are)
    focus_until: float = 0                              # focus session (docs/FOCUS.md): epoch seconds; only priority senders come through

def in_quiet(q: Quiet, now: datetime | None = None) -> bool:
    if not q.enabled: return False
    t = (now or datetime.now(ZoneInfo(q.tz))).astimezone(ZoneInfo(q.tz))
    m = t.hour * 60 + t.minute
    s = int(q.start[:2]) * 60 + int(q.start[3:]); e = int(q.end[:2]) * 60 + int(q.end[3:])
    if s == e: return False
    if s < e: return t.weekday() in q.days and s <= m < e
    # over midnight: the evening part belongs to today, the early part to the day before
    return (m >= s and t.weekday() in q.days) or (m < e and (t.weekday() - 1) % 7 in q.days)

def hold(st: Settings, sender: str | None, prio: str | None, now: datetime | None = None) -> bool:
    t = (now or datetime.now(ZoneInfo('UTC'))).timestamp()
    if st.focus_until > t:                            # focus: even mentions wait; priority senders still come through
        return not (sender and sender in st.priority_senders)
    if not in_quiet(st.quiet, now): return False
    if sender and sender in st.priority_senders: return False
    if st.quiet.allow_high and prio == "high": return False
    return True

_mem: dict[str, dict] = {}                            # user -> settings (tests / no database)
async def _save(user: str, s: Settings):
    if db.pool is None: _mem[user] = s.model_dump(); return
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO notify_settings (user_id, data, updated_at) VALUES (%s,%s,now()) ON CONFLICT (user_id) DO UPDATE SET data=EXCLUDED.data, updated_at=now()",
                        (user, s.model_dump_json()))
async def _load(user: str) -> Settings:
    if db.pool is None: return Settings(**_mem.get(user, {}))
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT data FROM notify_settings WHERE user_id=%s", (user,))).fetchone()
    return Settings(**(r[0] if isinstance(r[0], dict) else json.loads(r[0]))) if r else Settings()
async def _owner(pushkey: str) -> tuple[str, Settings] | None:
    if db.pool is None:
        for u, d in _mem.items():
            if pushkey in d.get("pushkeys", []): return u, Settings(**d)
        return None
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT user_id, data FROM notify_settings WHERE data->'pushkeys' ? %s", (pushkey,))).fetchone()
    return (r[0], Settings(**(r[1] if isinstance(r[1], dict) else json.loads(r[1])))) if r else None

class Focus(BaseModel):
    minutes: int = Field(ge=0, le=480)                  # 0 ends the session

@router.post("/v1/notify/focus")
async def focus(req: Focus, user=Depends(flags.require("quiet_hours"))):
    st = await _load(user["user_id"])
    st.focus_until = time.time() + req.minutes * 60 if req.minutes else 0
    await _save(user["user_id"], st)
    return {"focus_until": st.focus_until}

@router.get("/v1/notify/settings")
async def get_settings(user=Depends(flags.require("quiet_hours"))): return (await _load(user["user_id"])).model_dump()

@router.put("/v1/notify/settings")
async def put_settings(req: Settings, user=Depends(flags.require("quiet_hours"))):
    try: ZoneInfo(req.quiet.tz)
    except Exception: raise HTTPException(422, f"Unknown time zone {req.quiet.tz}")
    cur = await _load(user["user_id"])
    req.pushkeys = sorted(set(cur.pushkeys) | set(req.pushkeys))[-20:]       # devices are added, never dropped by another device
    await _save(user["user_id"], req); await db.audit(user["user_id"], "notify.settings", f"quiet={req.quiet.enabled} priority={len(req.priority_senders)}")
    return req.model_dump()

async def _forward(body: dict) -> dict:
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.post(SYGNAL, json=body)
    return r.json() if r.status_code == 200 else {"rejected": []}

@router.post("/_matrix/push/v1/notify")
async def notify(request: Request):
    """Called by Synapse. Never reports a held device as rejected (that would delete its pusher)."""
    n = (await request.json()).get("notification", {})
    sender, prio = n.get("sender"), n.get("prio")
    keep = []
    for d in n.get("devices", []):
        o = await _owner(d.get("pushkey", ""))
        if o and hold(o[1], sender, prio): continue
        keep.append(d)
    if not keep: return {"rejected": []}
    slim = {k: n[k] for k in ("event_id", "room_id", "counts", "prio", "id") if k in n}        # event_id_only: nothing else leaves
    return await _forward({"notification": {**slim, "devices": keep}})
