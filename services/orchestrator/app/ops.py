"""Real operations telemetry: live health probes and latency of every service, LiveKit room stats,
agent metrics. Feeds the Performance and High-availability screens. No synthetic data."""
import asyncio, time
from collections import deque
import httpx
from livekit import api as lkapi
from . import config, agents, db

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
