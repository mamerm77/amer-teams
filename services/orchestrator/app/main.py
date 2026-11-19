import secrets, time
from fastapi import Header, FastAPI, Depends, HTTPException
from fastapi.responses import PlainTextResponse
from pydantic import BaseModel, Field
from prometheus_client import Counter, Histogram, generate_latest
import asyncio
from . import auth, livekit_token, agents, config, ops, db, admin, sip, meetings, calltrace, compliance, digest, meeting_ai, workflows, calendar_time, decisions, notify, flags, partners, guests, analytics, guest_accounts, incidents, skills, rooms, shifts, ambient
from .admin import require_admin
from .agentops.router import router as agentops_router
from .agentops.personal import router as personal_router, store as approvals_store
from .agentops import store as agentops_store

app = FastAPI(title="Amer Teams Orchestrator", version="0.5.0")

app.include_router(admin.router)
app.include_router(sip.router)
app.include_router(meetings.router)
app.include_router(calltrace.router)
app.include_router(compliance.router)
app.include_router(digest.router)
app.include_router(meeting_ai.router)
app.include_router(workflows.router)
app.include_router(calendar_time.router)
app.include_router(decisions.router)
app.include_router(notify.router)
app.include_router(flags.router)
app.include_router(partners.router)
app.include_router(guests.router)
app.include_router(analytics.router)
app.include_router(guest_accounts.router)
app.include_router(incidents.router)
app.include_router(skills.router)
app.include_router(rooms.router)
app.include_router(shifts.router)
app.include_router(ambient.router)
app.include_router(agentops_router)
app.include_router(personal_router)

@app.on_event("startup")
async def _start():
    await db.connect()
    for aid, en in (await db.load_agent_config()).items():
        if aid in agents.AGENTS: agents.AGENTS[aid].enabled = en
    asyncio.create_task(ops.loop())
    asyncio.create_task(calltrace.retention_loop())
    asyncio.create_task(guest_accounts.expiry_loop())
    s = agentops_store.store()
    if hasattr(s, "mark_interrupted"): await s.mark_interrupted()
    try: await approvals_store().cancel_waiting()          # a restart ends waiting sessions: their approvals are cancelled
    except Exception: pass
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
    can_pub = await meetings.publish_allowed(user, req.room_id)      # webinar attendees cannot publish media
    tok = livekit_token.sign(user["user_id"], req.display_name or user["user_id"], room, can_publish=can_pub)
    await audit(user["user_id"], "call.join", req.call_id)
    await db.call_session(req.call_id, room, req.room_id, user["user_id"])
    return {"url": config.LIVEKIT_PUBLIC_URL, "token": tok, "livekit_room": room,
            "call_id": req.call_id, "e2ee": "required", "role": "presenter" if can_pub else "attendee"}

# ---------- AI engine ----------
class AskReq(BaseModel):
    prompt: str
    context: str = ""
    encrypted: bool = False            # the context came from an end-to-end encrypted chat (policy ai_plain_server)
    labels: list[str] = []
    agent: str | None = None

@app.post("/v1/ai/ask")
async def ask(req: AskReq, user=Depends(auth.matrix_user)):
    if req.agent and req.agent not in agents.AGENTS:
        raise HTTPException(400, "Unknown agent")
    if req.encrypted and not (await flags.flags_for(user["user_id"]))["ai_plain_server"]:
        raise HTTPException(403, "Your organisation does not allow encrypted chats to go to the AI service; an attested enclave is required")
    t0 = time.perf_counter()
    with LAT.labels(req.agent or "auto").time():
        res = await agents.run(req.prompt, req.context, req.labels, req.agent)
    REQ.labels(res["agent"]).inc()
    status = "blocked" if res.get("blocked") else "error" if res.get("error") else "ok"
    if status == "error": ERR.labels(res["agent"]).inc()
    await db.ai_request(user["user_id"], res["agent"], status, int((time.perf_counter() - t0) * 1000))
    await audit(user["user_id"], "ai.ask", f'{res["agent"]}:{status}')
    return res

# ---------- Amer as a chat participant ----------
class BotReq(BaseModel):
    user_id: str
    room_id: str
    prompt: str
    history: list[dict] = []          # [{"sender": "...", "body": "..."}], oldest first, from the encrypted chat
    labels: list[str] = []

def _friendly(answer: str) -> str:
    if "ANTHROPIC_API_KEY is not set" in answer:
        return "I'm not set up on this server yet: an administrator needs to add an AI provider key (ANTHROPIC_API_KEY)."
    if answer.startswith("LLM error"):
        return "I couldn't reach the AI service just now. Please try again in a minute."
    return answer

