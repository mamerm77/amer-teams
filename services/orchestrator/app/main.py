import secrets, time
from fastapi import FastAPI, Depends, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, generate_latest
import asyncio
from . import auth, livekit_token, agents, config, ops, db, admin, sip

app = FastAPI(title="Amer Teams Orchestrator", version="0.5.0")

app.include_router(admin.router)
app.include_router(sip.router)

@app.on_event("startup")
async def _start():
    await db.connect()
    for aid, en in (await db.load_agent_config()).items():
        if aid in agents.AGENTS: agents.AGENTS[aid].enabled = en
    asyncio.create_task(ops.loop())
REQ = Counter("amer_agent_requests_total", "Agent requests", ["agent"])
LAT = Histogram("amer_agent_latency_seconds", "Agent latency", ["agent"])
ERR = Counter("amer_agent_errors_total", "Agent requests that failed", ["agent"])

async def audit(user, action, detail=""):
    await db.audit(user, action, detail)

@app.get("/healthz")
def health(): return {"status": "ok"}

@app.get("/metrics", response_class=PlainTextResponse)
def metrics(): return generate_latest()

# ---------- Encrypted calls ----------
class CallReq(BaseModel):
    room_id: str
    call_id: str = Field(default_factory=lambda: secrets.token_hex(8))
    display_name: str = ""

@app.post("/v1/calls/token")
async def call_token(req: CallReq, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, req.room_id)
    room = livekit_token.room_name(req.room_id, req.call_id)
    tok = livekit_token.sign(user["user_id"], req.display_name or user["user_id"], room)
    await audit(user["user_id"], "call.join", req.call_id)
    await db.call_session(req.call_id, room, req.room_id, user["user_id"])
    return {"url": config.LIVEKIT_PUBLIC_URL, "token": tok, "livekit_room": room,
            "call_id": req.call_id, "e2ee": "required"}

# ---------- AI engine ----------
class AskReq(BaseModel):
    prompt: str
    context: str = ""
    labels: list[str] = []
    agent: str | None = None

@app.post("/v1/ai/ask")
async def ask(req: AskReq, user=Depends(auth.matrix_user)):
    if req.agent and req.agent not in agents.AGENTS:
        raise HTTPException(400, "Unknown agent")
    t0 = time.perf_counter()
    with LAT.labels(req.agent or "auto").time():
        res = await agents.run(req.prompt, req.context, req.labels, req.agent)
    REQ.labels(res["agent"]).inc()
    status = "blocked" if res.get("blocked") else "error" if res.get("error") else "ok"
    if status == "error": ERR.labels(res["agent"]).inc()
    await db.ai_request(user["user_id"], res["agent"], status, int((time.perf_counter() - t0) * 1000))
    await audit(user["user_id"], "ai.ask", f'{res["agent"]}:{status}')
    return res

# ---------- Control plane ----------
@app.get("/v1/agents")
async def list_agents(user=Depends(auth.matrix_user)):
    return [{"id": a.id, "name": a.name, "enabled": a.enabled, "calls": a.calls,
             "errors": a.errors, "latency_ms": round(a.latency_ms)} for a in agents.AGENTS.values()]

class Toggle(BaseModel): enabled: bool

@app.post("/v1/agents/{aid}")
async def toggle(aid: str, t: Toggle, user=Depends(auth.matrix_user)):
    if aid not in agents.AGENTS: raise HTTPException(404)
    agents.AGENTS[aid].enabled = t.enabled
    await db.save_agent(aid, t.enabled, user["user_id"])
    await audit(user["user_id"], "agent.toggle", f"{aid}={t.enabled}")
    return {"ok": True}

@app.get("/v1/audit")
async def get_audit(user=Depends(auth.matrix_user)): return await db.audit_recent()

@app.get("/v1/audit/verify")
async def verify_audit(user=Depends(auth.matrix_user)):
    ok, n = await db.audit_verify(); return {"intact": ok, "entries": n}

# ---------- Operations (real telemetry) ----------
@app.get("/v1/ops/status")
async def ops_status(user=Depends(auth.matrix_user)):
    now = ops.HISTORY[-1] if ops.HISTORY else await ops.sample()
    return {"now": now, "availability_pct": ops.availability(), "availability_24h_pct": await db.availability(24),
            "history": [{"ts": h["ts"], "latency": {p["service"]: p["latency_ms"] for p in h["services"]},
                         "calls": h["media"].get("active_calls"), "participants": h["media"].get("participants")}
                        for h in list(ops.HISTORY)[-120:]]}

@app.get("/v1/ops/alerts")
async def ops_alerts(user=Depends(auth.matrix_user)):
    """Firing alerts from Alertmanager, for the app's Health screen."""
    if not config.ALERTMANAGER_URL: return []
    import httpx
    try:
        async with httpx.AsyncClient(timeout=4) as c:
            r = await c.get(f"{config.ALERTMANAGER_URL}/api/v2/alerts", params={"active": "true", "silenced": "false"})
        return [{"name": a["labels"].get("alertname"), "severity": a["labels"].get("severity", "warning"),
                 "summary": a["annotations"].get("summary", ""), "since": a.get("startsAt")} for a in r.json()]
    except Exception as e:
        return [{"name": "MonitoringUnreachable", "severity": "warning", "summary": f"Alertmanager not reachable: {type(e).__name__}", "since": None}]

@app.post("/v1/ops/alert-webhook")
async def alert_webhook(payload: dict):
    """Alertmanager notifications: recorded in the tamper-evident audit log."""
    for a in payload.get("alerts", []):
        await db.audit("alertmanager", f"alert.{a.get('status', 'firing')}", f"{a['labels'].get('alertname')}: {a['annotations'].get('summary', '')}"[:300])
    return {"ok": True}

# ---------- Scheduler (structured meeting intent) ----------
class SchedReq(BaseModel):
    request: str
    timezone: str = "Asia/Dubai"

@app.post("/v1/ai/schedule")
async def schedule(req: SchedReq, user=Depends(auth.matrix_user)):
    import json, datetime
    today = datetime.date.today().isoformat()
    res = await agents.run(f"Today is {today}, timezone {req.timezone}. Return JSON with keys title, start (ISO 8601 with offset), duration_min, participants (Matrix IDs or names). Request: {req.request}", agent="sched")
    if res.get("error") or res.get("blocked"): raise HTTPException(502, res["answer"])
    txt = res["answer"]; txt = txt[txt.find("{"): txt.rfind("}") + 1]
    try: plan = json.loads(txt)
    except Exception: raise HTTPException(502, "Scheduler returned invalid JSON")
    await audit(user["user_id"], "ai.schedule", plan.get("title", ""))
    return {"meeting": plan, "trace": res["trace"]}
