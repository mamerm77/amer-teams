"""Meeting options on the real stack (Teams parity, docs/MEETING_OPTIONS.md): "Who can present" is enforced by the
server through the media token, and Do not disturb holds notifications (focus) for up to a week."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Opt-Pass-1234"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Opt-Pass-1234"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=30) as h:
        (H, hid), (A, aid), (P, pid) = await tok(h, f"orgz{sfx}"), await tok(h, f"atte{sfx}"), await tok(h, f"pres{sfx}")
        rid = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=H, json={"preset": "private_chat", "invite": [aid, pid]})).json()["room_id"]
        for X in (A, P): await h.post(f"{HS}/_matrix/client/v3/join/{rid}", headers=X, json={})
        role = lambda X: h.post(f"{ORCH}/v1/calls/token", headers=X, json={"room_id": rid, "call_id": "c1"})
        r0 = (await role(A)).json()["role"]
        st = lambda body: h.put(f"{HS}/_matrix/client/v3/rooms/{rid}/state/com.amerteams.meeting.settings/", headers=H, json=body)
        await st({"who_presents": "organisers"})
        ra, rh = (await role(A)).json()["role"], (await role(H)).json()["role"]
        check("1. 'Who can present: only organisers': attendees get a listen-only media token; organisers present", r0 == "presenter" and ra == "attendee" and rh == "presenter", (r0, ra, rh))
        await st({"who_presents": "specific", "presenters": [pid]})
        rp, ra2 = (await role(P)).json()["role"], (await role(A)).json()["role"]
        check("2. 'Specific people': the chosen presenter can present, others cannot", rp == "presenter" and ra2 == "attendee", (rp, ra2))
        cheat = await h.put(f"{HS}/_matrix/client/v3/rooms/{rid}/state/com.amerteams.meeting.settings/", headers=A, json={"who_presents": "everyone"})
        check("3. An attendee cannot change the meeting options (the server refuses the change)", cheat.status_code == 403, cheat.status_code)
        f = await h.post(f"{ORCH}/v1/notify/focus", headers=A, json={"minutes": 24 * 60})
        check("4. Do not disturb holds notifications for up to a week (a day here)", f.status_code == 200 and f.json()["focus_until"] > 0, f.text[:100])
    json.dump(R, open(os.getenv("OUT", "/opt/amer/meeting_options_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
