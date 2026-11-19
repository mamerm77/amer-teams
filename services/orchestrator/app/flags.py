"""Feature flags per tenant (docs/FEATURE_FLAGS.md).

flags(tenant, feature, enabled, rollout_pct). A user's tenant comes from tenant_members ("public" if none). A
feature is on for a user when the tenant's row (or, without one, the "*" row, or the built-in default) is
enabled and the user falls inside the rollout percentage. The bucket is a stable hash of user and feature, so
the same people stay in as the percentage grows. The server checks a flag before serving a feature's API, and
the app hides a feature whose flag is off.
"""
from __future__ import annotations
import hashlib
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .admin import require_admin

router = APIRouter()
# feature -> (default on?, title). New Phase 3 features start on for everyone so a fresh install has them; an
# administrator can switch any of them off, or roll it out to a percentage, per tenant.
FEATURES: dict[str, tuple[bool, str]] = {
    "catch_up": (True, "Catch me up"), "meeting_agent": (True, "Ask Amer in meetings"), "workflows": (True, "Workflows"),
    "canvases": (True, "Canvases"), "personal_agents": (True, "My agents and the glass box"), "decisions": (True, "Decisions and tasks"),
    "find_time": (True, "Find a time"), "quiet_hours": (True, "Quiet hours"), "agenda": (True, "Meeting agenda and follow-up"),
    "search": (True, "Search everywhere"), "file_preview": (True, "File previews")}

def bucket(user: str, feature: str) -> int:
    return int(hashlib.sha256(f"{feature}|{user}".encode()).hexdigest()[:8], 16) % 100

_mem: dict[tuple[str, str], dict] = {}
async def _rows(tenant: str) -> dict[str, dict]:
    if db.pool is None:
        return {f: r for (t, f), r in _mem.items() if t in (tenant, "*")} | {f: r for (t, f), r in _mem.items() if t == tenant}
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT tenant, feature, enabled, rollout_pct FROM flags WHERE tenant IN (%s, '*') ORDER BY tenant = %s", (tenant, tenant))).fetchall()
    return {f: {"enabled": e, "rollout_pct": p} for _, f, e, p in rows}          # the tenant's own row comes last and wins

async def tenant_of(user: str) -> str:
    if db.pool is None: return _mem.get(("_member", user), {}).get("tenant", "public")
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT tenant FROM tenant_members WHERE user_id=%s", (user,))).fetchone()
    return r[0] if r else "public"

async def flags_for(user: str) -> dict[str, bool]:
    rows = await _rows(await tenant_of(user))
    out = {}
    for f, (default, _) in FEATURES.items():
        r = rows.get(f, {"enabled": default, "rollout_pct": 100})
        out[f] = bool(r["enabled"]) and bucket(user, f) < int(r["rollout_pct"])
    return out

def require(feature: str):
    """FastAPI dependency: 403 when the feature is off for this user."""
    async def dep(user=Depends(auth.matrix_user)):
        if not (await flags_for(user["user_id"])).get(feature, False):
            raise HTTPException(403, f"{FEATURES[feature][1]} is switched off for your organisation")
        return user
    return dep

@router.get("/v1/flags")
async def mine(user=Depends(auth.matrix_user)): return await flags_for(user["user_id"])

class Flag(BaseModel):
    tenant: str = Field(pattern=r"^(\*|[a-z0-9_-]{1,40})$")
    feature: str
    enabled: bool
    rollout_pct: int = Field(default=100, ge=0, le=100)

@router.get("/v1/admin/flags")
async def all_flags(user=Depends(require_admin)):
    if db.pool is None: return [{"tenant": t, "feature": f, **r} for (t, f), r in _mem.items() if t != "_member"]
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT tenant, feature, enabled, rollout_pct FROM flags ORDER BY tenant, feature")).fetchall()
    return {"features": {k: v[1] for k, v in FEATURES.items()}, "defaults": {k: v[0] for k, v in FEATURES.items()},
            "rows": [{"tenant": t, "feature": f, "enabled": e, "rollout_pct": p} for t, f, e, p in rows]}

@router.put("/v1/admin/flags")
async def set_flag(req: Flag, user=Depends(require_admin)):
    if req.feature not in FEATURES: raise HTTPException(422, f"Unknown feature {req.feature}")
    if db.pool is None: _mem[(req.tenant, req.feature)] = {"enabled": req.enabled, "rollout_pct": req.rollout_pct}
    else:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO flags (tenant, feature, enabled, rollout_pct, updated_at) VALUES (%s,%s,%s,%s,now()) "
                            "ON CONFLICT (tenant, feature) DO UPDATE SET enabled=EXCLUDED.enabled, rollout_pct=EXCLUDED.rollout_pct, updated_at=now()",
                            (req.tenant, req.feature, req.enabled, req.rollout_pct))
    await db.audit(user["user_id"], "flag.set", f"{req.tenant}/{req.feature}={req.enabled}@{req.rollout_pct}%")
    return {"ok": True}
