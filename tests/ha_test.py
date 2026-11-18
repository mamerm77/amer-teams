"""High-availability tests on live processes (no mocks).

A. AI engine: 3 replicas behind a health-checking load balancer (Caddy), continuous traffic,
   one replica killed, then a rolling restart of all replicas -> zero failed requests.
B. Settings consistency: an agent switched off via one replica is off on all replicas.
C. PostgreSQL: primary + synchronous standby; the primary is killed during writes, the standby is
   promoted; every acknowledged write is present (RPO 0) and the AI engine keeps working via a
   multi-host connection string (same behaviour as the CloudNativePG "-rw" service).
"""
import asyncio, json, os, shutil, signal, subprocess, sys, time
import httpx, psycopg

PG = "/usr/lib/postgresql/16/bin"; BASE = "/opt/amer/ha"; ORCH_DIR = "/home/claude/amer-teams/services/orchestrator"
PORTS = [8181, 8182, 8183]; LB = "http://127.0.0.1:8090"
DSN = "postgresql://amer:amer-pass@127.0.0.1:5434,127.0.0.1:5435/amer?target_session_attrs=read-write&connect_timeout=2"
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
def sh(cmd, user="postgres"):
    return subprocess.run(["su", user, "-c", cmd], capture_output=True, text=True)

# ---------------- PostgreSQL pair ----------------
def pg_setup():
    for p in ("5434", "5435"): sh(f"{PG}/pg_ctl -D {BASE}/pg{p} stop -m immediate")
    shutil.rmtree(BASE, ignore_errors=True); os.makedirs(BASE); shutil.chown(BASE, "postgres", "postgres")
    sh(f"{PG}/initdb -D {BASE}/pg5434 -U postgres --auth-local=trust --auth-host=scram-sha-256 -E UTF8 --locale=C >/dev/null")
    with open(f"{BASE}/pg5434/postgresql.conf", "a") as f:
        f.write("port=5434\nlisten_addresses='127.0.0.1'\nunix_socket_directories='/tmp'\nwal_level=replica\nmax_wal_senders=5\n"
                "synchronous_commit=on\npassword_encryption=scram-sha-256\n")
    with open(f"{BASE}/pg5434/pg_hba.conf", "a") as f: f.write("host replication repl 127.0.0.1/32 scram-sha-256\n")
    sh(f"{PG}/pg_ctl -D {BASE}/pg5434 -l {BASE}/p.log start -w")
    for q in ("CREATE ROLE repl REPLICATION LOGIN PASSWORD 'repl'", "CREATE ROLE amer LOGIN PASSWORD 'amer-pass'", "CREATE DATABASE amer OWNER amer"):
        sh(f'psql -h /tmp -p 5434 -c "{q}"')
    sh(f"PGPASSWORD=repl {PG}/pg_basebackup -h 127.0.0.1 -p 5434 -U repl -D {BASE}/pg5435 -R -X stream -C -S standby1")
    with open(f"{BASE}/pg5435/postgresql.auto.conf", "a") as f:
        f.write("primary_conninfo = 'host=127.0.0.1 port=5434 user=repl password=repl application_name=standby1'\n")
    with open(f"{BASE}/pg5435/postgresql.conf", "a") as f: f.write("port=5435\n")
    sh(f"{PG}/pg_ctl -D {BASE}/pg5435 -l {BASE}/s.log start -w")
    # only now require the standby to confirm every commit (otherwise commits would wait for a standby that does not exist)
    sh('psql -h /tmp -p 5434 -c "ALTER SYSTEM SET synchronous_standby_names = \'standby1\'"'); sh('psql -h /tmp -p 5434 -c "SELECT pg_reload_conf()"')
    time.sleep(2)

