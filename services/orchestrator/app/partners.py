"""Partner organisations: shared channels across servers (docs/PARTNERS.md).

Connection states: requested -> approved_by_us -> active (both sides approved) -> suspended | disconnected.

- Our administrator adds a partner server and approves it (approved_by_us). The connection becomes active when
  the partner confirms: either their Amer Teams server calls our handshake with the one-time code we gave them, or
  (for a partner running plain Matrix) our administrator records that they confirmed out of band.
- Only active partners are on the list the Synapse module reads (/v1/federation/allowed). Everything from any other
  server is refused by Synapse itself, and rooms are local-only unless created as shared.
- Suspend or disconnect removes the partner from the list at once (within the module's 10-second cache); rooms
  stay readable to local members with history up to the disconnect.
"""
from __future__ import annotations
import hashlib, hmac, os, re, secrets, time
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .admin import require_admin

router = APIRouter()
MODULE_SECRET = os.getenv("AMER_FEDERATION_SECRET", "")
SERVER_RX = r"^[a-z0-9]([a-z0-9.-]{0,251}[a-z0-9])?(:\d{1,5})?$"
STATES = ("requested", "approved_by_us", "active", "suspended", "disconnected")

_mem: dict[str, dict] = {}
async def _get(server):
    if db.pool is None: return _mem.get(server)
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT server, state, code_hash, note, extract(epoch from updated_at) FROM partners WHERE server=%s", (server,))).fetchone()
    return dict(zip(("server", "state", "code_hash", "note", "updated_at"), r)) if r else None
async def _put(p):
    p = {**p, "updated_at": time.time()}
    if db.pool is None: _mem[p["server"]] = p; return p
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO partners (server, state, code_hash, note, updated_at) VALUES (%s,%s,%s,%s,now()) ON CONFLICT (server) DO UPDATE SET state=EXCLUDED.state, code_hash=EXCLUDED.code_hash, note=EXCLUDED.note, updated_at=now()",
                        (p["server"], p["state"], p.get("code_hash"), p.get("note", "")))
    return p
async def _all():
    if db.pool is None: return sorted(_mem.values(), key=lambda p: p["server"])
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT server, state, note, extract(epoch from updated_at) FROM partners ORDER BY server")).fetchall()
    return [dict(zip(("server", "state", "note", "updated_at"), r)) for r in rows]

def _h(code: str) -> str: return hashlib.sha256(code.encode()).hexdigest()

class NewPartner(BaseModel):
    server: str = Field(pattern=SERVER_RX)
    note: str = Field(default="", max_length=200)

@router.post("/v1/admin/partners")
async def add(req: NewPartner, user=Depends(require_admin)):
    """Approve a partner on our side. Returns a one-time code to give the partner's administrator."""
    cur = await _get(req.server)
    if cur and cur["state"] == "active": raise HTTPException(409, "Already an active partner")
    code = secrets.token_urlsafe(18)
    p = await _put({"server": req.server, "state": "approved_by_us", "code_hash": _h(code), "note": req.note})
    await db.audit(user["user_id"], "partner.approve", req.server)
    return {**{k: p[k] for k in ("server", "state", "note")}, "code": code}

class Transition(BaseModel):
    action: str = Field(pattern="^(confirmed|suspend|resume|disconnect)$")

@router.post("/v1/admin/partners/{server}")
async def change(server: str, req: Transition, user=Depends(require_admin)):
    p = await _get(server)
    if not p: raise HTTPException(404, "No such partner")
    rules = {"confirmed": ({"approved_by_us"}, "active"), "suspend": ({"active"}, "suspended"),
             "resume": ({"suspended"}, "active"), "disconnect": ({"requested", "approved_by_us", "active", "suspended"}, "disconnected")}
    allowed, to = rules[req.action]
    if p["state"] not in allowed: raise HTTPException(409, f"Cannot {req.action} a partner that is {p['state']}")
    p = await _put({**p, "state": to, "code_hash": None if to in ("active", "disconnected") else p.get("code_hash")})
    await db.audit(user["user_id"], f"partner.{req.action}", server)
    return {k: p[k] for k in ("server", "state")}

@router.get("/v1/admin/partners")
async def listing(user=Depends(require_admin)): return await _all()

class Handshake(BaseModel):
    server: str = Field(pattern=SERVER_RX)      # the partner's server name
    code: str = Field(min_length=10, max_length=100)

@router.post("/v1/federation/handshake")
async def handshake(req: Handshake):
    """The partner's Amer Teams server confirms with the one-time code we gave its administrator."""
    p = await _get(req.server)
    if not p or p["state"] != "approved_by_us" or not p.get("code_hash") or not hmac.compare_digest(p["code_hash"], _h(req.code)):
        raise HTTPException(403, "Not approved, or wrong code")
    await _put({**p, "state": "active", "code_hash": None})
    await db.audit(f"@federation:{req.server}", "partner.active", req.server)
    return {"state": "active"}

@router.get("/v1/federation/allowed")
async def allowed(x_amer_federation: str = Header("")):
    """For the Synapse module only."""
    if not MODULE_SECRET or not hmac.compare_digest(x_amer_federation, MODULE_SECRET): raise HTTPException(401, "Not the Synapse module")
    return {"servers": [p["server"] for p in await _all() if p["state"] == "active"]}

@router.get("/v1/federation/partners")
async def active_for_users(user=Depends(auth.matrix_user)):
    """Active partner servers, so people can start a shared channel with one."""
    return [{"server": p["server"], "note": p.get("note", "")} for p in await _all() if p["state"] == "active"]
