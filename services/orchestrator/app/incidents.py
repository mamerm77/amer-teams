"""Operator mode for telecoms (docs/OPERATOR_MODE.md): incidents, war rooms, on-call and paging, MTTA/MTTR.

The server keeps only what a NOC needs to measure: incident number, severity, service, state and times, and the
on-call rota. The war room itself is an end-to-end encrypted chat created by the declaring person's app; the server
learns a hash of its room id, never its content. Alerts from Alertmanager (or any monitoring system posting the
same JSON) open an incident record that waits for the on-call engineer to open the war room.

States: investigating -> identified -> mitigated -> resolved (any earlier state may go straight to resolved).
"""
from __future__ import annotations
import datetime as dt, hashlib, hmac, json, os
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .admin import require_admin

router = APIRouter()
SEVERITIES = ("P1", "P2", "P3", "P4")
STATES = ("investigating", "identified", "mitigated", "resolved")
ALERT_SECRET = os.getenv("AMER_ALERT_SECRET", "")
_mem: dict = {"rotas": {}, "inc": {}, "seq": {}}

def on_call(rota: dict, day: dt.date | None = None) -> str | None:
    m = rota["members"]
    if not m: return None
    d = (day or dt.date.today()); s = rota["starts"] if isinstance(rota["starts"], dt.date) else dt.date.fromisoformat(str(rota["starts"]))
    return m[((d - s).days // max(1, rota["days_each"])) % len(m)]

# ---------- rotas ----------
class Rota(BaseModel):
    service: str = Field(pattern=r"^[A-Za-z0-9 ._/-]{1,60}$")
    members: list[str] = Field(min_length=1, max_length=50)
    starts: dt.date
    days_each: int = Field(default=7, ge=1, le=31)
    escalation: str = ""                    # who is paged if nobody acknowledges in 10 minutes

@router.put("/v1/oncall/rotas")
async def put_rota(r: Rota, user=Depends(require_admin)):
    if db.pool is None: _mem["rotas"][r.service] = r.model_dump()
    else:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO oncall_rotas (service, members, starts, days_each, escalation) VALUES (%s,%s,%s,%s,%s) ON CONFLICT (service) DO UPDATE SET "
                            "members=EXCLUDED.members, starts=EXCLUDED.starts, days_each=EXCLUDED.days_each, escalation=EXCLUDED.escalation",
                            (r.service, json.dumps(r.members), r.starts, r.days_each, r.escalation))
    await db.audit(user["user_id"], "oncall.rota", r.service)
    return {"service": r.service, "on_call": on_call(r.model_dump())}

async def _rotas() -> dict[str, dict]:
    if db.pool is None: return _mem["rotas"]
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT service, members, starts, days_each, escalation FROM oncall_rotas ORDER BY service")).fetchall()
    return {s: {"service": s, "members": m if isinstance(m, list) else json.loads(m), "starts": st, "days_each": d, "escalation": e} for s, m, st, d, e in rows}

@router.get("/v1/oncall")
async def who_is_on_call(user=Depends(auth.matrix_user)):
    return [{"service": s, "on_call": on_call(r), "next": on_call(r, dt.date.today() + dt.timedelta(days=r["days_each"])), "escalation": r["escalation"], "members": r["members"]}
            for s, r in (await _rotas()).items()]

# ---------- incidents ----------
async def _next_number() -> tuple[str, int]:
    y = dt.date.today().year
    if db.pool is None:
        _mem["seq"][y] = _mem["seq"].get(y, 0) + 1; n = _mem["seq"][y]
    else:
        async with db.pool.connection() as c:
            async with c.transaction():
                await c.execute("LOCK TABLE incidents IN EXCLUSIVE MODE")
                n = (await (await c.execute("SELECT coalesce(max(seq), 0) + 1 FROM incidents WHERE number LIKE %s", (f"INC-{y}-%",))).fetchone())[0]
                await c.execute("INSERT INTO incidents (number, seq, severity, service, state, declared_by) VALUES (%s,%s,'P4','-','reserved','-')", (f"INC-{y}-{n:04d}", n))
    return f"INC-{y}-{n:04d}", n

async def _get(number):
    if db.pool is None: return _mem["inc"].get(number)
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT number, severity, service, state, room_hash, declared_by, source, extract(epoch from declared_at)::bigint, "
                                   "extract(epoch from acked_at)::bigint, acked_by, extract(epoch from mitigated_at)::bigint, extract(epoch from resolved_at)::bigint FROM incidents WHERE number=%s", (number,))).fetchone()
    return dict(zip(("number", "severity", "service", "state", "room_hash", "declared_by", "source", "declared_at", "acked_at", "acked_by", "mitigated_at", "resolved_at"), r)) if r else None

