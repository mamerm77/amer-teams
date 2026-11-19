"""Phone dial-in to meetings and inbound call handling (docs/PHONE_DIALIN.md).

Ordinary phones cannot take part in end-to-end encryption, so a phone never joins an encrypted meeting directly.
A host opens a *phone bridge* for a meeting: a separate, clearly labelled media room reached by the trunk's number
and a 6-digit PIN (LiveKit SIP dispatch rule with a PIN). People in the app who want to talk with phone callers join
the bridge too; the app says it is encrypted to the phone network, not end to end.

Inbound calls to the company number (rooms "phone-in-<caller>") are announced by LiveKit's webhook; the app's
hunt group sees them in the Phone line view and the first to press Answer gets the call (atomic in the database).
"""
from __future__ import annotations
import hashlib, secrets
from fastapi import APIRouter, Depends, HTTPException
from livekit import api as lkapi
from pydantic import BaseModel
from . import auth, config, db, livekit_token
from .admin import require_admin
from .meetings import power_level, HOST_LEVEL
from .sip import _lk, mask

router = APIRouter(prefix="/v1/phone")

async def _inbound_trunk():
    async with _lk() as lk:
        items = (await lk.sip.list_sip_inbound_trunk(lkapi.ListSIPInboundTrunkRequest())).items
    if not items: raise HTTPException(503, "No phone line (inbound SIP trunk) is configured yet")
    return items[0].sip_trunk_id, (list(items[0].numbers) or ["?"])[0]

class Bridge(BaseModel): room_id: str

@router.post("/dialin")
async def open_bridge(req: Bridge, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, req.room_id)
    if await power_level(user, req.room_id) < HOST_LEVEL: raise HTTPException(403, "Only a meeting host can open phone dial-in")
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT livekit_room, pin, number FROM phone_bridges WHERE room_id=%s", (req.room_id,))).fetchone()
    if r: return {"number": r[2], "pin": r[1], "livekit_room": r[0], "security": "Encrypted to the phone network (TLS + SRTP), not end-to-end"}
    trunk, number = await _inbound_trunk()
    lkroom = f"phone-meet-{hashlib.sha256(req.room_id.encode()).hexdigest()[:16]}"
    pin = f"{secrets.randbelow(900000) + 100000}"
    async with _lk() as lk:
        rule = await lk.sip.create_sip_dispatch_rule(lkapi.CreateSIPDispatchRuleRequest(trunk_ids=[trunk], name=f"dial-in {lkroom}",
            rule=lkapi.SIPDispatchRule(dispatch_rule_direct=lkapi.SIPDispatchRuleDirect(room_name=lkroom, pin=pin))))
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO phone_bridges (room_id, livekit_room, pin, dispatch_rule_id, number, created_by) VALUES (%s,%s,%s,%s,%s,%s)",
                        (req.room_id, lkroom, pin, rule.sip_dispatch_rule_id, number, user["user_id"]))
    await db.audit(user["user_id"], "phone.dialin.open", req.room_id)
    return {"number": number, "pin": pin, "livekit_room": lkroom, "security": "Encrypted to the phone network (TLS + SRTP), not end-to-end"}

@router.delete("/dialin/{room_id}")
async def close_bridge(room_id: str, user=Depends(auth.matrix_user)):
    if await power_level(user, room_id) < HOST_LEVEL: raise HTTPException(403, "Only a meeting host can close phone dial-in")
    async with db.pool.connection() as c:
        r = await (await c.execute("DELETE FROM phone_bridges WHERE room_id=%s RETURNING dispatch_rule_id", (room_id,))).fetchone()
    if r:
        async with _lk() as lk: await lk.sip.delete_sip_dispatch_rule(lkapi.DeleteSIPDispatchRuleRequest(sip_dispatch_rule_id=r[0]))
    await db.audit(user["user_id"], "phone.dialin.close", room_id); return {"closed": bool(r)}

@router.post("/dialin/{room_id}/join")
async def join_bridge(room_id: str, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, room_id)
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT livekit_room FROM phone_bridges WHERE room_id=%s", (room_id,))).fetchone()
    if not r: raise HTTPException(404, "Phone dial-in is not open for this meeting")
    return {"url": config.LIVEKIT_PUBLIC_URL, "token": livekit_token.sign(user["user_id"], user["user_id"], r[0]), "e2ee": "not-possible",
            "security": "Encrypted to the phone network (TLS + SRTP), not end-to-end"}

# ---------- inbound: hunt group ----------
class Line(BaseModel): hunt_group: list[str]; greeting: str = ""

@router.put("/line")
async def set_line(req: Line, user=Depends(require_admin)):
    import json
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO phone_line (id, hunt_group, greeting) VALUES (1,%s,%s) ON CONFLICT (id) DO UPDATE SET hunt_group=EXCLUDED.hunt_group, greeting=EXCLUDED.greeting", (json.dumps(req.hunt_group), req.greeting))
    return {"ok": True}

async def _hunt():
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT hunt_group FROM phone_line WHERE id=1")).fetchone()
    return r[0] if r else []

async def inbound_event(event: str, lkroom: str, identity: str):
    """Called from the LiveKit webhook for rooms named phone-in-*."""
    if not lkroom.startswith("phone-in-") or not db.pool: return
    async with db.pool.connection() as c:
        if event == "participant_joined" and identity.startswith("sip_"):
            await c.execute("INSERT INTO phone_inbound (livekit_room, caller_masked) VALUES (%s,%s) ON CONFLICT DO NOTHING", (lkroom, mask(identity.removeprefix("sip_"))))
        if event == "room_finished":
            await c.execute("DELETE FROM phone_inbound WHERE livekit_room=%s", (lkroom,))

@router.get("/inbound")
async def waiting(user=Depends(auth.matrix_user)):
    if user["user_id"] not in await _hunt(): raise HTTPException(403, "You are not in the phone line's hunt group")
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT livekit_room, caller_masked, extract(epoch from arrived_at)::bigint, answered_by FROM phone_inbound ORDER BY arrived_at")).fetchall()
    return [{"call": r, "caller": m, "arrived_at": a, "answered_by": b} for r, m, a, b in rows]

@router.post("/inbound/{lkroom}/answer")
async def answer(lkroom: str, user=Depends(auth.matrix_user)):
    if user["user_id"] not in await _hunt(): raise HTTPException(403, "You are not in the phone line's hunt group")
    async with db.pool.connection() as c:
        r = await (await c.execute("UPDATE phone_inbound SET answered_by=%s, answered_at=now() WHERE livekit_room=%s AND answered_by IS NULL RETURNING caller_masked", (user["user_id"], lkroom))).fetchone()
    if not r: raise HTTPException(409, "Someone else answered this call")
    await db.audit(user["user_id"], "phone.inbound.answer", r[0])
    return {"url": config.LIVEKIT_PUBLIC_URL, "token": livekit_token.sign(user["user_id"], user["user_id"], lkroom), "caller": r[0],
            "security": "Encrypted to the phone network (TLS + SRTP), not end-to-end"}
