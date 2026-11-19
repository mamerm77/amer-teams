"""Call trace: signalling, media-server events and media quality for every call, visible to administrators.

Sources
- client: each device reports the signalling events it sends and receives, and its state changes
  (metadata only: call id, type, reason, outcome, party id, timestamps).
- media:  LiveKit webhooks (room started/finished, participant joined/left, track published),
  verified with the LiveKit API secret.
- quality: WebRTC getStats samples (codec, bitrate, loss, jitter, RTT, MOS) reported every 10 s.
Message and call content is never sent here; it stays end-to-end encrypted. Tenants that enable
compliance archive content through a separate archiving account (see docs/COMPLIANCE.md).
"""
import base64, hashlib, json
import jwt
from fastapi import APIRouter, Depends, HTTPException, Request
from pydantic import BaseModel, Field
from . import auth, config, db
from .admin import require_admin

router = APIRouter()
SIGNALS = {"invite", "ringing", "answer", "reject", "hangup", "end", "key", "state", "media_connected", "error", "join", "leave"}

async def _q(sql, args=(), fetch=False):
    async with db.pool.connection() as c:
        cur = await c.execute(sql, args)
        return await cur.fetchall() if fetch else None

async def tenant_of(user_id: str) -> str:
    r = await _q("SELECT tenant FROM tenant_members WHERE user_id=%s", (user_id,), True)
    return r[0][0] if r else "public"

# ---------------- client reports ----------------
class TraceEvent(BaseModel):
    call_id: str = Field(min_length=1, max_length=128)
    room_id: str = Field("", max_length=255)
    event: str
    direction: str = Field("out", pattern="^(in|out|local)$")
    device_id: str = Field("", max_length=64)
    kind: str = Field("call", pattern="^(call|meeting|phone)$")
    media: str | None = Field(None, pattern="^(audio|video)$")
    peer: str | None = Field(None, max_length=255)
    reason: str | None = Field(None, max_length=64)
    outcome: str | None = Field(None, max_length=32)
    state: str | None = Field(None, max_length=32)
    duration_s: int | None = Field(None, ge=0, le=7 * 86400)
    client_ts: int | None = None

@router.post("/v1/calls/trace")
async def report(ev: TraceEvent, user=Depends(auth.matrix_user)):
    if ev.event not in SIGNALS: raise HTTPException(400, "Unknown trace event")
    uid = user["user_id"]
    detail = {k: v for k, v in ev.model_dump().items() if v not in (None, "") and k not in ("call_id", "event", "device_id", "room_id")}
    await _q("INSERT INTO call_events (call_id, source, user_id, device_id, event, detail) VALUES (%s,'client',%s,%s,%s,%s)",
             (ev.call_id, uid, ev.device_id, ev.event, json.dumps(detail)))
    rh = hashlib.sha256(ev.room_id.encode()).hexdigest() if ev.room_id else None
    if ev.event == "invite" and ev.direction == "out":
        await _q("INSERT INTO call_records (call_id, kind, media, room_hash, caller, callee, tenant) VALUES (%s,%s,%s,%s,%s,%s,%s) "
                 "ON CONFLICT (call_id) DO NOTHING", (ev.call_id, ev.kind, ev.media, rh, uid, ev.peer, await tenant_of(uid)))
    elif ev.event == "join" and ev.kind != "call":
        await _q("INSERT INTO call_records (call_id, kind, media, room_hash, caller, tenant) VALUES (%s,%s,%s,%s,%s,%s) "
                 "ON CONFLICT (call_id) DO NOTHING", (ev.call_id, ev.kind, ev.media, rh, uid, await tenant_of(uid)))
    elif ev.event == "answer":
        await _q("UPDATE call_records SET answered_at=coalesce(answered_at, now()), callee=coalesce(callee, %s) WHERE call_id=%s",
                 (uid if ev.direction == "out" else None, ev.call_id))
    elif ev.event in ("end", "reject") or (ev.event == "state" and ev.state == "ended"):
        out = ev.outcome or ({"busy": "busy"}.get(ev.reason or "", "declined") if ev.event == "reject" else None)
        await _q("UPDATE call_records SET ended_at=coalesce(ended_at, now()), outcome=coalesce(outcome, %s), "
                 "duration_s=coalesce(%s, duration_s) WHERE call_id=%s", (out, ev.duration_s, ev.call_id))
    return {"ok": True}