@app.post("/v1/ai/bot")
async def bot(req: BotReq, x_bot_secret: str = Header("")):
    """Called only by the Amer bot service. The request is attributed to and audited for the user who asked."""
    import hmac
    if not config.AMER_BOT_SECRET or not hmac.compare_digest(x_bot_secret, config.AMER_BOT_SECRET):
        raise HTTPException(401, "Not the Amer bot")
    if not (await flags.flags_for(req.user_id))["ai_plain_server"]:
        return {"answer": "Your organisation does not allow encrypted chats to go to the AI service, so I can't answer here until an attested enclave is deployed.", "agent": "Guardian", "blocked": True}
    history = "\n".join(f"{h.get('sender', '?')}: {h.get('body', '')}" for h in req.history[-20:])
    t0 = time.perf_counter()
    res = await agents.run(req.prompt, f"Recent messages in this chat:\n{history}" if history else "", req.labels, None)
    status = "blocked" if res.get("blocked") else "error" if res.get("error") else "ok"
    REQ.labels(res["agent"]).inc()
    await db.ai_request(req.user_id, res["agent"], status, int((time.perf_counter() - t0) * 1000))
    await audit(req.user_id, "ai.chat", f'{res["agent"]}:{status}')
    return {**res, "answer": _friendly(res["answer"])}

ENCLAVE_URL = __import__("os").getenv("ENCLAVE_URL", "")

@app.get("/v1/ai/enclave/attestation")
async def enclave_attestation(user=Depends(auth.matrix_user)):
    """The enclave proxy's attestation, passed through unchanged; the app verifies it (docs/ENCRYPTED_AI.md)."""
    if not ENCLAVE_URL: raise HTTPException(503, "No enclave is deployed on this server")
    import httpx
    try:
        async with httpx.AsyncClient(timeout=5) as c: r = await c.get(f"{ENCLAVE_URL}/attestation")
        return r.json()
    except Exception: raise HTTPException(503, "The enclave is not reachable")

class SealedReq(BaseModel):
    v: int = 1
    epk: str
    nonce: str
    ct: str

@app.post("/v1/ai/enclave/infer")
async def enclave_infer(req: SealedReq, user=Depends(auth.matrix_user)):
    """Relays ciphertext only: this server cannot read the request or the answer."""
    if not ENCLAVE_URL: raise HTTPException(503, "No enclave is deployed on this server")
    import httpx
    t0 = time.perf_counter()
    async with httpx.AsyncClient(timeout=90) as c: r = await c.post(f"{ENCLAVE_URL}/infer", json=req.model_dump())
    if r.status_code != 200: raise HTTPException(r.status_code, "The enclave refused the request")
    j = r.json()
    await db.ai_request(user["user_id"], "Enclave", "ok", int((time.perf_counter() - t0) * 1000))
    await audit(user["user_id"], "ai.enclave", f"bytes={len(req.ct)} tokens={sum((j.get('tokens') or {}).get(k, 0) for k in ('input_tokens', 'output_tokens'))}")
    return {"v": 1, "nonce": j["nonce"], "ct": j["ct"]}

@app.get("/v1/ai/assistant")
async def assistant(user=Depends(auth.matrix_user)):
    """Who to chat with: the Amer account on this server."""
    domain = user["user_id"].split(":", 1)[1]
    return {"user_id": f"@{config.AMER_BOT_USER}:{domain}", "available": bool(config.AMER_BOT_SECRET)}

# ---------- Control plane ----------
@app.get("/v1/agents")
async def list_agents(user=Depends(auth.matrix_user)):
    return [{"id": a.id, "name": a.name, "enabled": a.enabled, "calls": a.calls,
             "errors": a.errors, "latency_ms": round(a.latency_ms)} for a in agents.AGENTS.values()]

class Toggle(BaseModel): enabled: bool

@app.post("/v1/agents/{aid}")
async def toggle(aid: str, t: Toggle, user=Depends(require_admin)):
    if aid not in agents.AGENTS: raise HTTPException(404)
    agents.AGENTS[aid].enabled = t.enabled
    await db.save_agent(aid, t.enabled, user["user_id"])
    await audit(user["user_id"], "agent.toggle", f"{aid}={t.enabled}")
    return {"ok": True}

@app.get("/v1/audit")
async def get_audit(user=Depends(require_admin)): return await db.audit_recent()

@app.get("/v1/audit/verify")
async def verify_audit(user=Depends(require_admin)):
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
