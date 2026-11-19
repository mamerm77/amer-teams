"""Tool connectors (docs/TOOL_CONNECTORS.md): Jira, GitHub, GitLab, Grafana/Alertmanager, ServiceNow, Jenkins or any
tool that can call a webhook posts into a chat.

A host creates a connector for a chat and gets a secret webhook URL. The chat invites the connectors account (an
ordinary end-to-end encrypted Matrix member, shown in the member list). The connector service receives the webhook,
checks the secret, formats the event and posts it encrypted. The secret is stored hashed; the URL is shown once.
"""
from __future__ import annotations
import hashlib, hmac, os, secrets
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .meetings import power_level, HOST_LEVEL

router = APIRouter()
KINDS = ("generic", "github", "gitlab", "jira", "alertmanager", "grafana", "servicenow", "jenkins")
SERVICE_SECRET = os.getenv("AMER_CONNECTOR_SECRET", "")
BOT = os.getenv("AMER_CONNECTOR_USER", "connectors")
_h = lambda s: hashlib.sha256(s.encode()).hexdigest()

class NewConnector(BaseModel):
    room_id: str
    kind: str = Field(pattern="^(" + "|".join(KINDS) + ")$")
    name: str = Field(min_length=1, max_length=60)

@router.post("/v1/connectors")
async def create(req: NewConnector, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, req.room_id)
    if await power_level(user, req.room_id) < HOST_LEVEL: raise HTTPException(403, "Only a chat host can add connectors")
    cid = f"cn_{secrets.token_hex(5)}"; token = secrets.token_urlsafe(24)
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO connectors (id, room_id, kind, name, token_hash, created_by) VALUES (%s,%s,%s,%s,%s,%s)", (cid, req.room_id, req.kind, req.name, _h(token), user["user_id"]))
    await db.audit(user["user_id"], "connector.create", f"{req.room_id}|{cid}|{req.kind}")
    server = user["user_id"].split(":", 1)[1]
    return {"id": cid, "path": f"/hooks/{cid}/{token}", "invite": f"@{BOT}:{server}"}

@router.get("/v1/connectors")
async def listing(room_id: str, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, room_id)
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT id, kind, name, created_by, extract(epoch from created_at)::bigint, extract(epoch from last_used)::bigint, uses, enabled FROM connectors WHERE room_id=%s ORDER BY created_at", (room_id,))).fetchall()
    return [dict(zip(("id", "kind", "name", "created_by", "created_at", "last_used", "uses", "enabled"), r)) for r in rows]

@router.delete("/v1/connectors/{cid}")
async def remove(cid: str, user=Depends(auth.matrix_user)):
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT room_id FROM connectors WHERE id=%s", (cid,))).fetchone()
        if not r: raise HTTPException(404, "No such connector")
        if await power_level(user, r[0]) < HOST_LEVEL: raise HTTPException(403, "Only a chat host can remove connectors")
        await c.execute("DELETE FROM connectors WHERE id=%s", (cid,))
    await db.audit(user["user_id"], "connector.remove", cid); return {"removed": True}

class Check(BaseModel): id: str; token: str

@router.post("/v1/connectors/internal/check")
async def check(req: Check, x_amer_connector: str = Header("")):
    """For the connector service only: is this webhook genuine, and which chat does it post to?"""
    if not SERVICE_SECRET or not hmac.compare_digest(x_amer_connector, SERVICE_SECRET): raise HTTPException(401, "Not the connector service")
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT room_id, kind, name, token_hash, enabled FROM connectors WHERE id=%s", (req.id,))).fetchone()
        if not r or not r[4] or not hmac.compare_digest(r[3], _h(req.token)): raise HTTPException(403, "Unknown connector or wrong secret")
        await c.execute("UPDATE connectors SET last_used=now(), uses=uses+1 WHERE id=%s", (req.id,))
    return {"room_id": r[0], "kind": r[1], "name": r[2]}

@router.get("/v1/connectors/internal/rooms")
async def rooms(x_amer_connector: str = Header("")):
    """Rooms the connectors account may join (it refuses invites to any other)."""
    if not SERVICE_SECRET or not hmac.compare_digest(x_amer_connector, SERVICE_SECRET): raise HTTPException(401, "Not the connector service")
    async with db.pool.connection() as c:
        return {"rooms": [r[0] for r in await (await c.execute("SELECT DISTINCT room_id FROM connectors WHERE enabled")).fetchall()]}
