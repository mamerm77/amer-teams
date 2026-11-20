"""Join a team with a code, on the real stack (Teams parity): the same calls the app makes. Owner publishes a code
(alias) and sets the team to 'knock'; someone asks to join with the code; only owners can approve; approved people join."""
import asyncio, json, os, secrets, sys, urllib.parse
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Code-Pass-1234"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Code-Pass-1234"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3); code = f"t{sfx}"[:7]
    async with httpx.AsyncClient(timeout=30) as h:
        (O, oid), (A, aid), (M, mid) = await tok(h, f"owner{sfx}"), await tok(h, f"asker{sfx}"), await tok(h, f"memb{sfx}")
        team = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=O, json={"preset": "private_chat", "invite": [mid], "creation_content": {"type": "m.space"}, "name": "Optical", "power_level_content_override": {"invite": 50}})).json()["room_id"]   # as the app creates private teams
        await h.post(f"{HS}/_matrix/client/v3/join/{team}", headers=M, json={})
        alias = f"#team-{code}:amer.test"; qa = urllib.parse.quote(alias)
        await h.put(f"{HS}/_matrix/client/v3/directory/room/{qa}", headers=O, json={"room_id": team})
        await h.put(f"{HS}/_matrix/client/v3/rooms/{team}/state/m.room.join_rules/", headers=O, json={"join_rule": "knock"})
        direct = await h.post(f"{HS}/_matrix/client/v3/join/{qa}", headers=A, json={})
        rid = (await h.get(f"{HS}/_matrix/client/v3/directory/room/{qa}", headers=A)).json().get("room_id")
        k = await h.post(f"{HS}/_matrix/client/v3/knock/{qa}", headers=A, json={"reason": "Joined with the team code"})
        check("1. With the code, a person finds the team and asks to join; they cannot just walk in", rid == team and direct.status_code == 403 and k.status_code == 200, (rid == team, direct.status_code, k.status_code))
        mem = (await h.get(f"{HS}/_matrix/client/v3/rooms/{team}/state/m.room.member/{urllib.parse.quote(aid)}", headers=O)).json()
        check("2. The owners see the request (membership 'knock')", mem.get("membership") == "knock", mem)
        bad = await h.post(f"{HS}/_matrix/client/v3/rooms/{team}/invite", headers=M, json={"user_id": aid})
        check("3. A member who is not an owner cannot approve it", bad.status_code == 403, bad.status_code)
        ok = await h.post(f"{HS}/_matrix/client/v3/rooms/{team}/invite", headers=O, json={"user_id": aid})
        j = await h.post(f"{HS}/_matrix/client/v3/join/{team}", headers=A, json={})
        check("4. The owner approves; the person joins the team", ok.status_code == 200 and j.status_code == 200, (ok.status_code, j.status_code))
        wrong = await h.get(f"{HS}/_matrix/client/v3/directory/room/{urllib.parse.quote('#team-zzzzzzz:amer.test')}", headers=A)
        check("5. A wrong code finds nothing", wrong.status_code == 404, wrong.status_code)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/team_code_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
