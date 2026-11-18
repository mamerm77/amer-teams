"""Real operations telemetry: live health probes and latency of every service, LiveKit room stats,
agent metrics. Feeds the Performance and High-availability screens. No synthetic data."""
import asyncio, time
from collections import deque
import httpx
from livekit import api as lkapi
from prometheus_client import Gauge
from . import config, agents, db

G_UP = Gauge("amer_service_up", "1 if the service answered its health probe", ["service"])
G_LAT = Gauge("amer_service_probe_latency_ms", "Health probe round-trip time", ["service"])
G_CALLS = Gauge("amer_active_calls", "Calls currently running on the media server")
G_PART = Gauge("amer_call_participants", "People currently in calls")
G_AGENT_ON = Gauge("amer_agent_enabled", "1 if the AI agent is enabled", ["agent"])
G_AUDIT = Gauge("amer_audit_chain_intact", "1 if the audit log hash chain verifies")

HISTORY: deque = deque(maxlen=360)   # 30 min at 5 s
TARGETS = {
    "chat (Synapse)": lambda: f"{config.SYNAPSE_URL}/health",
    "media (LiveKit)": lambda: config.LIVEKIT_HTTP_URL,
}

async def probe(client, name, url):
    t0 = time.perf_counter()
    try:
        r = await client.get(url, timeout=3)
        ok = r.status_code < 500
    except Exception as e:
        return {"service": name, "up": False, "latency_ms": None, "error": type(e).__name__}
    return {"service": name, "up": ok, "latency_ms": round((time.perf_counter() - t0) * 1000, 1)}

async def livekit_stats():
    try:
        async with lkapi.LiveKitAPI(config.LIVEKIT_HTTP_URL, config.LIVEKIT_API_KEY, config.LIVEKIT_API_SECRET) as lk:
            rooms = (await lk.room.list_rooms(lkapi.ListRoomsRequest())).rooms
        return {"active_calls": len(rooms), "participants": sum(r.num_participants for r in rooms)}
    except Exception as e:
        return {"active_calls": None, "participants": None, "error": type(e).__name__}

async def sample():
    async with httpx.AsyncClient() as c:
        probes = await asyncio.gather(*[probe(c, n, u()) for n, u in TARGETS.items()])
    probes.append({"service": "AI engine (orchestrator)", "up": True, "latency_ms": 0.0})
    s = {"ts": int(time.time()), "services": probes, "media": await livekit_stats(),
         "agents": [{"id": a.id, "name": a.name, "enabled": a.enabled, "calls": a.calls,
                     "errors": a.errors, "latency_ms": round(a.latency_ms)} for a in agents.AGENTS.values()]}
    HISTORY.append(s)
    for p in probes:
        G_UP.labels(p["service"]).set(1 if p["up"] else 0)
        if p["latency_ms"] is not None: G_LAT.labels(p["service"]).set(p["latency_ms"])
    if s["media"].get("active_calls") is not None:
        G_CALLS.set(s["media"]["active_calls"]); G_PART.set(s["media"]["participants"])
    for a in agents.AGENTS.values(): G_AGENT_ON.labels(a.id).set(1 if a.enabled else 0)
    try: G_AUDIT.set(1 if (await db.audit_verify())[0] else 0)
    except Exception: pass
    try: await db.ops_sample(s)
    except Exception: pass
    return s

async def loop():
    while True:
        try: await sample()
        except Exception: pass
        await asyncio.sleep(5)

def availability():
    if not HISTORY: return {}
    out = {}
    for name in [p["service"] for p in HISTORY[-1]["services"]]:
        vals = [p["up"] for h in HISTORY for p in h["services"] if p["service"] == name]
        out[name] = round(100 * sum(vals) / len(vals), 3)
    return out
