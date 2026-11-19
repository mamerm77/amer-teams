"""Guest accounts and UAE data residency (docs/GUEST_ACCOUNTS.md, docs/DATA_RESIDENCY.md).

Guest accounts: an external person gets a real Matrix account (so chats with them stay end-to-end encrypted),
marked as a guest with a sponsor and an expiry. The Synapse policy module (deploy/synapse-modules) enforces, on the
server, that a guest cannot create rooms, cannot invite anyone, and can join only rooms they were invited to. At
expiry the account is deactivated (checked whenever the list is read and every ten minutes).

Data residency: a report of where each kind of data is stored and processed, from this deployment's own
configuration, with a pass/fail against the required region (DATA_REGION, default "AE").
"""
from __future__ import annotations
import asyncio, hmac, os, secrets, time, urllib.parse
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from . import auth, config, db
from .admin import _syn, mxid, require_admin
from .partners import MODULE_SECRET

router = APIRouter()
_mem: dict[str, dict] = {}

class GuestReq(BaseModel):
    username: str = Field(min_length=2, max_length=40)
    display_name: str = Field(min_length=1, max_length=60)
    email: str = Field(pattern=r"^[^@\s]{1,64}@[^@\s]{1,190}\.[A-Za-z]{2,}$")
    days: int = Field(default=30, ge=1, le=180)

@router.post("/v1/admin/guest-accounts")
async def create_guest(req: GuestReq, user=Depends(require_admin)):
    uid = mxid(f"guest.{req.username}")
    pw = secrets.token_urlsafe(14)
    await _syn("PUT", f"/_synapse/admin/v2/users/{urllib.parse.quote(uid)}", json={"password": pw, "displayname": f"{req.display_name} (guest)", "admin": False})
    exp = time.time() + req.days * 86400; dom = req.email.split("@")[1].lower()
    if db.pool is None: _mem[uid] = {"user_id": uid, "sponsor": user["user_id"], "email_domain": dom, "expires_at": exp, "deactivated_at": None}
    else:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO guest_accounts (user_id, sponsor, email_domain, expires_at) VALUES (%s,%s,%s,to_timestamp(%s))", (uid, user["user_id"], dom, exp))
    await db.audit(user["user_id"], "guest_account.create", f"{uid}|{dom}|{req.days}d")
    return {"user_id": uid, "password": pw, "expires_at": int(exp), "note": "Give the guest this one-time password; ask them to change it at first sign-in."}

async def _rows(active_only=False):
    if db.pool is None: return [g for g in _mem.values() if not active_only or g["deactivated_at"] is None]
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, sponsor, email_domain, extract(epoch from created_at)::bigint, extract(epoch from expires_at)::bigint, "
                                      "extract(epoch from deactivated_at)::bigint FROM guest_accounts" + (" WHERE deactivated_at IS NULL" if active_only else "") + " ORDER BY created_at DESC")).fetchall()
    return [dict(zip(("user_id", "sponsor", "email_domain", "created_at", "expires_at", "deactivated_at"), r)) for r in rows]

async def expire_due() -> list[str]:
    done = []
    for g in await _rows(active_only=True):
        if g["expires_at"] > time.time(): continue
        try: await _syn("POST", f"/_synapse/admin/v1/deactivate/{urllib.parse.quote(g['user_id'])}", json={"erase": False})
        except HTTPException: continue
        if db.pool is None: _mem[g["user_id"]]["deactivated_at"] = time.time()
        else:
            async with db.pool.connection() as c: await c.execute("UPDATE guest_accounts SET deactivated_at=now() WHERE user_id=%s", (g["user_id"],))
        await db.audit("@system", "guest_account.expired", g["user_id"]); done.append(g["user_id"])
    return done

@router.get("/v1/admin/guest-accounts")
async def list_guests(user=Depends(require_admin)):
    await expire_due(); return await _rows()

@router.post("/v1/admin/guest-accounts/{uid}/end")
async def end_guest(uid: str, user=Depends(require_admin)):
    if db.pool is None: _mem.get(uid, {})["expires_at"] = 0
    else:
        async with db.pool.connection() as c: await c.execute("UPDATE guest_accounts SET expires_at=now() - interval '1 minute' WHERE user_id=%s", (uid,))
    return {"ended": uid in await expire_due()}

@router.get("/v1/federation/guests")
async def guests_for_module(x_amer_federation: str = Header("")):
    """For the Synapse module only: guest accounts that are active."""
    if not MODULE_SECRET or not hmac.compare_digest(x_amer_federation, MODULE_SECRET): raise HTTPException(401, "Not the Synapse module")
    return {"guests": [g["user_id"] for g in await _rows(active_only=True)]}

async def expiry_loop():
    while True:
        await asyncio.sleep(600)
        try: await expire_due()
        except Exception: pass

# ---------- data residency ----------
REGION = os.getenv("DATA_REGION", "AE")
HOSTING = {k: os.getenv(f"RESIDENCY_{k.upper()}", "") for k in ("database", "media", "files", "backups", "ai", "push")}
UAE_HINTS = ("uaenorth", "uaecentral", "me-central-1", "core42", "g42", "eand", "etisalat", "khazna", "moro", ".ae", "abudhabi", "dubai", "localhost", "127.0.0.1", "on-premises")

@router.get("/v1/admin/residency")
async def residency(user=Depends(require_admin)):
    """Where each kind of data lives. Location for each component comes from RESIDENCY_* (set by whoever deploys),
    since the server cannot see which data centre its own disks are in."""
    def judge(where: str) -> str:
        if not where: return "not declared"
        return "in region" if REGION == "AE" and any(h in where.lower() for h in UAE_HINTS) else ("in region" if REGION != "AE" and REGION.lower() in where.lower() else "check")
    ai_where = HOSTING["ai"] or (config.__dict__.get("ANTHROPIC_BASE_URL") or os.getenv("ANTHROPIC_BASE_URL", "https://api.anthropic.com"))
    items = [
        {"data": "Messages and files (end-to-end encrypted)", "stored": HOSTING["database"] or config.SYNAPSE_URL, "readable_by_server": False},
        {"data": "Calls and meetings media (end-to-end encrypted, relayed)", "stored": HOSTING["media"] or config.LIVEKIT_HTTP_URL, "readable_by_server": False},
        {"data": "Attachments (encrypted blobs)", "stored": HOSTING["files"] or config.SYNAPSE_URL, "readable_by_server": False},
        {"data": "Audit log, call metadata, settings", "stored": HOSTING["database"] or "PostgreSQL (DATABASE_URL)", "readable_by_server": True},
        {"data": "Backups", "stored": HOSTING["backups"], "readable_by_server": True},
        {"data": "AI requests (text you send to Amer)", "stored": ai_where, "readable_by_server": True,
         "note": "Processed by the AI provider at this address. Restricted chats never go there; Confidential chats are refused."},
        {"data": "Push notifications (event id only, no content)", "stored": HOSTING["push"] or "Apple APNs / Google FCM (outside the UAE)", "readable_by_server": False},
    ]
    for i in items: i["status"] = judge(i["stored"])
    return {"required_region": REGION, "items": items, "all_in_region": all(i["status"] == "in region" for i in items if i["readable_by_server"])}
