"""Tool connectors on the real stack (docs/TOOL_CONNECTORS.md): a person (real end-to-end encrypted client) adds a
connector, invites the connectors account, a tool posts a GitHub/Alertmanager webhook, and the person decrypts the
formatted message. Wrong secrets and chats without a connector are refused."""
import asyncio, json, os, secrets, sys, tempfile
import httpx
from nio import AsyncClient, AsyncClientConfig, RoomMessageNotice
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080"); HOOKS = os.getenv("HOOKS", "http://127.0.0.1:8070")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def main():
    sfx = secrets.token_hex(3); u = f"devops{sfx}"; pw = "Conn-Test-123!"
    async with httpx.AsyncClient(timeout=30) as h:
        await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": pw})
        c = AsyncClient(HS, f"@{u}:amer.test", store_path=tempfile.mkdtemp(), config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
        await c.login(pw); await c.sync(timeout=3000)
        if c.should_upload_keys: await c.keys_upload()
        r = await c.room_create(name="Release train", initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])
        room = r.room_id; H = {"Authorization": f"Bearer {c.access_token}"}
        stray = (await c.room_create(name="No connector")).room_id
        cn = (await h.post(f"{ORCH}/v1/connectors", headers=H, json={"room_id": room, "kind": "github", "name": "GitHub"})).json()
        check("1. A chat host adds a connector and gets a secret webhook URL", cn["path"].startswith(f"/hooks/{cn['id']}/") and cn["invite"] == "@connectors:amer.test", {k: cn[k] for k in ("id", "invite")})
        await c.room_invite(stray, "@connectors:amer.test"); await c.room_invite(room, "@connectors:amer.test")
        joined = False
        for _ in range(20):
            await c.sync(timeout=2000)
            mem = await c.joined_members(room); joined = any(m.user_id == "@connectors:amer.test" for m in getattr(mem, "members", []))
            if joined: break
        sm = await c.joined_members(stray)
        check("2. The connectors account joins the chat with a connector, and refuses one without", joined and not any(m.user_id == "@connectors:amer.test" for m in getattr(sm, "members", [])))
        bad = await h.post(f"{HOOKS}/hooks/{cn['id']}/wrong-secret", json={"text": "x"})
        check("3. A webhook with the wrong secret is refused", bad.status_code == 403, bad.status_code)
        await asyncio.sleep(3)
        payload = {"ref": "refs/heads/main", "repository": {"full_name": "eand/optical-planner"}, "pusher": {"name": "moh"},
                   "commits": [{"message": "Add Super C+L span budget\n\nbody", "author": {"name": "Moh"}}, {"message": "Fix OSNR rounding", "author": {"name": "Sara"}}]}
        ok = await h.post(f"{HOOKS}{cn['path']}", json=payload, headers={"X-GitHub-Event": "push"})
        check("4. The tool's webhook is accepted and posted", ok.status_code == 200 and ok.json().get("event_id"), ok.text[:120])
        got = None
        for _ in range(20):
            s = await c.sync(timeout=2000)
            for ev in (s.rooms.join.get(room).timeline.events if room in s.rooms.join else []):
                if isinstance(ev, RoomMessageNotice) and "pushed" in ev.body: got = ev
            if got: break
        check("5. The person decrypts it: an end-to-end encrypted, readable summary", got and got.body.startswith("[GitHub] ⬆️ moh pushed 2 commit(s) to eand/optical-planner main") and "Add Super C+L span budget (Moh)" in got.body, got.body if got else None)
        lst = (await h.get(f"{ORCH}/v1/connectors", headers=H, params={"room_id": room})).json()
        check("6. The chat lists its connectors with use count", lst and lst[0]["uses"] == 1, lst)
        await h.delete(f"{ORCH}/v1/connectors/{cn['id']}", headers=H)
        gone = await h.post(f"{HOOKS}{cn['path']}", json=payload, headers={"X-GitHub-Event": "push"})
        check("7. After removing the connector, its URL stops working", gone.status_code == 403, gone.status_code)
        await c.close()
    json.dump(R, open(os.getenv("OUT", "/opt/amer/connectors_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
