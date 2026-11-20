"""Virtual office on the real stack (docs/VIRTUAL_OFFICE.md): staff seeded, a request reaches the Chief of Staff,
the conversation and statuses are recorded, Guardian blocks labelled content, agents can be renamed or switched off.
The local stack has no AI provider key, so the model step answers with that error; with a key the same path plans
and delegates."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def main():
    u = f"boss{secrets.token_hex(3)}"
    async with httpx.AsyncClient(timeout=30) as h:
        await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Office-Pass-1!"})
        t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Office-Pass-1!"})).json()["access_token"]
        H = {"Authorization": f"Bearer {t}"}
        o = (await h.get(f"{ORCH}/v1/office", headers=H)).json()
        check("1. Your staff is ready: a Chief of Staff, nine specialists and the five Teams agents, all available", len(o["agents"]) == 15 and o["agents"][0]["role"] == "Chief of Staff" and all(a["status"] == "available" for a in o["agents"]), [a["name"] for a in o["agents"]])
        b = await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Summarise the vendor pricing", "labels": ["confidential"]})
        check("2. Guardian blocks a Confidential request before any agent sees it", b.status_code == 403, b.text[:100])
        r = (await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Prepare me for Monday's DWDM vendor review: agenda, key risks, a budget view."})).json()
        await asyncio.sleep(3)
        d = (await h.get(f"{ORCH}/v1/office/tasks/{r['task']}", headers=H)).json()
        conv = d["conversation"]
        check("3. The request goes to the Chief of Staff and the hand-over is recorded in the team room", conv and conv[0]["sender"] == "you" and conv[0]["recipient"] == "chief", conv[:2])
        check("4. Without an AI provider key the team says so plainly (no silent failure)", d["status"] == "failed" and "ANTHROPIC_API_KEY" in (d["result"] or ""), d["result"])
        o = (await h.get(f"{ORCH}/v1/office", headers=H)).json()
        check("5. Statuses return to available when the work stops", all(a["status"] == "available" for a in o["agents"]))
        await h.patch(f"{ORCH}/v1/office/agents/health", headers=H, json={"enabled": False, "name": "Dana"})
        no = await h.patch(f"{ORCH}/v1/office/agents/chief", headers=H, json={"enabled": False})
        o = (await h.get(f"{ORCH}/v1/office", headers=H)).json(); hv = next(a for a in o["agents"] if a["id"] == "health")
        check("6. You can rename or switch off a specialist, not the Chief of Staff", hv["name"] == "Dana" and not hv["enabled"] and no.status_code == 422)
        d1 = (await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Draft a short note about OSNR margins", "agent": "writer"})).json()
        await asyncio.sleep(2)
        dd = (await h.get(f"{ORCH}/v1/office/tasks/{d1['task']}", headers=H)).json()
        check("7. You can also ask one agent directly", dd["agent"] == "writer" and dd["conversation"][0]["recipient"] == "writer")
    json.dump(R, open(os.getenv("OUT", "/opt/amer/office_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
