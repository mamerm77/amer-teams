"""Notification quiet hours and priority senders (docs/NOTIFICATIONS.md).

Synapse sends each push to this filter (the pusher URL ends in /_matrix/push/v1/notify, as Synapse requires).
For each device in the push, the filter looks up its owner's settings. It holds the push during their quiet hours,
unless the sender is a priority sender, or it is a mention or call (Synapse marks those prio "high") and the
user allows those. It forwards the rest to Sygnal with event and room ids only: no sender, no content. The
message itself is fetched and decrypted on the phone.

Held pushes are not lost: the messages are in the chat and in the unread counts when the person opens the app.
"""
from __future__ import annotations
import os, asyncio
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
    minutes: int = Field(ge=0, le=10080)                # 0 ends the session; up to a week (Do not disturb until changed)

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
        if o: await _track(o[0], n)
        if o and hold(o[1], sender, prio): continue
        keep.append(d)
    if not keep: return {"rejected": []}
    slim = {k: n[k] for k in ("event_id", "room_id", "counts", "prio", "id") if k in n}        # event_id_only: nothing else leaves
    return await _forward({"notification": {**slim, "devices": keep}})


# ---------- missed activity email (Teams parity) ----------
async def _track(user: str, n: dict):
    """Latest unread count per chat, from the push Synapse sends (also when the count drops to 0 after reading)."""
    rid = n.get("room_id"); unread = int((n.get("counts") or {}).get("unread", 0))
    if not rid or db.pool is None: return
    try:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO missed_activity (user_id, room_id, unread, last_at) VALUES (%s,%s,%s,now()) ON CONFLICT (user_id, room_id) DO UPDATE SET unread=EXCLUDED.unread, last_at=now()",
                            (user, rid, unread))
    except Exception: pass

class MissedEmail(BaseModel): frequency: str

@router.get("/v1/notify/missed-email")
async def get_missed(user=Depends(auth.matrix_user)):
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT frequency FROM missed_email WHERE user_id=%s", (user["user_id"],))).fetchone()
    return {"frequency": r[0] if r else "hourly", "email_configured": bool(os.getenv("SMTP_HOST"))}

@router.put("/v1/notify/missed-email")
async def set_missed(req: MissedEmail, user=Depends(auth.matrix_user)):
    if req.frequency not in ("off", "hourly", "daily"): raise HTTPException(422, "frequency: off, hourly or daily")
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO missed_email (user_id, frequency) VALUES (%s,%s) ON CONFLICT (user_id) DO UPDATE SET frequency=EXCLUDED.frequency", (user["user_id"], req.frequency))
    return {"ok": True}

async def missed_due() -> list[tuple[str, str, int, int]]:
    """(user, email, chats, messages) for people with unread activity older than an hour, not emailed within their period."""
    async with db.pool.connection() as c:
        rows = await (await c.execute(
            "SELECT a.user_id, p.email, count(*), sum(a.unread) FROM missed_activity a JOIN people_profile p ON p.user_id=a.user_id "
            "LEFT JOIN missed_email m ON m.user_id=a.user_id "
            "WHERE a.unread > 0 AND a.last_at < now() - interval '1 hour' AND p.email IS NOT NULL AND coalesce(m.frequency,'hourly') <> 'off' "
            "AND (m.last_sent IS NULL OR m.last_sent < now() - CASE WHEN m.frequency='daily' THEN interval '1 day' ELSE interval '1 hour' END) "
            "GROUP BY a.user_id, p.email")).fetchall()
    return [(u, e, int(n), int(m)) for u, e, n, m in rows]

async def missed_loop():
    from .people import _mail, _base
    while True:
        await asyncio.sleep(900)
        try:
            for user, email, chats, msgs in await missed_due():
                ok = await _mail(email, f"You have {msgs} unread message{'s' if msgs != 1 else ''} in Amer Teams",
                                 f"While you were away, {msgs} message{'s' if msgs != 1 else ''} arrived in {chats} chat{'s' if chats != 1 else ''}.\n"
                                 f"Open Amer Teams to read them: {_base()}\n\nMessages are end-to-end encrypted, so this email cannot show them.\n"
                                 "Change how often you get these in the app: Notifications → Missed activity emails.")
                async with db.pool.connection() as c:
                    await c.execute("INSERT INTO missed_email (user_id, last_sent) VALUES (%s, now()) ON CONFLICT (user_id) DO UPDATE SET last_sent=now()", (user,))
                if not ok: break                                         # no SMTP: stop until it is configured
        except Exception: pass
