"""Attendees' local times (Teams scheduling parity), on the real stack: each person's app publishes its time zone with
working hours; the meeting details ask for everyone's local time at the meeting's start."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Tz-Pass-12345"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Tz-Pass-12345"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    s = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=30) as h:
        (A, a), (B, b), (C, c) = await tok(h, f"dxb{s}"), await tok(h, f"cai{s}"), await tok(h, f"none{s}")
        work = {"days": [0, 1, 2, 3, 4], "start": "08:00", "end": "17:00"}
        r1 = await h.put(f"{ORCH}/v1/calendar/freebusy", headers=A, json={"busy": [], "tz": "Asia/Dubai", "work": work})
        r2 = await h.put(f"{ORCH}/v1/calendar/freebusy", headers=B, json={"busy": [], "tz": "Africa/Cairo", "work": work})
        z = (await h.post(f"{ORCH}/v1/calendar/timezones", headers=A, json={"users": [a, b, c], "at": "2026-11-23T06:00:00Z"})).json()
        check("1. Each attendee's time zone, as their app published it", r1.status_code == 200 and r2.status_code == 200 and z.get(a, {}).get("tz") == "Asia/Dubai" and z.get(b, {}).get("tz") == "Africa/Cairo", z)
        check("2. Their local time for the meeting: 06:00 UTC is 10:00 in Dubai and 08:00 in Cairo", z.get(a, {}).get("local") == "Mon 10:00" and z.get(b, {}).get("local") == "Mon 08:00", z)
        check("3. Someone who has not published a time zone is simply left out", c not in z, list(z))
    json.dump(R, open(os.getenv("OUT", "/opt/amer/timezones_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
