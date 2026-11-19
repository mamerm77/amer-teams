"""Amer as a chat participant, live: real Synapse, real end-to-end encrypted clients (matrix-nio), the real bot
process and the real orchestrator AI engine (Guardian, Router, agents, audit). No mocks.
Without an AI provider key on this server, the model's words are replaced by the engine's own "not set up"
answer; with ANTHROPIC_API_KEY set, the same path returns the model's answer."""
import asyncio, json, os, secrets, subprocess, sys, tempfile
import httpx, psycopg
from nio import AsyncClient, AsyncClientConfig, RoomMessageText

HS, ORCH, SERVER = "http://127.0.0.1:8008", "http://127.0.0.1:8080", "amer.test"
DSN = os.getenv("DATABASE_URL", "postgresql://amer:amer-pass@127.0.0.1:5432/amer")
SYN = os.getenv("SYNAPSE_DSN", "postgresql://synapse:syn-pass@127.0.0.1:5432/synapse")
ADM = {"Authorization": "Bearer " + open("/opt/amer/admin.token").read().strip()}
SECRET = os.environ["AMER_BOT_SECRET"]; BOTUSER = os.getenv("AMER_BOT_USER", "amer")
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:220]}", flush=True)
sfx = secrets.token_hex(3); PW = "Amer-Test-Pass-1!"; U1, U2 = f"nadia{sfx}", f"omar{sfx}"; BOT = f"@{BOTUSER}:{SERVER}"

