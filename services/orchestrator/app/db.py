"""PostgreSQL persistence for the orchestrator (psycopg 3, async pool)."""
import hashlib, pathlib
from psycopg_pool import AsyncConnectionPool
from . import config

pool: AsyncConnectionPool | None = None
MIGRATIONS = pathlib.Path(__file__).resolve().parent.parent / "migrations"

async def connect():
    global pool
    pool = AsyncConnectionPool(config.DATABASE_URL, min_size=2, max_size=10, open=False)
    await pool.open(wait=True)
    await migrate()

async def migrate():
    async with pool.connection() as c:
        await c.execute("CREATE TABLE IF NOT EXISTS schema_migrations (version int PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())")
        done = {r[0] for r in await (await c.execute("SELECT version FROM schema_migrations")).fetchall()}
        for f in sorted(MIGRATIONS.glob("*.sql")):
            v = int(f.name.split("_")[0])
            if v not in done:
                await c.execute(f.read_text())

async def audit(user, action, detail=""):
    async with pool.connection() as c:
        async with c.transaction():
            await c.execute("LOCK TABLE audit_log IN EXCLUSIVE MODE")
            row = await (await c.execute("SELECT hash FROM audit_log ORDER BY id DESC LIMIT 1")).fetchone()
            prev = row[0] if row else "0" * 64
            h = hashlib.sha256(f"{prev}|{user}|{action}|{detail}".encode()).hexdigest()
            await c.execute("INSERT INTO audit_log (user_id, action, detail, prev_hash, hash) VALUES (%s,%s,%s,%s,%s)",
                            (user, action, detail, prev, h))

async def audit_recent(n=100):
    async with pool.connection() as c:
        rows = await (await c.execute("SELECT extract(epoch from ts)::bigint, user_id, action, detail FROM audit_log ORDER BY id DESC LIMIT %s", (n,))).fetchall()
    return [{"ts": r[0], "user": r[1], "action": r[2], "detail": r[3]} for r in rows]

async def audit_verify():
    """Recompute the hash chain; returns (ok, rows_checked)."""
    async with pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, action, detail, prev_hash, hash FROM audit_log ORDER BY id")).fetchall()
    prev = "0" * 64
    for u, a, d, p, h in rows:
        if p != prev or hashlib.sha256(f"{p}|{u}|{a}|{d}".encode()).hexdigest() != h:
            return False, len(rows)
        prev = h
    return True, len(rows)

async def load_agent_config():
    async with pool.connection() as c:
        return dict(await (await c.execute("SELECT agent_id, enabled FROM agent_config")).fetchall())

async def save_agent(aid, enabled, user):
    async with pool.connection() as c:
        await c.execute("INSERT INTO agent_config (agent_id, enabled, updated_by, updated_at) VALUES (%s,%s,%s,now()) "
                        "ON CONFLICT (agent_id) DO UPDATE SET enabled=EXCLUDED.enabled, updated_by=EXCLUDED.updated_by, updated_at=now()",
                        (aid, enabled, user))

async def ai_request(user, agent, status, latency_ms):
    async with pool.connection() as c:
        await c.execute("INSERT INTO ai_requests (user_id, agent, status, latency_ms) VALUES (%s,%s,%s,%s)", (user, agent, status, latency_ms))

async def call_session(call_id, lk_room, room_id, user):
    async with pool.connection() as c:
        await c.execute("INSERT INTO call_sessions (call_id, livekit_room, room_hash, user_id) VALUES (%s,%s,%s,%s)",
                        (call_id, lk_room, hashlib.sha256(room_id.encode()).hexdigest(), user))

async def ops_sample(s):
    async with pool.connection() as c:
        async with c.transaction():
            for p in s["services"]:
                await c.execute("INSERT INTO ops_samples VALUES (to_timestamp(%s),%s,%s,%s) ON CONFLICT DO NOTHING",
                                (s["ts"], p["service"], p["up"], p["latency_ms"]))
            await c.execute("INSERT INTO media_samples VALUES (to_timestamp(%s),%s,%s) ON CONFLICT DO NOTHING",
                            (s["ts"], s["media"].get("active_calls"), s["media"].get("participants")))

async def availability(hours=24):
    async with pool.connection() as c:
        rows = await (await c.execute("SELECT service, round(100.0*avg(up::int),3) FROM ops_samples WHERE ts > now() - make_interval(hours => %s) GROUP BY service", (hours,))).fetchall()
    return {r[0]: float(r[1]) for r in rows}
