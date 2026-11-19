"""Monitoring tests against the live stack: Prometheus scraping, metrics, alert rules firing on real
failures, Alertmanager delivery, audit trail, app alert API, and recovery. No mocks.
Run on the host that runs the stack (it stops and restarts services)."""
import json, os, subprocess, sys, time
import httpx, psycopg

PROM, AM, ORCH, HS = "http://127.0.0.1:9090", "http://127.0.0.1:9093", "http://127.0.0.1:8080", "http://127.0.0.1:8008"
AMER_DB = "postgresql://amer:amer-pass@127.0.0.1/amer"
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
h = httpx.Client(timeout=10)
q = lambda e: h.get(f"{PROM}/api/v1/query", params={"query": e}).json()["data"]["result"]
val = lambda e: float(q(e)[0]["value"][1]) if q(e) else None
def firing(name): return any(a["labels"]["alertname"] == name and a["state"] == "firing" for a in h.get(f"{PROM}/api/v1/alerts").json()["data"]["alerts"])
def am_has(name): return any(a["labels"]["alertname"] == name for a in h.get(f"{AM}/api/v2/alerts", params={"active": "true"}).json())
def wait(cond, secs=90):
    end = time.time() + secs
    while time.time() < end:
        try:
            if cond(): return True
        except Exception: pass
        time.sleep(3)
    return False
def audit(action, like):
    with psycopg.connect(AMER_DB) as c:
        return c.execute("SELECT count(*) FROM audit_log WHERE action=%s AND detail LIKE %s", (action, like)).fetchone()[0]
tok = h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": "moh"}, "password": "Pass-moh-123"}).json()["access_token"]
H = {"Authorization": f"Bearer {tok}"}

# 1. scraping and metrics
t = h.get(f"{PROM}/api/v1/targets").json()["data"]["activeTargets"]
check("1. All 6 targets scraped", wait(lambda: all(x["health"] == "up" for x in h.get(f"{PROM}/api/v1/targets").json()["data"]["activeTargets"]), 30), ", ".join(f"{x['labels']['job']}={x['health']}" for x in t))
check("2. AI engine reports 3/3 services up", val("sum(amer_service_up)") == 3)
check("3. Chat server metrics present", (val("sum(synapse_http_server_requests_received_total)") or 0) > 0)
check("4. Media server metrics present", len(q('{job="media"}')) > 10, f"{len(q('{job=\"media\"}'))} series")
check("5. PostgreSQL and Redis exporters report up", val("pg_up") == 1 and val("redis_up") == 1)
check("6. Audit-integrity metric is 1", val("amer_audit_chain_intact") == 1)
rules = h.get(f"{PROM}/api/v1/rules").json()["data"]["groups"]
check("7. 8 alert rules loaded", sum(len(g["rules"]) for g in rules) == 8)

# 2. real outage: media server
subprocess.run(["pkill", "-f", "livekit-server"]); t0 = time.time()
check("8. Media outage: ServiceDown alert fires", wait(lambda: firing("ServiceDown")), f"after {time.time()-t0:.0f} s")
check("9. Media outage: MetricsUnavailable warning fires (metrics scrape also fails)", wait(lambda: firing("MetricsUnavailable"), 180))
check("10. Alertmanager received the alerts", wait(lambda: am_has("ServiceDown"), 40))
check("11. Alert written to tamper-evident audit log", wait(lambda: audit("alert.firing", "ServiceDown%") > 0, 60))
app_alerts = h.get(f"{ORCH}/v1/ops/alerts", headers=H).json()
check("12. App Health screen API lists the alert", any(a["name"] == "ServiceDown" for a in app_alerts), [a["name"] for a in app_alerts])
subprocess.Popen("cd /opt/amer && exec setsid ./livekit-server --config lk.yaml >> lk.log 2>&1 < /dev/null", shell=True)
check("13. Media restored: alerts resolve", wait(lambda: not firing("ServiceDown") and not firing("MetricsUnavailable"), 120))
check("14. Resolution recorded in audit log", wait(lambda: audit("alert.resolved", "ServiceDown%") > 0, 90))

# 3. real outage: Redis
subprocess.run(["redis-cli", "shutdown", "nosave"], capture_output=True)
check("15. Redis outage: RedisDown alert fires", wait(lambda: firing("RedisDown")))
subprocess.run(["redis-server", "--daemonize", "yes", "--appendonly", "yes", "--dir", "/opt/amer"], capture_output=True)
check("16. Redis restored: alert resolves", wait(lambda: not firing("RedisDown"), 90))

# 4. tamper detection: alter one audit row behind the trigger (as DB superuser), then restore it
def su(sql):   # run as the PostgreSQL superuser over the local socket
    return subprocess.run(["su", "postgres", "-c", f'psql -d amer -tAc "{sql}"'], capture_output=True, text=True).stdout.strip()
rid = su("SELECT id FROM audit_log ORDER BY id LIMIT 1")
orig = su(f"SELECT detail FROM audit_log WHERE id={rid}")
su("ALTER TABLE audit_log DISABLE TRIGGER audit_no_update")
su(f"UPDATE audit_log SET detail = detail || ' (tampered)' WHERE id={rid}")
try:
    check("17. Tampered audit row: AuditLogTampered alert fires", wait(lambda: firing("AuditLogTampered"), 90))
finally:
    su(f"UPDATE audit_log SET detail = regexp_replace(detail, ' \\(tampered\\)$', '') WHERE id={rid}")
    su("ALTER TABLE audit_log ENABLE TRIGGER audit_no_update")
check("18. Restored row: integrity metric back to 1", wait(lambda: val("amer_audit_chain_intact") == 1, 60))

p = sum(r["pass"] for r in R); print(f"\n{p}/{len(R)} monitoring checks passed")
json.dump(R, open(os.getenv("OUT", "monitoring_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)
