"""Operator mode on the real local stack (docs/OPERATOR_MODE.md): rota, declare, page, acknowledge, states, MTTA/MTTR,
Alertmanager webhook opening and resolving an incident. Real orchestrator and Postgres. No mocks."""
import asyncio, datetime as dt, json, os, re, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
SECRET = os.getenv("AMER_ALERT_SECRET") or re.search(r"AMER_ALERT_SECRET=(\S+)", open("/opt/amer/orch.env").read()).group(1)
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)

async def main():
    sfx = secrets.token_hex(3); svc = f"DWDM core {sfx}"
    async with httpx.AsyncClient(timeout=20) as h:
        users = []
        for n in ("noc1", "noc2", "noc3"):
            await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": f"{n}{sfx}", "password": "Noc-Pass-123!"}); users.append(f"@{n}{sfx}:amer.test")
        tok = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": f"noc2{sfx}"}, "password": "Noc-Pass-123!"})).json()["access_token"]
        U = {"Authorization": f"Bearer {tok}"}
        start = dt.date.today() - dt.timedelta(days=8)          # second week of the rota: noc2 is on call
        r = (await h.put(f"{ORCH}/v1/oncall/rotas", headers=ADM, json={"service": svc, "members": users, "starts": str(start), "days_each": 7, "escalation": users[2]})).json()
        check("1. A weekly on-call rota gives the right person this week", r["on_call"] == users[1], r)
        oc = {x["service"]: x for x in (await h.get(f"{ORCH}/v1/oncall", headers=U)).json()}
        check("2. Anyone can see who is on call now and next", oc[svc]["on_call"] == users[1] and oc[svc]["next"] == users[2], oc[svc])
        d = (await h.post(f"{ORCH}/v1/incidents", headers=U, json={"severity": "P1", "service": svc})).json()
        check("3. Declaring an incident gives a number and who to page", re.match(r"^INC-\d{4}-\d{4}$", d["number"]) and d["on_call"] == users[1] and d["escalation"] == users[2], d)
        d2 = (await h.post(f"{ORCH}/v1/incidents", headers=U, json={"severity": "P3", "service": svc})).json()
        check("4. Incident numbers are sequential", int(d2["number"][-4:]) == int(d["number"][-4:]) + 1, (d["number"], d2["number"]))
        await asyncio.sleep(1.2)
        a = (await h.post(f"{ORCH}/v1/incidents/{d['number']}", headers=U, json={"ack": True})).json()
        check("5. Acknowledge records who and when (MTTA)", a["acked_by"] == users[1] and a["acked_at"] >= a["declared_at"], a)
        b = await h.post(f"{ORCH}/v1/incidents/{d['number']}", headers=U, json={"state": "mitigated"})
        bad = await h.post(f"{ORCH}/v1/incidents/{d['number']}", headers=U, json={"state": "investigating"})
        check("6. States move forward only (mitigated cannot go back to investigating)", b.status_code == 200 and bad.status_code == 409, bad.text[:80])
        c = (await h.post(f"{ORCH}/v1/incidents/{d['number']}", headers=U, json={"state": "resolved"})).json()
        check("7. Resolving stamps the time", c["state"] == "resolved" and c["resolved_at"] and c["mitigated_at"], c)
        m = (await h.get(f"{ORCH}/v1/incidents/metrics", headers=U)).json()
        check("8. MTTA and MTTR by severity", m.get("P1", {}).get("mtta_min") is not None and m["P1"]["mttr_min"] >= m["P1"]["mtta_min"], m.get("P1"))
        fp = f"fp{sfx}"
        no = await h.post(f"{ORCH}/v1/alerts/webhook", json={"alerts": []}, headers={"X-Amer-Alert": "wrong"})
        check("9. The alert webhook refuses callers without the secret", no.status_code == 401, no.status_code)
        alert = {"status": "firing", "fingerprint": fp, "labels": {"alertname": "OchOsnrLow", "severity": "critical", "service": svc}}
        w = (await h.post(f"{ORCH}/v1/alerts/webhook", json={"alerts": [alert]}, headers={"X-Amer-Alert": SECRET})).json()
        w2 = (await h.post(f"{ORCH}/v1/alerts/webhook", json={"alerts": [alert]}, headers={"X-Amer-Alert": SECRET})).json()
        opened = w["results"][0].get("opened") if w["results"] else None
        check("10. A critical alert opens a P1 incident once (repeats do not duplicate)", opened and w2["results"] == [], (w, w2))
        lst = {i["number"]: i for i in (await h.get(f"{ORCH}/v1/incidents?open_only=true", headers=U)).json()}
        check("11. The alert's incident waits for its war room", opened in lst and lst[opened]["source"] == "alert" and lst[opened]["severity"] == "P1" and not lst[opened]["room_hash"], lst.get(opened))
        w3 = (await h.post(f"{ORCH}/v1/alerts/webhook", json={"alerts": [{**alert, "status": "resolved"}]}, headers={"X-Amer-Alert": SECRET})).json()
        check("12. The alert clearing resolves its incident", w3["results"] == [{"resolved": opened}], w3)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/operator_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
