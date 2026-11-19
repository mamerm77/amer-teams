"""Meeting rooms, booking and room devices (docs/ROOMS.md).

- Rooms: name, site, capacity, equipment. Bookings cannot overlap (a database exclusion constraint, so two people
  booking the same slot at the same moment cannot both win).
- Check-in: a booking that nobody checks in to within 10 minutes of its start is released, so the room shows free.
- Room device: a tablet outside (or inside) the room, paired with a one-time code, shows today's schedule, checks
  people in and books the room now for 15-60 minutes. It sees titles only when the organiser chose to show them.
"""
from __future__ import annotations
import datetime as dt, hashlib, hmac, json, secrets
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .admin import require_admin

router = APIRouter()
NO_SHOW_MIN = 10
UTC = dt.timezone.utc
_h = lambda s: hashlib.sha256(s.encode()).hexdigest()

def _need_db():
    if db.pool is None: raise HTTPException(503, "Room booking needs the database")

class RoomIn(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    site: str = Field(default="", max_length=60)
    capacity: int = Field(default=6, ge=1, le=500)
    equipment: list[str] = Field(default=[], max_length=20)

@router.post("/v1/rooms")
async def add_room(r: RoomIn, user=Depends(require_admin)):
    _need_db(); rid = f"rm_{secrets.token_hex(4)}"
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO meeting_rooms (id, name, site, capacity, equipment) VALUES (%s,%s,%s,%s,%s)", (rid, r.name, r.site, r.capacity, json.dumps(r.equipment)))
    await db.audit(user["user_id"], "room.add", rid); return {"id": rid, **r.model_dump()}

@router.post("/v1/rooms/{rid}/pair")
async def pair(rid: str, user=Depends(require_admin)):
    """A one-time code to type on the room's tablet. Pairing again replaces the old device."""
    _need_db(); code = secrets.token_urlsafe(9)
    async with db.pool.connection() as c:
        r = await c.execute("UPDATE meeting_rooms SET device_hash=%s WHERE id=%s", (_h(code), rid))
        if not r.rowcount: raise HTTPException(404, "No such room")
    await db.audit(user["user_id"], "room.pair", rid); return {"device_code": code}

async def _release_no_shows(c):
    await c.execute("UPDATE room_bookings SET released_at=now() WHERE released_at IS NULL AND checked_in_at IS NULL AND lower(during) < now() - make_interval(mins => %s)", (NO_SHOW_MIN,))

def _iso(t: str) -> dt.datetime:
    v = dt.datetime.fromisoformat(t.replace("Z", "+00:00")); return v if v.tzinfo else v.replace(tzinfo=UTC)

@router.get("/v1/rooms")
async def rooms(start: str | None = None, end: str | None = None, capacity: int = 1, user=Depends(auth.matrix_user)):
    """Rooms with their bookings in the window (default: the next 12 hours) and whether each is free for all of it."""
    _need_db()
    s = _iso(start) if start else dt.datetime.now(UTC); e = _iso(end) if end else s + dt.timedelta(hours=12)
    async with db.pool.connection() as c:
        await _release_no_shows(c)
        rs = await (await c.execute("SELECT id, name, site, capacity, equipment FROM meeting_rooms WHERE active AND capacity >= %s ORDER BY site, name", (capacity,))).fetchall()
        bs = await (await c.execute("SELECT id, room_id, lower(during), upper(during), organiser, title, show_title, checked_in_at FROM room_bookings WHERE released_at IS NULL AND during && tstzrange(%s, %s) ORDER BY lower(during)", (s, e))).fetchall()
    out = []
    for rid, name, site, cap, eq in rs:
        mine = [{"id": b[0], "start": b[2].isoformat(), "end": b[3].isoformat(), "organiser": b[4], "title": b[5] if (b[6] or b[4] == user["user_id"]) else "Booked",
                 "checked_in": b[7] is not None} for b in bs if b[1] == rid]
        out.append({"id": rid, "name": name, "site": site, "capacity": cap, "equipment": eq if isinstance(eq, list) else json.loads(eq), "bookings": mine, "free": not mine})
    return out

class BookIn(BaseModel):
    room_id: str
    start: str
    end: str
    title: str = Field(default="", max_length=120)
    show_title: bool = False
    chat_room: str | None = None

async def _book(room_id, s, e, organiser, title="", show_title=False, chat_room=None, checked_in=False):
    if e <= s or e - s > dt.timedelta(hours=12): raise HTTPException(422, "A booking is between 1 minute and 12 hours")
    if e < dt.datetime.now(UTC): raise HTTPException(422, "That time has passed")
    bid = f"bk_{secrets.token_hex(5)}"
    import psycopg
    try:
        async with db.pool.connection() as c:
            await _release_no_shows(c)
            await c.execute("INSERT INTO room_bookings (id, room_id, during, organiser, title, show_title, chat_room, checked_in_at) VALUES (%s,%s,tstzrange(%s,%s),%s,%s,%s,%s," + ("now()" if checked_in else "NULL") + ")",
                            (bid, room_id, s, e, organiser, title, show_title, chat_room))
    except psycopg.errors.ExclusionViolation: raise HTTPException(409, "That room is already booked for part of this time")
    except psycopg.errors.ForeignKeyViolation: raise HTTPException(404, "No such room")
    return bid

@router.post("/v1/rooms/bookings")
async def book(req: BookIn, user=Depends(auth.matrix_user)):
    _need_db(); s, e = _iso(req.start), _iso(req.end)
    bid = await _book(req.room_id, s, e, user["user_id"], req.title, req.show_title, req.chat_room)
    await db.audit(user["user_id"], "room.book", f"{req.room_id}|{bid}"); return {"id": bid}

@router.delete("/v1/rooms/bookings/{bid}")
async def cancel(bid: str, user=Depends(auth.matrix_user)):
    _need_db()
    async with db.pool.connection() as c:
        r = await c.execute("UPDATE room_bookings SET released_at=now() WHERE id=%s AND organiser=%s AND released_at IS NULL", (bid, user["user_id"]))
    if not r.rowcount: raise HTTPException(404, "Not your booking")
    return {"released": True}

@router.post("/v1/rooms/bookings/{bid}/check-in")
async def check_in(bid: str, user=Depends(auth.matrix_user)):
    _need_db(); return await _checkin(bid)

async def _checkin(bid, room_id=None):
    async with db.pool.connection() as c:
        r = await (await c.execute("UPDATE room_bookings SET checked_in_at=coalesce(checked_in_at, now()) WHERE id=%s AND released_at IS NULL AND (%s::text IS NULL OR room_id=%s) "
                                   "AND now() BETWEEN lower(during) - interval '15 minutes' AND upper(during) RETURNING id", (bid, room_id, room_id))).fetchone()
    if not r: raise HTTPException(409, "Check-in opens 15 minutes before the start and closes at the end")
    return {"checked_in": True}

# ---------- the room's own device ----------
async def _device_room(code: str) -> str:
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT id FROM meeting_rooms WHERE device_hash=%s AND active", (_h(code),))).fetchone()
    if not r: raise HTTPException(401, "This device is not paired with a room")
    return r[0]

@router.get("/v1/room-device/today")
async def device_today(x_room_device: str = Header("")):
    _need_db(); rid = await _device_room(x_room_device)
    now = dt.datetime.now(UTC); day_end = now.replace(hour=23, minute=59)
    async with db.pool.connection() as c:
        await _release_no_shows(c)
        name = (await (await c.execute("SELECT name, site, capacity FROM meeting_rooms WHERE id=%s", (rid,))).fetchone())
        bs = await (await c.execute("SELECT id, lower(during), upper(during), title, show_title, checked_in_at FROM room_bookings WHERE room_id=%s AND released_at IS NULL AND during && tstzrange(%s, %s) ORDER BY lower(during)",
                                    (rid, now - dt.timedelta(hours=1), day_end))).fetchall()
    items = [{"id": b, "start": s.isoformat(), "end": e.isoformat(), "title": t if show else "Booked", "checked_in": ci is not None} for b, s, e, t, show, ci in bs]
    current = next((i for i in items if _iso(i["start"]) <= now < _iso(i["end"])), None)
    return {"room": {"id": rid, "name": name[0], "site": name[1], "capacity": name[2]}, "now": now.isoformat(), "current": current,
            "next": next((i for i in items if _iso(i["start"]) > now), None), "today": items, "free": current is None}

@router.post("/v1/room-device/check-in/{bid}")
async def device_check_in(bid: str, x_room_device: str = Header("")):
    _need_db(); return await _checkin(bid, await _device_room(x_room_device))

class Now(BaseModel): minutes: int = Field(ge=15, le=60)
@router.post("/v1/room-device/book-now")
async def device_book_now(req: Now, x_room_device: str = Header("")):
    _need_db(); rid = await _device_room(x_room_device); s = dt.datetime.now(UTC)
    bid = await _book(rid, s, s + dt.timedelta(minutes=req.minutes), "@room-device", "Booked at the room", True, None, checked_in=True)
    await db.audit("@room-device", "room.book_now", f"{rid}|{bid}"); return {"id": bid}