async def _write(number, **f):
    if db.pool is None: _mem["inc"].setdefault(number, {"number": number}).update(f); return
    sets = ", ".join(f"{k} = " + ("now()" if v == "now()" else "%s") for k, v in f.items())
    async with db.pool.connection() as c:
        await c.execute(f"UPDATE incidents SET {sets} WHERE number=%s", tuple(v for v in f.values() if v != "now()") + (number,))

class Declare(BaseModel):
    severity: str = Field(pattern=r"^P[1-4]$")
    service: str = Field(min_length=1, max_length=60)
    room_id: str | None = None

@router.post("/v1/incidents")
async def declare(req: Declare, user=Depends(auth.matrix_user)):
    number, _ = await _next_number()
    rh = hashlib.sha256(req.room_id.encode()).hexdigest()[:16] if req.room_id else None
    now = int(dt.datetime.now().timestamp())
    if db.pool is None: _mem["inc"][number] = {"number": number, "severity": req.severity, "service": req.service, "state": "investigating", "room_hash": rh,
                                                "declared_by": user["user_id"], "source": "manual", "declared_at": now, "acked_at": None, "acked_by": None, "mitigated_at": None, "resolved_at": None}
    else: await _write(number, severity=req.severity, service=req.service, state="investigating", room_hash=rh, declared_by=user["user_id"], declared_at="now()")
    rota = (await _rotas()).get(req.service)
    await db.audit(user["user_id"], "incident.declare", f"{number}|{req.severity}|{req.service}")
    return {"number": number, "on_call": on_call(rota) if rota else None, "escalation": rota["escalation"] if rota else None}

class Link(BaseModel): room_id: str
@router.post("/v1/incidents/{number}/room")
async def link_room(number: str, req: Link, user=Depends(auth.matrix_user)):
    if not await _get(number): raise HTTPException(404, "No such incident")
    await _write(number, room_hash=hashlib.sha256(req.room_id.encode()).hexdigest()[:16]); return {"ok": True}

class Change(BaseModel): state: str | None = None; ack: bool = False; severity: str | None = Field(default=None, pattern=r"^P[1-4]$")
@router.post("/v1/incidents/{number}")
async def change(number: str, req: Change, user=Depends(auth.matrix_user)):
    i = await _get(number)
    if not i or i["state"] == "reserved": raise HTTPException(404, "No such incident")
    f: dict = {}
    if req.ack and not i["acked_at"]: f.update(acked_at="now()", acked_by=user["user_id"])
    if req.severity: f["severity"] = req.severity
    if req.state:
        if req.state not in STATES: raise HTTPException(422, "Unknown state")
        if i["state"] == "resolved": raise HTTPException(409, "This incident is resolved")
        if STATES.index(req.state) < STATES.index(i["state"]): raise HTTPException(409, f"Cannot go back from {i['state']} to {req.state}")
        f["state"] = req.state
        if req.state in ("mitigated", "resolved") and not i["mitigated_at"]: f["mitigated_at"] = "now()"
        if req.state == "resolved": f["resolved_at"] = "now()"
        if not i["acked_at"]: f.update(acked_at="now()", acked_by=user["user_id"])     # working on it counts as acknowledging
    if db.pool is None:
        now = int(dt.datetime.now().timestamp()); _mem["inc"][number].update({k: (now if v == "now()" else v) for k, v in f.items()})
    elif f: await _write(number, **f)
    await db.audit(user["user_id"], "incident.change", f"{number}|{json.dumps({k: v for k, v in f.items() if v != 'now()'})}")
    return await _get(number)