# ---------------- AI engine replicas + LB ----------------
procs = {}
def start_replica(port):
    env = {**os.environ, "SYNAPSE_URL": "http://127.0.0.1:8008", "LIVEKIT_HTTP_URL": "http://127.0.0.1:7880", "LIVEKIT_API_KEY": "APIamer",
           "LIVEKIT_API_SECRET": "amer-test-secret-amer-test-secret-0123", "LIVEKIT_PUBLIC_URL": "ws://127.0.0.1:7880", "DATABASE_URL": DSN}
    procs[port] = subprocess.Popen(["/opt/amer/venv/bin/uvicorn", "app.main:app", "--port", str(port)], cwd=ORCH_DIR, env=env,
                                   stdout=open(f"{BASE}/orch{port}.log", "a"), stderr=subprocess.STDOUT, start_new_session=True)
def wait_up(url, secs=30):
    end = time.time() + secs
    while time.time() < end:
        try:
            if httpx.get(url, timeout=1).status_code == 200: return True
        except Exception: pass
        time.sleep(0.5)
    return False
def lb_start():
    cfg = f"""{{\n\tadmin off\n\tauto_https off\n}}\n:8090 {{\n\treverse_proxy {' '.join(f'127.0.0.1:{p}' for p in PORTS)} {{
\t\tlb_policy round_robin\n\t\tlb_try_duration 5s\n\t\tlb_try_interval 100ms\n\t\thealth_uri /healthz\n\t\thealth_interval 1s\n\t\thealth_timeout 1s\n\t\tfail_duration 10s\n\t}}\n}}\n"""
    open(f"{BASE}/Caddyfile", "w").write(cfg)
    return subprocess.Popen(["/opt/amer/caddy", "run", "--config", f"{BASE}/Caddyfile", "--adapter", "caddyfile"],
                            stdout=open(f"{BASE}/lb.log", "w"), stderr=subprocess.STDOUT, start_new_session=True)

async def load(stop, stats, token):
    """Continuous mixed traffic through the load balancer: health, authenticated agent list, audit read."""
    H = {"Authorization": f"Bearer {token}"}
    async with httpx.AsyncClient(timeout=10) as c:
        while not stop.is_set():
            for path in ("/healthz", "/v1/agents", "/v1/audit"):
                try:
                    r = await c.get(LB + path, headers=H); stats["ok" if r.status_code == 200 else "fail"] += 1
                    if r.status_code != 200: stats["errors"].append(f"{path} {r.status_code}")
                except Exception as e:
                    stats["fail"] += 1; stats["errors"].append(f"{path} {type(e).__name__}")
            await asyncio.sleep(0.02)

