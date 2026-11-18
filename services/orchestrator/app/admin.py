"""User administration: invite codes, create / list / deactivate users, reset passwords.
Proxies the Synapse Admin API with a service admin token; every caller must be a server admin."""
import urllib.parse
import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, config, db

router = APIRouter(prefix="/v1/admin")

def _h(): return {"Authorization": f"Bearer {config.SYNAPSE_ADMIN_TOKEN}"}

async def _syn(method, path, **kw):
    if not config.SYNAPSE_ADMIN_TOKEN:
        raise HTTPException(503, "SYNAPSE_ADMIN_TOKEN is not configured on the server")
    async with httpx.AsyncClient(timeout=10) as c:
        r = await c.request(method, f"{config.SYNAPSE_URL}{path}", headers=_h(), **kw)
    if r.status_code >= 400:
        try: j = r.json()
        except Exception: j = {}
        raise HTTPException(r.status_code, j.get("error", r.text[:200]))
    return r.json() if r.content else {}

async def require_admin(user=Depends(auth.matrix_user)):
    j = await _syn("GET", f"/_synapse/admin/v1/users/{urllib.parse.quote(user['user_id'])}/admin")
    if not j.get("admin"):
        raise HTTPException(403, "Administrator rights required")
    return user

def mxid(username: str) -> str:
    u = username.strip().lower().lstrip("@").split(":")[0]
    if not u or not all(ch.isalnum() or ch in "._=-/" for ch in u):
        raise HTTPException(400, "Username may contain only a-z, 0-9 and . _ = - /")
    return f"@{u}:{config.SERVER_NAME}"

class InviteReq(BaseModel):
    uses_allowed: int = Field(1, ge=1, le=1000)
    expiry_days: int = Field(7, ge=1, le=365)

@router.post("/invites")
async def create_invite(req: InviteReq, user=Depends(require_admin)):
    import time
    j = await _syn("POST", "/_synapse/admin/v1/registration_tokens/new",
                   json={"uses_allowed": req.uses_allowed, "expiry_time": int((time.time() + req.expiry_days * 86400) * 1000)})
    await db.audit(user["user_id"], "admin.invite.create", f"uses={req.uses_allowed}")
    return j

@router.get("/invites")
async def list_invites(user=Depends(require_admin)):
    return (await _syn("GET", "/_synapse/admin/v1/registration_tokens"))["registration_tokens"]

@router.delete("/invites/{token}")
async def revoke_invite(token: str, user=Depends(require_admin)):
    await _syn("DELETE", f"/_synapse/admin/v1/registration_tokens/{urllib.parse.quote(token)}")
    await db.audit(user["user_id"], "admin.invite.revoke", token[:4] + "…")
    return {"ok": True}

class UserReq(BaseModel):
    username: str
    password: str
    display_name: str = ""
    admin: bool = False

@router.post("/users")
async def create_user(req: UserReq, user=Depends(require_admin)):
    uid = mxid(req.username)
    async with httpx.AsyncClient(timeout=10) as c:
        exists = (await c.get(f"{config.SYNAPSE_URL}/_synapse/admin/v2/users/{urllib.parse.quote(uid)}", headers=_h())).status_code == 200
    if exists: raise HTTPException(409, "That username is already taken")
    await _syn("PUT", f"/_synapse/admin/v2/users/{urllib.parse.quote(uid)}",
               json={"password": req.password, "displayname": req.display_name or req.username, "admin": req.admin})
    await db.audit(user["user_id"], "admin.user.create", uid)
    return {"user_id": uid}

@router.get("/users")
async def list_users(user=Depends(require_admin)):
    j = await _syn("GET", "/_synapse/admin/v2/users?limit=500&guests=false&deactivated=true")
    return [{"user_id": u["name"], "display_name": u.get("displayname"), "admin": bool(u.get("admin")),
             "deactivated": bool(u.get("deactivated")), "created_ms": u.get("creation_ts")} for u in j["users"]]

class PwReq(BaseModel): password: str

@router.post("/users/{uid}/password")
async def reset_password(uid: str, req: PwReq, user=Depends(require_admin)):
    await _syn("POST", f"/_synapse/admin/v1/reset_password/{urllib.parse.quote(uid)}", json={"new_password": req.password, "logout_devices": True})
    await db.audit(user["user_id"], "admin.user.password_reset", uid)
    return {"ok": True}

@router.post("/users/{uid}/deactivate")
async def deactivate(uid: str, user=Depends(require_admin)):
    if uid == user["user_id"]: raise HTTPException(400, "You cannot deactivate your own account")
    await _syn("POST", f"/_synapse/admin/v1/deactivate/{urllib.parse.quote(uid)}", json={"erase": False})
    await db.audit(user["user_id"], "admin.user.deactivate", uid)
    return {"ok": True}