class QualitySample(BaseModel):
    kind: str = Field(pattern="^(audio|video)$")
    direction: str = Field(pattern="^(send|recv)$")
    codec: str | None = Field(None, max_length=32)
    bitrate_kbps: float | None = Field(None, ge=0, le=1e6)
    packets: int | None = Field(None, ge=0)
    packets_lost: int | None = Field(None, ge=0)
    jitter_ms: float | None = Field(None, ge=0, le=1e5)
    rtt_ms: float | None = Field(None, ge=0, le=1e5)

class QualityReport(BaseModel):
    call_id: str = Field(min_length=1, max_length=128)
    device_id: str = Field("", max_length=64)
    samples: list[QualitySample] = Field(max_length=32)

def mos(loss_pct: float, rtt_ms: float, jitter_ms: float) -> float:
    """ITU-T G.107 E-model, simplified (G.711/Opus-class codec): R = 93.2 − Id − Ie,eff, then R→MOS."""
    d = rtt_ms / 2 + 2 * jitter_ms + 10
    idd = 0.024 * d + (0.11 * (d - 177.3) if d > 177.3 else 0)
    ie = 0 + (95 - 0) * loss_pct / (loss_pct + 4.3)          # Bpl ≈ 4.3 for random loss with PLC
    r = max(0.0, min(100.0, 93.2 - idd - ie))
    return round(1 + 0.035 * r + 7e-6 * r * (r - 60) * (100 - r), 2)

@router.post("/v1/calls/quality")
async def quality(q: QualityReport, user=Depends(auth.matrix_user)):
    for s in q.samples:
        loss = (100.0 * s.packets_lost / (s.packets + s.packets_lost)) if s.packets and s.packets_lost is not None and s.packets + s.packets_lost else None
        m = mos(loss or 0, s.rtt_ms or 0, s.jitter_ms or 0) if s.kind == "audio" else None
        await _q("INSERT INTO call_quality (call_id, user_id, device_id, kind, direction, codec, bitrate_kbps, packets, packets_lost, loss_pct, jitter_ms, rtt_ms, mos) "
                 "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s)",
                 (q.call_id, user["user_id"], q.device_id, s.kind, s.direction, s.codec, s.bitrate_kbps, s.packets, s.packets_lost, loss, s.jitter_ms, s.rtt_ms, m))
    return {"ok": True}

# ---------------- LiveKit webhooks (media server) ----------------
@router.post("/v1/livekit/webhook")
async def livekit_webhook(request: Request):
    body = await request.body()
    tok = request.headers.get("Authorization", "")
    try:
        claims = jwt.decode(tok, config.LIVEKIT_API_SECRET, algorithms=["HS256"], options={"verify_aud": False})
    except jwt.PyJWTError:
        raise HTTPException(401, "Invalid webhook signature")
    if claims.get("iss") != config.LIVEKIT_API_KEY or claims.get("sha256") != base64.b64encode(hashlib.sha256(body).digest()).decode():
        raise HTTPException(401, "Webhook body does not match its signature")
    ev = json.loads(body)
    room = (ev.get("room") or {}).get("name", "")
    r = await _q("SELECT call_id FROM call_sessions WHERE livekit_room=%s ORDER BY joined_at DESC LIMIT 1", (room,), True) if room else []
    call_id = r[0][0] if r else f"lk:{room}"
    p = ev.get("participant") or {}; t = ev.get("track") or {}
    detail = {k: v for k, v in {"participant": p.get("identity"), "track": t.get("type"), "track_source": t.get("source"),
              "mime": t.get("mimeType"), "encrypted": t.get("encryption") not in (None, "NONE") if t else None,
              "num_participants": (ev.get("room") or {}).get("numParticipants")}.items() if v is not None}
    await _q("INSERT INTO call_events (call_id, source, user_id, event, detail) VALUES (%s,'media',%s,%s,%s)",
             (call_id, p.get("identity"), ev.get("event", "unknown"), json.dumps(detail)))
    if ev.get("event") == "participant_joined":
        await _q("UPDATE call_records SET participants=participants+1 WHERE call_id=%s", (call_id,))
    return {"ok": True}

