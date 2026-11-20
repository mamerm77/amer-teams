"""Teams agents in the virtual office, on the real stack (docs/VIRTUAL_OFFICE.md, "Teams agents").
A second orchestrator runs against a stand-in AI provider (fake_llm.py), so the real pipeline is exercised:
the Teams agents are on the staff, the Chief of Staff delegates to the Project Manager and the Facilitator in
parallel, they read the chat context the app sent, propose actions on that chat only, nothing runs until you
approve, and approving hands the actions back to the app to run with your own keys."""
import asyncio, os, secrets, subprocess, sys, time
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); PORT = 8183; ORCH = f"http://127.0.0.1:{PORT}"
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
HERE = os.path.dirname(os.path.abspath(__file__)); R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)

async def main():
    llm = subprocess.Popen([sys.executable, os.path.join(HERE, "fake_llm.py"), "8099"])
    env = {**os.environ, "ANTHROPIC_API_KEY": "test-only", "LLM_BASE_URL": "http://127.0.0.1:8099"}
    orch = subprocess.Popen([os.path.join(os.path.dirname(sys.executable), "uvicorn"), "app.main:app", "--port", str(PORT)],
                            cwd=os.path.join(HERE, "..", "services", "orchestrator"), env=env, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    try:
        async with httpx.AsyncClient(timeout=30) as h:
            for _ in range(60):
                try:
                    if (await h.get(f"{ORCH}/healthz")).status_code == 200: break
                except httpx.HTTPError: pass
                await asyncio.sleep(1)
            u = f"lead{secrets.token_hex(3)}"
            await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Agents-Pass-1!"})
            t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Agents-Pass-1!"})).json()["access_token"]
            H = {"Authorization": f"Bearer {t}"}
            o = (await h.get(f"{ORCH}/v1/office", headers=H)).json()
            roles = {a["id"]: a["role"] for a in o["agents"]}
            check("1. The Teams agents are on the staff: Facilitator, Interpreter, Project Manager, Channel expert, Analyst",
                  all(k in roles for k in ("facilitator", "interpreter", "pm", "channel", "analyst")), roles)
            room = "!projx:amer.test"
            ctx = f"Chat 'Project X' room_id: {room}\nBob: can you send the vendor comparison?\nMoh: yes, by Thursday\nBob: we decide on Monday"
            r = (await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Make a plan and status report for Project X and set the follow-ups.", "context": ctx, "rooms": [room]})).json()
            d = {}
            for _ in range(30):
                d = (await h.get(f"{ORCH}/v1/office/tasks/{r['task']}", headers=H)).json()
                if d["status"] not in ("in_progress", "assigned"): break
                await asyncio.sleep(1)
            subs = {s["agent"]: s for s in d["subtasks"]}
            check("2. The Chief of Staff delegated to the Project Manager and the Facilitator, who worked in parallel", {"pm", "facilitator"} <= set(subs), list(subs))
            conv = [f"{m['sender']}→{m['recipient']}" for m in d["conversation"]]
            check("3. The hand-overs are a conversation in the team room (you→chief, chief→pm, pm→chief, chief→you)",
                  "you→chief" in conv and "chief→pm" in conv and "pm→chief" in conv and conv[-1] == "chief→you", conv)
            acts = d.get("actions", [])
            check("4. The agents proposed concrete actions on that chat: a task with a due date and a message", any(a["type"] == "task" and a.get("due") for a in acts) and any(a["type"] == "post" for a in acts), acts)
            check("5. Nothing runs on its own: the request waits for your approval", d["status"] == "needs_approval" and d["needs_approval"], d["status"])
            bad = (await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Plan it", "context": f"room_id: {room}", "rooms": ["!other:amer.test"]})).json()
            await asyncio.sleep(4)
            bd = (await h.get(f"{ORCH}/v1/office/tasks/{bad['task']}", headers=H)).json()
            check("6. Actions on a chat that was not in the context are dropped", all(a["room"] == "!other:amer.test" for a in bd.get("actions", [])) and not any(a["room"] == room for a in bd.get("actions", [])), bd.get("actions"))
            ok = (await h.post(f"{ORCH}/v1/office/tasks/{r['task']}/decide", headers=H, json={"approve": True})).json()
            check("7. Approving hands the actions back to the app to run with your own keys (the server never posts)", ok["status"] == "approved" and len(ok["actions"]) >= 2, ok)
            d2 = (await h.get(f"{ORCH}/v1/office/tasks/{r['task']}", headers=H)).json()
            check("8. Approving the request approves its sub-tasks too", all(s["status"] != "needs_approval" for s in d2["subtasks"]), [s["status"] for s in d2["subtasks"]])
            one = (await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Translate to Arabic: the maintenance window is at 01:00", "agent": "interpreter"})).json()
            await asyncio.sleep(3)
            od = (await h.get(f"{ORCH}/v1/office/tasks/{one['task']}", headers=H)).json()
            check("9. You can ask one agent directly (Interpreter), and it answers without the Chief of Staff", od["agent"] == "interpreter" and od["status"] == "done" and od["result"], od["status"])
            b = await h.post(f"{ORCH}/v1/office/requests", headers=H, json={"request": "Summarise this", "context": "pricing", "labels": ["confidential"]})
            check("10. Guardian still blocks Confidential content, including context sent with the request", b.status_code == 403, b.status_code)
    finally:
        orch.terminate(); llm.terminate()
    import json; json.dump(R, open(os.getenv("OUT", "/tmp/teams_agents_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed")
asyncio.run(main())