@router.get("/v1/incidents")
async def listing(open_only: bool = False, user=Depends(auth.matrix_user)):
    if db.pool is None: rows = list(_mem["inc"].values())
    else:
        async with db.pool.connection() as c:
            ns = [r[0] for r in await (await c.execute("SELECT number FROM incidents WHERE state <> 'reserved' " + ("AND resolved_at IS NULL " if open_only else "") + "ORDER BY declared_at DESC LIMIT 200")).fetchall()]
        rows = [await _get(n) for n in ns]
    return [r for r in rows if not open_only or not r.get("resolved_at")]

@router.get("/v1/incidents/metrics")
async def metrics(days: int = 90, user=Depends(auth.matrix_user)):
    """MTTA (declared -> acknowledged) and MTTR (declared -> resolved), minutes, by severity."""
    if db.pool is None: return {}
    async with db.pool.connection() as c:
        rows = await (await c.execute("""SELECT severity, count(*), avg(extract(epoch from acked_at - declared_at)) / 60, avg(extract(epoch from resolved_at - declared_at)) / 60,
            count(*) FILTER (WHERE resolved_at IS NULL) FROM incidents WHERE state <> 'reserved' AND declared_at > now() - make_interval(days => %s) GROUP BY 1 ORDER BY 1""", (days,))).fetchall()
    return {s: {"incidents": n, "mtta_min": round(float(a), 1) if a is not None else None, "mttr_min": round(float(r), 1) if r is not None else None, "open": o} for s, n, a, r, o in rows}

# ---------- alerts ----------
@router.post("/v1/alerts/webhook")
async def alerts(body: dict, x_amer_alert: str = Header(""), authorization: str = Header("")):
    """Alertmanager webhook (or the same JSON from another monitoring system). A firing critical/major alert opens
    an incident waiting for its war room; a resolved alert resolves an auto-opened incident."""
    given = x_amer_alert or authorization.removeprefix("Bearer ").strip()          # Alertmanager sends http_config.authorization
    if not ALERT_SECRET or not hmac.compare_digest(given, ALERT_SECRET): raise HTTPException(401, "Not the monitoring system")
    out = []
    for a in body.get("alerts", []):
        fp = a.get("fingerprint") or hashlib.sha256(json.dumps(a.get("labels", {}), sort_keys=True).encode()).hexdigest()[:16]
        lab = a.get("labels", {}); sev = {"critical": "P1", "major": "P2", "warning": "P3"}.get(str(lab.get("severity", "")).lower(), "P4")
        service = str(lab.get("service") or lab.get("job") or "network")[:60]
        existing = None
        if db.pool is not None:
            async with db.pool.connection() as c:
                r = await (await c.execute("SELECT number FROM incidents WHERE alert_fingerprint=%s AND resolved_at IS NULL", (fp,))).fetchone()
            existing = r[0] if r else None
        else: existing = next((n for n, i in _mem["inc"].items() if i.get("alert_fingerprint") == fp and not i.get("resolved_at")), None)
        if a.get("status") == "firing" and not existing and sev in ("P1", "P2"):
            number, _ = await _next_number()
            if db.pool is None: _mem["inc"][number] = {"number": number, "severity": sev, "service": service, "state": "investigating", "source": "alert", "alert_fingerprint": fp,
                                                        "declared_by": "@monitoring", "declared_at": int(dt.datetime.now().timestamp()), "acked_at": None, "mitigated_at": None, "resolved_at": None, "room_hash": None, "acked_by": None}
            else: await _write(number, severity=sev, service=service, state="investigating", source="alert", alert_fingerprint=fp, declared_by="@monitoring", declared_at="now()")
            await db.audit("@monitoring", "incident.alert", f"{number}|{sev}|{service}"); out.append({"opened": number})
        elif a.get("status") == "resolved" and existing:
            await change(existing, Change(state="resolved"), {"user_id": "@monitoring"}); out.append({"resolved": existing})
    return {"results": out}
