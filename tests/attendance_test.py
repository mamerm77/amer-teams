"""Meeting attendance report on the real stack (Teams parity): two people really join the media server, one leaves
early; LiveKit's signed webhooks are the only source. Organisers see who attended, when and for how long; other
attendees cannot see the report."""
import asyncio, json, os, secrets, sys
import httpx
from livekit import rtc
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Att-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Att-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=30) as h:
        (H, hid), (B, bid) = await tok(h, f"org{sfx}"), await tok(h, f"att{sfx}")
        rid = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=H, json={"preset": "private_chat", "invite": [bid], "name": "Weekly sync"})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/join/{rid}", headers=B, json={})
        cid = secrets.token_hex(6)
        ta = (await h.post(f"{ORCH}/v1/calls/token", headers=H, json={"room_id": rid, "call_id": cid})).json()
        tb = (await h.post(f"{ORCH}/v1/calls/token", headers=B, json={"room_id": rid, "call_id": cid})).json()
        ra, rb = rtc.Room(), rtc.Room()
        await ra.connect("ws://127.0.0.1:7880", ta["token"]); await asyncio.sleep(1)
        await rb.connect("ws://127.0.0.1:7880", tb["token"]); await asyncio.sleep(4)
        await rb.disconnect(); await asyncio.sleep(2)
        await ra.disconnect()
        rep = {}
        for _ in range(15):
            rep = (await h.get(f"{ORCH}/v1/meetings/attendance/{rid}", headers=H)).json()
            m = rep.get("meetings", [])
            if m and all(p["last_leave"] for p in m[0]["people"]) and m[0]["attendees"] == 2: break
            await asyncio.sleep(1)
        m = (rep.get("meetings") or [{}])[0]; ppl = {p["user_id"]: p for p in m.get("people", [])}
        check("1. The organiser sees both attendees of the meeting", set(ppl) == {hid, bid}, list(ppl))
        check("2. Join order and times come from the media server: the organiser joined first", ppl and ppl[hid]["first_join"] <= ppl[bid]["first_join"], ppl)
        check("3. Time in the meeting: the person who left early has less (about 4 s vs about 7 s)", ppl and 2 <= ppl[bid]["seconds"] <= 8 and ppl[hid]["seconds"] > ppl[bid]["seconds"], {k: v["seconds"] for k, v in ppl.items()})
        nb = await h.get(f"{ORCH}/v1/meetings/attendance/{rid}", headers=B)
        check("4. Attendees who are not organisers cannot see the report", nb.status_code == 403, nb.status_code)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/attendance_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