# ---------------- admin views ----------------
@router.get("/v1/admin/calls")
async def list_calls(limit: int = 100, outcome: str | None = None, user: str | None = None, admin=Depends(require_admin)):
    rows = await _q("SELECT call_id, kind, media, caller, callee, extract(epoch from started_at)::bigint, extract(epoch from answered_at)::bigint, "
                    "extract(epoch from ended_at)::bigint, outcome, duration_s, participants, tenant, "
                    "(SELECT round(avg(mos)::numeric,2) FROM call_quality q WHERE q.call_id=r.call_id AND mos IS NOT NULL), "
                    "(SELECT round(max(loss_pct)::numeric,1) FROM call_quality q WHERE q.call_id=r.call_id) "
                    "FROM call_records r WHERE (%s::text IS NULL OR outcome=%s) AND (%s::text IS NULL OR caller=%s OR callee=%s) "
                    "ORDER BY started_at DESC LIMIT %s", (outcome, outcome, user, user, user, min(limit, 1000)), True)
    k = ["call_id", "kind", "media", "caller", "callee", "started", "answered", "ended", "outcome", "duration_s", "participants", "tenant", "avg_mos", "max_loss_pct"]
    out = [dict(zip(k, r)) for r in rows]
    for o in out:
        for f in ("avg_mos", "max_loss_pct"):
            if o[f] is not None: o[f] = float(o[f])
        if o["outcome"] is None: o["outcome"] = "in_progress" if o["answered"] else "ringing"
    return out

@router.get("/v1/admin/calls/{call_id}/trace")
async def call_trace(call_id: str, admin=Depends(require_admin)):
    ev = await _q("SELECT extract(epoch from ts), source, user_id, device_id, event, detail FROM call_events WHERE call_id=%s ORDER BY ts, id", (call_id,), True)
    q = await _q("SELECT extract(epoch from ts), user_id, kind, direction, codec, bitrate_kbps, loss_pct, jitter_ms, rtt_ms, mos FROM call_quality WHERE call_id=%s ORDER BY ts", (call_id,), True)
    if not ev and not q: raise HTTPException(404, "No trace for this call")
    await db.audit(admin["user_id"], "admin.call_trace", call_id)
    return {"call_id": call_id,
            "events": [{"t": float(e[0]), "source": e[1], "user": e[2], "device": e[3], "event": e[4], **(e[5] or {})} for e in ev],
            "quality": [{"t": float(x[0]), "user": x[1], "kind": x[2], "dir": x[3], "codec": x[4], "kbps": x[5], "loss_pct": x[6],
                         "jitter_ms": x[7], "rtt_ms": x[8], "mos": x[9]} for x in q],
            "content": "end-to-end encrypted; not available to the server"}

# ---------------- tenants and compliance ----------------
class TenantReq(BaseModel):
    tenant: str = Field(pattern=r"^[a-z0-9][a-z0-9-]{1,40}$")
    name: str = Field(min_length=1, max_length=100)
    compliance_enabled: bool = False
    compliance_user: str | None = Field(None, pattern=r"^@[^:]+:.+$")
    retention_days: int = Field(90, ge=1, le=3650)

@router.get("/v1/admin/tenants")
async def tenants(admin=Depends(require_admin)):
    rows = await _q("SELECT t.tenant, name, compliance_enabled, compliance_user, retention_days, (SELECT count(*) FROM tenant_members m WHERE m.tenant=t.tenant) FROM tenants t ORDER BY tenant", (), True)
    return [dict(zip(["tenant", "name", "compliance_enabled", "compliance_user", "retention_days", "members"], r)) for r in rows]

@router.post("/v1/admin/tenants")
async def save_tenant(t: TenantReq, admin=Depends(require_admin)):
    if t.tenant == "public" and t.compliance_enabled:
        raise HTTPException(400, "Compliance archiving cannot be enabled for public users")
    if t.compliance_enabled and not t.compliance_user:
        raise HTTPException(400, "Compliance needs an archiving account")
    await _q("INSERT INTO tenants (tenant, name, compliance_enabled, compliance_user, retention_days, updated_by) VALUES (%s,%s,%s,%s,%s,%s) "
             "ON CONFLICT (tenant) DO UPDATE SET name=EXCLUDED.name, compliance_enabled=EXCLUDED.compliance_enabled, compliance_user=EXCLUDED.compliance_user, "
             "retention_days=EXCLUDED.retention_days, updated_by=EXCLUDED.updated_by, updated_at=now()",
             (t.tenant, t.name, t.compliance_enabled, t.compliance_user, t.retention_days, admin["user_id"]))
    await db.audit(admin["user_id"], "tenant.save", f"{t.tenant} compliance={t.compliance_enabled}")
    return {"ok": True}

