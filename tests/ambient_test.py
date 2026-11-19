"""Ambient presence rooms on the real stack (docs/AMBIENT.md): a real LiveKit participant joins the team room and
members of the chat can see them before joining; non-members cannot."""
import asyncio, json, os, secrets, sys
import httpx
from livekit import rtc
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Amb-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Amb-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=20) as h:
        (A, a), (B, b), (X, x) = await tok(h, f"amira{sfx}"), await tok(h, f"bilal{sfx}"), await tok(h, f"out{sfx}")
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=A, json={"name": "Transport team", "invite": [b]})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/join/{room}", headers=B, json={})
        empty = (await h.get(f"{ORCH}/v1/ambient/{room}", headers=B)).json()
        check("1. Before anyone joins, the team room is empty", empty["here"] == [] and empty["call_id"] == f"meet-ambient-{room}", empty)
        t = (await h.post(f"{ORCH}/v1/calls/token", headers=A, json={"room_id": room, "call_id": f"meet-ambient-{room}", "display_name": "Amira"})).json()
        lk = rtc.Room(); await lk.connect(os.getenv("LK_WS", "ws://127.0.0.1:7880"), t["token"])
        here = []
        for _ in range(10):
            here = (await h.get(f"{ORCH}/v1/ambient/{room}", headers=B)).json()["here"]
            if here: break
            await asyncio.sleep(1)
        check("2. A teammate sees who is in the team room without joining (from the media server)", [p["name"] for p in here] == ["Amira"], here)
        out = await h.get(f"{ORCH}/v1/ambient/{room}", headers=X)
        check("3. Someone outside the chat cannot see who is there", out.status_code == 403, out.status_code)
        await lk.disconnect(); await asyncio.sleep(2)
        after = (await h.get(f"{ORCH}/v1/ambient/{room}", headers=B)).json()["here"]
        check("4. After they leave, the room shows empty again", after == [], after)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/ambient_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
