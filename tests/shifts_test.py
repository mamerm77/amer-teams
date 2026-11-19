"""Frontline shifts on the real local stack (docs/FRONTLINE.md): manager-only publishing, no overlapping shifts,
clock in/out windows, offer -> claim -> approve swap. Real Synapse power levels, orchestrator, PostgreSQL."""
import asyncio, datetime as dt, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Shift-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Shift-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
def at(m): return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=m)).replace(microsecond=0).isoformat()
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=20) as h:
        (M, m), (A, a), (B, b) = await tok(h, f"lead{sfx}"), await tok(h, f"tech{sfx}"), await tok(h, f"tech2{sfx}")
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=M, json={"name": "Field team Al Ain", "invite": [a, b]})).json()["room_id"]
        for H in (A, B): await h.post(f"{HS}/_matrix/client/v3/join/{room}", headers=H, json={})
        no = await h.post(f"{ORCH}/v1/shifts", headers=A, json={"room_id": room, "user_id": a, "start": at(5), "end": at(245)})
        check("1. Only a team manager (host) can publish shifts", no.status_code == 403, no.text[:80])
        s1 = (await h.post(f"{ORCH}/v1/shifts", headers=M, json={"room_id": room, "user_id": a, "start": at(5), "end": at(245), "role": "Splicing"})).json()
        ov = await h.post(f"{ORCH}/v1/shifts", headers=M, json={"room_id": room, "user_id": a, "start": at(200), "end": at(400)})
        check("2. The same person cannot get overlapping shifts", s1.get("id") and ov.status_code == 409, ov.text[:80])
        s2 = (await h.post(f"{ORCH}/v1/shifts", headers=M, json={"room_id": room, "user_id": a, "start": at(600), "end": at(840)})).json()
        lst = (await h.get(f"{ORCH}/v1/shifts", headers=B, params={"room_id": room})).json()
        check("3. Teammates see the rota", {x["id"] for x in lst} >= {s1["id"], s2["id"]}, len(lst))
        early = await h.post(f"{ORCH}/v1/shifts/{s2['id']}/clock", headers=A, json={"action": "in"})
        ci = (await h.post(f"{ORCH}/v1/shifts/{s1['id']}/clock", headers=A, json={"action": "in"})).json()
        check("4. Clock in opens 15 minutes before the start, not hours early", early.status_code == 409 and ci["clock_in"], early.text[:80])
        other = await h.post(f"{ORCH}/v1/shifts/{s1['id']}/clock", headers=B, json={"action": "out"})
        co = (await h.post(f"{ORCH}/v1/shifts/{s1['id']}/clock", headers=A, json={"action": "out"})).json()
        check("5. Only the assignee clocks; clock out recorded", other.status_code == 403 and co["clock_out"], other.status_code)
        await h.post(f"{ORCH}/v1/shifts/{s2['id']}/offer", headers=A)
        cl = (await h.post(f"{ORCH}/v1/shifts/{s2['id']}/claim", headers=B)).json()
        check("6. A shift is offered and a teammate claims it", cl["swap_state"] == "claimed" and cl["swap_to"] == b, cl)
        selfapp = await h.post(f"{ORCH}/v1/shifts/{s2['id']}/decide", headers=B, json={"approve": True})
        ok = (await h.post(f"{ORCH}/v1/shifts/{s2['id']}/decide", headers=M, json={"approve": True})).json()
        check("7. Only a manager approves; then the shift moves to the claimer", selfapp.status_code == 403 and ok["user_id"] == b and ok["swap_state"] == "none", ok)
        s3 = (await h.post(f"{ORCH}/v1/shifts", headers=M, json={"room_id": room, "user_id": a, "start": at(700), "end": at(800)})).json()
        await h.post(f"{ORCH}/v1/shifts/{s3['id']}/offer", headers=A); await h.post(f"{ORCH}/v1/shifts/{s3['id']}/claim", headers=B)
        clash = await h.post(f"{ORCH}/v1/shifts/{s3['id']}/decide", headers=M, json={"approve": True})
        check("8. A swap that would double-book the claimer is refused", clash.status_code == 409, clash.text[:80])
    json.dump(R, open(os.getenv("OUT", "/opt/amer/shifts_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
