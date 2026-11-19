"""Frontline shifts (docs/FRONTLINE.md). A team is a chat; its hosts (power level 50+) are its managers.

- Managers publish shifts. A person cannot hold two overlapping shifts (database exclusion constraint).
- Clock in from 15 minutes before the start until the end; clock out after clocking in.
- Swap: the assignee offers the shift, a teammate claims it, a manager approves; then it moves to the claimer, who
  must not already be on shift then.
"""
from __future__ import annotations
import datetime as dt, secrets
import psycopg
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .meetings import power_level, HOST_LEVEL

router = APIRouter()
UTC = dt.timezone.utc
def _iso(t): v = dt.datetime.fromisoformat(t.replace("Z", "+00:00")); return v if v.tzinfo else v.replace(tzinfo=UTC)
def _need():
    if db.pool is None: raise HTTPException(503, "Shifts need the database")

async def _manager(user, room_id):
    await auth.assert_room_member(user, room_id)
    if await power_level(user, room_id) < HOST_LEVEL: raise HTTPException(403, "Only the team's managers can do this")

class ShiftIn(BaseModel):
    room_id: str; user_id: str; start: str; end: str
    role: str = Field(default="", max_length=60)

@router.post("/v1/shifts")
async def create(s: ShiftIn, user=Depends(auth.matrix_user)):
    _need(); await _manager(user, s.room_id)
    a, b = _iso(s.start), _iso(s.end)
    if not (dt.timedelta(minutes=15) <= b - a <= dt.timedelta(hours=16)): raise HTTPException(422, "A shift is 15 minutes to 16 hours")
    sid = f"sh_{secrets.token_hex(5)}"
    try:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO shifts (id, room_id, user_id, during, role, created_by) VALUES (%s,%s,%s,tstzrange(%s,%s),%s,%s)", (sid, s.room_id, s.user_id, a, b, s.role, user["user_id"]))
    except psycopg.errors.ExclusionViolation: raise HTTPException(409, f"{s.user_id} already has a shift at that time")
    await db.audit(user["user_id"], "shift.create", f"{s.room_id}|{sid}"); return {"id": sid}

def _row(r):
    return dict(zip(("id", "room_id", "user_id", "start", "end", "role", "clock_in", "clock_out", "swap_state", "swap_to"),
                    (r[0], r[1], r[2], r[3].isoformat(), r[4].isoformat(), r[5], r[6] and r[6].isoformat(), r[7] and r[7].isoformat(), r[8], r[9])))
SEL = "SELECT id, room_id, user_id, lower(during), upper(during), role, clock_in, clock_out, swap_state, swap_to FROM shifts"

@router.get("/v1/shifts")
async def listing(room_id: str, start: str | None = None, end: str | None = None, user=Depends(auth.matrix_user)):
    _need(); await auth.assert_room_member(user, room_id)
    a = _iso(start) if start else dt.datetime.now(UTC) - dt.timedelta(hours=12); b = _iso(end) if end else a + dt.timedelta(days=7)
    async with db.pool.connection() as c:
        rows = await (await c.execute(SEL + " WHERE room_id=%s AND NOT cancelled AND during && tstzrange(%s,%s) ORDER BY lower(during)", (room_id, a, b))).fetchall()
    return [_row(r) for r in rows]

async def _get(sid):
    async with db.pool.connection() as c:
        r = await (await c.execute(SEL + " WHERE id=%s AND NOT cancelled", (sid,))).fetchone()
    if not r: raise HTTPException(404, "No such shift")
    return _row(r)

class Clock(BaseModel): action: str = Field(pattern="^(in|out)$")
@router.post("/v1/shifts/{sid}/clock")
async def clock(sid: str, req: Clock, user=Depends(auth.matrix_user)):
    _need(); s = await _get(sid)
    if s["user_id"] != user["user_id"]: raise HTTPException(403, "Not your shift")
    now = dt.datetime.now(UTC)
    if req.action == "in":
        if not (_iso(s["start"]) - dt.timedelta(minutes=15) <= now <= _iso(s["end"])): raise HTTPException(409, "Clock in opens 15 minutes before the start")
        q = "UPDATE shifts SET clock_in=coalesce(clock_in, now()) WHERE id=%s"
    else:
        if not s["clock_in"]: raise HTTPException(409, "Clock in first")
        q = "UPDATE shifts SET clock_out=now() WHERE id=%s"
    async with db.pool.connection() as c: await c.execute(q, (sid,))
    await db.audit(user["user_id"], f"shift.clock_{req.action}", sid); return await _get(sid)

@router.post("/v1/shifts/{sid}/offer")
async def offer(sid: str, user=Depends(auth.matrix_user)):
    _need(); s = await _get(sid)
    if s["user_id"] != user["user_id"]: raise HTTPException(403, "Not your shift")
    if s["clock_in"]: raise HTTPException(409, "You have already clocked in")
    async with db.pool.connection() as c: await c.execute("UPDATE shifts SET swap_state='offered', swap_to=NULL WHERE id=%s", (sid,))
    return await _get(sid)

@router.post("/v1/shifts/{sid}/claim")
async def claim(sid: str, user=Depends(auth.matrix_user)):
    _need(); s = await _get(sid); await auth.assert_room_member(user, s["room_id"])
    if s["swap_state"] != "offered": raise HTTPException(409, "This shift is not on offer")
    if s["user_id"] == user["user_id"]: raise HTTPException(409, "It is already yours")
    async with db.pool.connection() as c: await c.execute("UPDATE shifts SET swap_state='claimed', swap_to=%s WHERE id=%s", (user["user_id"], sid))
    return await _get(sid)

class Decide(BaseModel): approve: bool
@router.post("/v1/shifts/{sid}/decide")
async def decide(sid: str, req: Decide, user=Depends(auth.matrix_user)):
    _need(); s = await _get(sid); await _manager(user, s["room_id"])
    if s["swap_state"] != "claimed": raise HTTPException(409, "No claim to decide")
    try:
        async with db.pool.connection() as c:
            if req.approve: await c.execute("UPDATE shifts SET user_id=swap_to, swap_state='none', swap_to=NULL WHERE id=%s", (sid,))
            else: await c.execute("UPDATE shifts SET swap_state='offered', swap_to=NULL WHERE id=%s", (sid,))
    except psycopg.errors.ExclusionViolation: raise HTTPException(409, f"{s['swap_to']} already has a shift at that time")
    await db.audit(user["user_id"], f"shift.swap_{'approve' if req.approve else 'decline'}", sid); return await _get(sid)

@router.delete("/v1/shifts/{sid}")
async def cancel(sid: str, user=Depends(auth.matrix_user)):
    _need(); s = await _get(sid); await _manager(user, s["room_id"])
    async with db.pool.connection() as c: await c.execute("UPDATE shifts SET cancelled=true WHERE id=%s", (sid,))
    return {"cancelled": True}
