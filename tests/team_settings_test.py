"""Team settings on the real stack (Teams owner/member rules, docs/TEAM_SETTINGS.md): the same power-level changes the
app's Team settings page writes, and the server (Synapse) enforcing them for a member."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Team-Pass-1234"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Team-Pass-1234"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=30) as h:
        (O, oid), (M, mid) = await tok(h, f"own{sfx}"), await tok(h, f"mem{sfx}")
        team = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=O, json={"preset": "private_chat", "invite": [mid], "creation_content": {"type": "m.space"}, "name": "Optical"})).json()["room_id"]
        ch = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=O, json={"preset": "private_chat", "invite": [mid], "name": "General"})).json()["room_id"]
        await h.put(f"{HS}/_matrix/client/v3/rooms/{team}/state/m.space.child/{ch}", headers=O, json={"via": ["amer.test"]})
        for r in (team, ch): await h.post(f"{HS}/_matrix/client/v3/join/{r}", headers=M, json={})
        pl = lambda r, X=O: h.get(f"{HS}/_matrix/client/v3/rooms/{r}/state/m.room.power_levels/", headers=X)
        async def set_pl(r, edit):
            p = (await pl(r)).json(); p.setdefault("events", {}); p.setdefault("notifications", {}); edit(p)
            return await h.put(f"{HS}/_matrix/client/v3/rooms/{r}/state/m.room.power_levels/", headers=O, json=p)
        child = lambda X, rid: h.put(f"{HS}/_matrix/client/v3/rooms/{team}/state/m.space.child/{rid}", headers=X, json={"via": ["amer.test"]})
        mine = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=M, json={"preset": "private_chat", "name": "Member channel"})).json()["room_id"]
        before = await child(M, mine)
        await set_pl(team, lambda p: p["events"].__setitem__("m.space.child", 0))
        after = await child(M, mine)
        check("1. 'Members can create channels': off → a member cannot add a channel; on → they can (server-enforced)", before.status_code == 403 and after.status_code == 200, (before.status_code, after.status_code))
        tab = lambda: h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/state/com.amerteams.channel/", headers=M, json={"tabs": ["Planner"]})
        t0 = await tab(); await set_pl(ch, lambda p: p["events"].__setitem__("com.amerteams.channel", 0)); t1 = await tab()
        check("2. 'Members can add tabs': the member's tab change is refused, then allowed", t0.status_code == 403 and t1.status_code == 200, (t0.status_code, t1.status_code))
        await set_pl(ch, lambda p: p.__setitem__("events_default", 100))
        post = await h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/send/m.room.message/t{sfx}", headers=M, json={"msgtype": "m.text", "body": "hello"})
        opost = await h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/send/m.room.message/o{sfx}", headers=O, json={"msgtype": "m.text", "body": "archived notice"})
        await set_pl(ch, lambda p: p.__setitem__("events_default", 0))
        post2 = await h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/send/m.room.message/u{sfx}", headers=M, json={"msgtype": "m.text", "body": "hello again"})
        check("3. Archive: channels become read-only for members (owners can still post); restore lets members post again", post.status_code == 403 and opost.status_code == 200 and post2.status_code == 200, (post.status_code, opost.status_code, post2.status_code))
        cheat = await h.put(f"{HS}/_matrix/client/v3/rooms/{team}/state/com.amerteams.team/", headers=M, json={"archived": False})
        check("4. A member cannot change the team settings", cheat.status_code == 403, cheat.status_code)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/team_settings_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