async def mk(u):
    c = AsyncClient(HS, f"@{u}:{SERVER}", store_path=tempfile.mkdtemp(), config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
    await c.login(PW); await c.sync(timeout=1000, full_state=True); return c
async def settle(*cs, n=3):
    for _ in range(n):
        for c in cs:
            await c.sync(timeout=500)
            if c.should_upload_keys: await c.keys_upload()
            if c.should_query_keys: await c.keys_query()
            if c.should_claim_keys: await c.keys_claim(c.get_users_for_key_claiming())
            for devs in c.device_store.values():
                for d in devs.values():
                    if not d.verified and d.device_id != c.device_id: c.verify_device(d)
async def send(c, room, body, **extra):
    await settle(c, n=1)
    return (await c.room_send(room, "m.room.message", {"msgtype": "m.text", "body": body, **extra}, ignore_unverified_devices=True)).event_id
async def bot_msgs(c, room, since_n, secs=40):
    got = []
    for _ in range(secs):
        await c.sync(timeout=1000)
        got = [e for e in c.rooms[room].__dict__.get("_amer", [])]
        if len(got) > since_n: break
    return got

async def main():
    async with httpx.AsyncClient(timeout=20) as h:
        for u in (U1, U2):
            assert (await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": PW})).status_code == 200
        store = tempfile.mkdtemp()
        env = {**os.environ, "HS": HS, "ORCH": ORCH, "SERVER_NAME": SERVER, "STORE_DIR": store}
        for k in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"): env.pop(k, None)
        bot = subprocess.Popen([sys.executable, "-u", os.path.join(os.path.dirname(__file__), "..", "services", "amer-bot", "bot.py")],
                               env=env, stdout=open(os.path.join(store, "log"), "w"), stderr=subprocess.STDOUT)
        for _ in range(60):
            if os.path.exists(os.path.join(store, "ready")): break
            await asyncio.sleep(1)
        check("1. Amer signs in as an encrypted chat participant", os.path.exists(os.path.join(store, "ready")), open(os.path.join(store, "log")).read()[-200:])
        a, b = await mk(U1), await mk(U2)
        inbox: dict[str, list] = {}
        def cb(room, ev):
            if ev.sender == BOT: inbox.setdefault(room.room_id, []).append(ev)
        a.add_event_callback(cb, RoomMessageText)
        async def wait_bot(room, n, secs=40):
            for _ in range(secs):
                await a.sync(timeout=1000)
                if len(inbox.get(room, [])) >= n: return inbox[room]
            return inbox.get(room, [])
        try:
            r = await h.get(f"{ORCH}/v1/ai/assistant", headers={"Authorization": f"Bearer {a.access_token}"})
            check("2. App can find the assistant account", r.json().get("user_id") == BOT and r.json().get("available") is True, r.json())
            dm = (await a.room_create(is_direct=True, invite=[BOT], initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])).room_id
            for _ in range(30):
                await a.sync(timeout=1000)
                if BOT in a.rooms[dm].users: break
            check("3. Amer joins a direct chat when invited", BOT in a.rooms[dm].users)
            await asyncio.sleep(4); await settle(a)
            await send(a, dm, "Hello Amer, what can you do?")
            msgs = await wait_bot(dm, 2)
            bodies = [m.body for m in msgs]
            check("4. Direct chat: Amer replies (privacy notice first, then the answer)", len(msgs) >= 2 and "AI service" in bodies[0], bodies)
            check("5. Without a provider key the answer says so clearly", any("not set up on this server" in x for x in bodies[1:]), bodies[1:])
            with psycopg.connect(SYN) as s:
                types = {t for (t,) in s.execute("SELECT DISTINCT type FROM events WHERE room_id=%s AND sender=%s AND state_key IS NULL", (dm, BOT)).fetchall()}
            check("6. Amer's replies are end-to-end encrypted on the server", types == {"m.room.encrypted"}, types)
            audit = (await h.get(f"{ORCH}/v1/audit", headers=ADM)).json()
            check("7. Each question is audited for the user who asked", any(x["action"] == "ai.chat" and x["user"] == f"@{U1}:{SERVER}" for x in audit))

            grp = (await a.room_create(invite=[f"@{U2}:{SERVER}", BOT], initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])).room_id
            await b.join(grp)
            for _ in range(30):
                await a.sync(timeout=1000)
                if BOT in a.rooms[grp].users and len(a.rooms[grp].users) == 3: break
            await asyncio.sleep(4); await settle(a, b)
            await send(b, grp, "Lunch at one?")
            await asyncio.sleep(10); await a.sync(timeout=1000)
            check("8. Group chat: Amer stays quiet unless mentioned", len(inbox.get(grp, [])) == 0, [m.body for m in inbox.get(grp, [])])
            await send(a, grp, "Amer please summarise this chat", **{"m.mentions": {"user_ids": [BOT]},
                       "format": "org.matrix.custom.html", "formatted_body": f'<a href="https://matrix.to/#/{BOT}">Amer</a> please summarise this chat'})
            msgs = await wait_bot(grp, 2)
            reply = msgs[-1] if msgs else None
            check("9. Group chat: Amer answers when @mentioned, as a reply", reply is not None and ((reply.source.get("content") or {}).get("m.relates_to") or {}).get("m.in_reply_to"), [m.body for m in msgs])

            await a.room_put_state(grp, "com.amerteams.sensitivity", {"label": "Confidential"})
            await asyncio.sleep(2)
            n0 = len(inbox.get(grp, []))
            await send(a, grp, "Amer summarise the confidential plan", **{"m.mentions": {"user_ids": [BOT]}})
            msgs = await wait_bot(grp, n0 + 1)
            check("10. Guardian: a chat labelled Confidential is not sent to the AI", msgs and "Blocked by policy" in msgs[-1].body, msgs[-1].body if msgs else None)

            await h.post(f"{ORCH}/v1/agents/assist", headers=ADM, json={"enabled": False})
            n0 = len(inbox.get(dm, []))
            await send(a, dm, "Are you there?")
            msgs = await wait_bot(dm, n0 + 1)
            check("11. Admin switch: pausing Amer pauses the chat assistant", msgs and "paused by an operator" in msgs[-1].body, msgs[-1].body if msgs else None)
            await h.post(f"{ORCH}/v1/agents/assist", headers=ADM, json={"enabled": True})

            r = await h.post(f"{ORCH}/v1/ai/bot", headers={"X-Bot-Secret": "wrong"}, json={"user_id": "@x:amer.test", "room_id": "!x", "prompt": "hi"})
            check("12. Only the bot service can call the bot endpoint", r.status_code == 401, r.status_code)
        finally:
            bot.terminate()
            for x in (a, b): await x.close()
    json.dump(R, open(os.getenv("OUT", "/opt/amer/amer_bot.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed")

asyncio.run(main())