async def main():
    pg_setup()
    with psycopg.connect("host=/tmp port=5434 dbname=postgres user=postgres") as c:   # replication view needs superuser
        rep = c.execute("SELECT application_name, sync_state FROM pg_stat_replication").fetchall()
    check("C0. Standby streaming in synchronous mode", rep == [("standby1", "sync")], rep)
    for p in PORTS: start_replica(p)
    check("A0. 3 AI-engine replicas started", all(wait_up(f"http://127.0.0.1:{p}/healthz") for p in PORTS))
    lb = lb_start(); check("A1. Load balancer up", wait_up(LB + "/healthz"))
    tok = httpx.post("http://127.0.0.1:8008/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": "moh"}, "password": "Pass-moh-123"}).json()["access_token"]
    H = {"Authorization": f"Bearer {tok}"}

    # A: kill one replica under load, then rolling restart
    stats = {"ok": 0, "fail": 0, "errors": []}; stop = asyncio.Event(); t = asyncio.create_task(load(stop, stats, tok))
    await asyncio.sleep(3)
    os.killpg(procs[8182].pid, signal.SIGKILL)                 # hard crash, no graceful shutdown
    await asyncio.sleep(5)
    start_replica(8182); wait_up("http://127.0.0.1:8182/healthz"); await asyncio.sleep(3)
    for p in PORTS:                                            # rolling upgrade: one replica at a time
        os.killpg(procs[p].pid, signal.SIGTERM); procs[p].wait(10)
        start_replica(p); wait_up(f"http://127.0.0.1:{p}/healthz"); await asyncio.sleep(2)
    await asyncio.sleep(2); stop.set(); await t
    check("A2. Replica crash + rolling restart: zero failed requests", stats["fail"] == 0 and stats["ok"] > 200,
          f"{stats['ok']} ok, {stats['fail']} failed {stats['errors'][:3]}")

    # B: settings consistency across replicas
    httpx.post(f"http://127.0.0.1:{PORTS[0]}/v1/agents/trans", headers=H, json={"enabled": False})
    def all_off(): return all(next(a for a in httpx.get(f"http://127.0.0.1:{p}/v1/agents", headers=H).json() if a["id"] == "trans")["enabled"] is False for p in PORTS)
    end = time.time() + 15; ok = False
    while time.time() < end and not ok: ok = all_off(); time.sleep(1)
    check("B1. Agent switched off on one replica is off on all 3", ok)
    httpx.post(f"http://127.0.0.1:{PORTS[1]}/v1/agents/trans", headers=H, json={"enabled": True})

    # C: database failover under writes
    acked, failed_writes = [], 0
    stop2 = asyncio.Event()
    async def writer():
        nonlocal failed_writes
        i = 0
        while not stop2.is_set():
            i += 1
            try:
                async with await psycopg.AsyncConnection.connect(DSN, autocommit=True) as c:
                    await c.execute("INSERT INTO agent_config (agent_id, enabled, updated_by) VALUES (%s, true, 'ha-test')", (f"probe-{i}",))
                acked.append(f"probe-{i}")
            except Exception: failed_writes += 1
            await asyncio.sleep(0.05)
    wt = asyncio.create_task(writer()); await asyncio.sleep(3)
    t_kill = time.time()
    sh(f"{PG}/pg_ctl -D {BASE}/pg5434 stop -m immediate")      # primary crashes
    sh(f"{PG}/pg_ctl -D {BASE}/pg5435 promote -w")             # operator promotes the synchronous standby
    promoted_in = time.time() - t_kill
    with psycopg.connect("host=/tmp port=5435 dbname=amer user=postgres", autocommit=True) as c:    # standby accepts writes now
        c.execute("ALTER SYSTEM SET synchronous_standby_names = ''"); c.execute("SELECT pg_reload_conf()")
    n_before = len(acked); await asyncio.sleep(4); stop2.set(); await wt
    with psycopg.connect("host=/tmp port=5435 dbname=amer user=postgres") as c:
        present = {r[0] for r in c.execute("SELECT agent_id FROM agent_config WHERE updated_by='ha-test'")}
        is_primary = not c.execute("SELECT pg_is_in_recovery()").fetchone()[0]
    lost = [a for a in acked if a not in present]
    check("C1. Standby promoted to primary", is_primary, f"in {promoted_in:.1f} s")
    check("C2. RPO 0: every acknowledged write survived the crash", not lost and len(acked) > 20, f"{len(acked)} acknowledged, {len(lost)} lost")
    check("C3. Writes resumed on the new primary", len(acked) > n_before, f"{len(acked) - n_before} writes after failover")
    r = httpx.post(LB + "/v1/agents/summ", headers=H, json={"enabled": True}); a = httpx.get(LB + "/v1/audit", headers=H)
    check("C4. AI engine works against the new primary (multi-host connection)", r.status_code == 200 and a.status_code == 200, f"{r.status_code}/{a.status_code}")

    for p in PORTS: os.killpg(procs[p].pid, signal.SIGTERM)
    os.killpg(lb.pid, signal.SIGTERM); sh(f"{PG}/pg_ctl -D {BASE}/pg5435 stop -m fast")
    p = sum(x["pass"] for x in R); print(f"\n{p}/{len(R)} high-availability checks passed")
    json.dump(R, open(os.getenv("OUT", "ha_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)

asyncio.run(main())
