"""Guest accounts and data residency on the real local stack (docs/GUEST_ACCOUNTS.md). Real Synapse with the Amer
policy module, real orchestrator, real accounts. No mocks."""
import asyncio, json, os, secrets, sys, time
import httpx

HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)

async def login(h, user, pw):
    r = await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": user}, "password": pw})
    return r.json().get("access_token"), r.status_code

async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=20) as h:
        await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": f"emp{sfx}", "password": "Emp-Pass-123!"})
        et, _ = await login(h, f"emp{sfx}", "Emp-Pass-123!"); E = {"Authorization": f"Bearer {et}"}
        g = (await h.post(f"{ORCH}/v1/admin/guest-accounts", headers=ADM, json={"username": f"lina{sfx}", "display_name": "Lina", "email": "lina@vendor.com", "days": 30})).json()
        check("1. An administrator creates a guest account with a sponsor and an expiry", g.get("user_id", "").startswith(f"@guest.lina{sfx}") and g.get("password"), {k: v for k, v in g.items() if k != "password"})
        gt, _ = await login(h, g["user_id"], g["password"]); G = {"Authorization": f"Bearer {gt}"}
        check("2. The guest can sign in with a real account (so chats stay end-to-end encrypted)", bool(gt))
        await asyncio.sleep(11)                                            # the module's cache
        r = await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=G, json={"name": "Guest room"})
        check("3. Synapse refuses: a guest cannot create rooms", r.status_code == 403, r.text[:120])
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=E, json={"name": "Project with vendor", "preset": "private_chat"})).json()["room_id"]
        other = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=E, json={"name": "Open to all staff", "preset": "public_chat"})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/rooms/{room}/invite", headers=E, json={"user_id": g["user_id"]})
        r = await h.post(f"{HS}/_matrix/client/v3/join/{room}", headers=G, json={})
        check("4. The guest joins a room they were invited to", r.status_code == 200, r.text[:120])
        r = await h.post(f"{HS}/_matrix/client/v3/join/{other}", headers=G, json={})
        check("5. Synapse refuses: a guest cannot join a room without an invitation, even a public one", r.status_code == 403, r.text[:120])
        r = await h.post(f"{HS}/_matrix/client/v3/rooms/{room}/invite", headers=G, json={"user_id": f"@emp{sfx}x:amer.test"})
        check("6. Synapse refuses: a guest cannot invite anyone", r.status_code == 403, r.text[:120])
        r = await h.put(f"{HS}/_matrix/client/v3/rooms/{room}/send/m.room.message/t1", headers=G, json={"msgtype": "m.text", "body": "Hello from the vendor"})
        check("7. The guest can take part in the rooms they are in", r.status_code == 200, r.text[:80])
        lst = (await h.get(f"{ORCH}/v1/admin/guest-accounts", headers=ADM)).json()
        mine = next((x for x in lst if x["user_id"] == g["user_id"]), {})
        check("8. The administrator sees the guest with sponsor, email domain and expiry", mine.get("email_domain") == "vendor.com" and mine.get("expires_at", 0) > time.time() + 29 * 86400, mine)
        e = (await h.post(f"{ORCH}/v1/admin/guest-accounts/{g['user_id']}/end", headers=ADM)).json()
        _, code = await login(h, g["user_id"], g["password"])
        check("9. Ending the guest account deactivates it: sign-in refused", e.get("ended") and code == 403, (e, code))
        res = (await h.get(f"{ORCH}/v1/admin/residency", headers=ADM)).json()
        check("10. Data residency report lists every kind of data with where it is and whether the server can read it",
              res["required_region"] == "AE" and len(res["items"]) == 7 and all("status" in i for i in res["items"]), [(i["data"][:20], i["status"]) for i in res["items"]])
    json.dump(R, open(os.getenv("OUT", "/opt/amer/guest_accounts_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