class MemberReq(BaseModel):
    user_id: str = Field(pattern=r"^@[^:]+:.+$")
    tenant: str

@router.post("/v1/admin/tenants/members")
async def set_member(m: MemberReq, admin=Depends(require_admin)):
    if m.tenant == "public":
        await _q("DELETE FROM tenant_members WHERE user_id=%s", (m.user_id,))
    else:
        if not await _q("SELECT 1 FROM tenants WHERE tenant=%s", (m.tenant,), True): raise HTTPException(404, "Unknown tenant")
        await _q("INSERT INTO tenant_members VALUES (%s,%s) ON CONFLICT (user_id) DO UPDATE SET tenant=EXCLUDED.tenant", (m.user_id, m.tenant))
    await db.audit(admin["user_id"], "tenant.member", f"{m.user_id}->{m.tenant}")
    return {"ok": True}

@router.get("/v1/compliance/me")
async def my_compliance(user=Depends(auth.matrix_user)):
    """Clients call this to show users whether their organisation archives their content."""
    t = await tenant_of(user["user_id"])
    r = await _q("SELECT name, compliance_enabled, compliance_user, retention_days FROM tenants WHERE tenant=%s", (t,), True)
    name, en, cu, rd = r[0]
    return {"tenant": t, "name": name, "compliance_enabled": en, "compliance_user": cu if en else None, "retention_days": rd}

# ---------------- retention ----------------
PURGE_SQL = [
    # rows of calls that have a record: that record's tenant decides
    """DELETE FROM call_events e USING call_records r, tenants t
       WHERE e.call_id = r.call_id AND r.tenant = t.tenant AND e.ts < now() - make_interval(days => t.retention_days)""",
    """DELETE FROM call_quality q USING call_records r, tenants t
       WHERE q.call_id = r.call_id AND r.tenant = t.tenant AND q.ts < now() - make_interval(days => t.retention_days)""",
    # rows without a record (e.g. media-server events of unknown rooms): public retention
    """DELETE FROM call_events e WHERE NOT EXISTS (SELECT 1 FROM call_records r WHERE r.call_id = e.call_id)
       AND e.ts < now() - make_interval(days => (SELECT retention_days FROM tenants WHERE tenant = 'public'))""",
    """DELETE FROM call_quality q WHERE NOT EXISTS (SELECT 1 FROM call_records r WHERE r.call_id = q.call_id)
       AND q.ts < now() - make_interval(days => (SELECT retention_days FROM tenants WHERE tenant = 'public'))""",
    """DELETE FROM call_records r USING tenants t
       WHERE r.tenant = t.tenant AND r.started_at < now() - make_interval(days => t.retention_days)""",
]

async def purge_once() -> dict:
    """Deletes call-trace data older than each tenant's retention. One replica at a time (advisory lock)."""
    out = {}
    async with db.pool.connection() as c:
        got = (await (await c.execute("SELECT pg_try_advisory_lock(73315)")).fetchone())[0]
        if not got: return {"skipped": "another replica is purging"}
        try:
            for i, sql in enumerate(PURGE_SQL):
                cur = await c.execute(sql); out[["events", "quality", "orphan_events", "orphan_quality", "records"][i]] = cur.rowcount
        finally:
            await c.execute("SELECT pg_advisory_unlock(73315)")
    return out

async def retention_loop():
    import asyncio, logging
    while True:
        try:
            from . import compliance
            r = await purge_once()
            r["compliance_archive"] = await compliance.purge_once()
            if any(isinstance(v, int) and v for v in r.values()): logging.info("call-trace retention purge: %s", r)
        except Exception as e:
            logging.warning("call-trace retention purge failed: %s", e)
        await asyncio.sleep(3600)

@router.post("/v1/admin/calls/purge")
async def purge_now(admin=Depends(require_admin)):
    r = await purge_once()
    await db.audit(admin["user_id"], "admin.calls_purge", json.dumps(r))
    return r
