"""Compliance archive: search, export, verification and retention (docs/COMPLIANCE.md).
Administrator-only. Every search, export and verification is itself written to the audit log."""
import hashlib, json
from datetime import datetime
from fastapi import APIRouter, Depends, HTTPException, Query
from fastapi.responses import StreamingResponse
from . import db
from .admin import require_admin

router = APIRouter()

async def _rows(sql, args=()):
    async with db.pool.connection() as c:
        return await (await c.execute(sql, args)).fetchall()

def _where(tenant, sender, room, q, since, until):
    w, a = ["tenant = %s"], [tenant]
    if sender: w.append("sender = %s"); a.append(sender)
    if room: w.append("room_id = %s"); a.append(room)
    if q: w.append("to_tsvector('simple', coalesce(body,'')) @@ plainto_tsquery('simple', %s)"); a.append(q)
    if since: w.append("ts >= %s"); a.append(since)
    if until: w.append("ts < %s"); a.append(until)
    return " AND ".join(w), a

COLS = "id, room_id, room_name, event_id, sender, extract(epoch from ts)::bigint, type, body, content, hash"
KEYS = ["id", "room_id", "room_name", "event_id", "sender", "ts", "type", "body", "content", "hash"]

@router.get("/v1/admin/compliance/search")
async def search(tenant: str, sender: str | None = None, room: str | None = None, q: str | None = None,
                 since: datetime | None = None, until: datetime | None = None, limit: int = Query(100, le=1000), admin=Depends(require_admin)):
    if not await _rows("SELECT 1 FROM tenants WHERE tenant=%s AND compliance_enabled", (tenant,)):
        raise HTTPException(404, "No compliance archive for this tenant")
    w, a = _where(tenant, sender, room, q, since, until)
    rows = await _rows(f"SELECT {COLS} FROM compliance_archive WHERE {w} ORDER BY ts DESC, id DESC LIMIT %s", (*a, limit))
    await db.audit(admin["user_id"], "compliance.search", json.dumps({"tenant": tenant, "sender": sender, "room": room, "q": q,
                   "since": str(since) if since else None, "until": str(until) if until else None, "results": len(rows)}))
    return [dict(zip(KEYS, r)) for r in rows]

@router.get("/v1/admin/compliance/export")
async def export(tenant: str, sender: str | None = None, room: str | None = None, q: str | None = None,
                 since: datetime | None = None, until: datetime | None = None, admin=Depends(require_admin)):
    """Newline-delimited JSON with each record's hash, for e-discovery. The audit entry records the scope."""
    if not await _rows("SELECT 1 FROM tenants WHERE tenant=%s AND compliance_enabled", (tenant,)):
        raise HTTPException(404, "No compliance archive for this tenant")
    w, a = _where(tenant, sender, room, q, since, until)
    rows = await _rows(f"SELECT {COLS}, prev_hash FROM compliance_archive WHERE {w} ORDER BY id", a)
    await db.audit(admin["user_id"], "compliance.export", json.dumps({"tenant": tenant, "sender": sender, "room": room, "q": q, "records": len(rows)}))
    def gen():
        for r in rows: yield json.dumps({**dict(zip(KEYS, r[:-1])), "prev_hash": r[-1]}, ensure_ascii=False) + "\n"
    return StreamingResponse(gen(), media_type="application/x-ndjson",
                             headers={"Content-Disposition": f'attachment; filename="compliance-{tenant}.ndjson"'})

async def verify_chain(tenant: str):
    """Recomputes the tenant's chain from its oldest surviving row (older rows may have been purged by retention)."""
    rows = await _rows("SELECT event_id, sender, (extract(epoch from ts)*1000)::bigint, type, content, prev_hash, hash FROM compliance_archive WHERE tenant=%s ORDER BY id", (tenant,))
    prev = rows[0][5] if rows else "0" * 64
    for i, (eid, snd, ts, typ, content, p, h) in enumerate(rows):
        canon = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
        if p != prev or hashlib.sha256(f"{p}|{tenant}|{eid}|{snd}|{ts}|{typ}|{canon}".encode()).hexdigest() != h:
            return {"ok": False, "checked": i + 1, "broken_at": eid}
        prev = h
    return {"ok": True, "checked": len(rows)}

@router.get("/v1/admin/compliance/verify")
async def verify(tenant: str, admin=Depends(require_admin)):
    r = await verify_chain(tenant)
    await db.audit(admin["user_id"], "compliance.verify", json.dumps({"tenant": tenant, **r}))
    return r

async def purge_once() -> int:
    """Removes archive rows past each tenant's retention. The guard trigger refuses anything else."""
    async with db.pool.connection() as c:
        async with c.transaction():
            await c.execute("SET LOCAL amer.purge = 'on'")
            cur = await c.execute("""DELETE FROM compliance_archive a USING tenants t
                                     WHERE a.tenant = t.tenant AND a.ts < now() - make_interval(days => t.retention_days)""")
            return cur.rowcount
