"""Amer Teams — user creation and registration tests against live servers over TLS (no mocks).

Exercises exactly what the app does: Matrix User-Interactive Auth with stage
m.login.registration_token, plus the orchestrator admin API.
"""
import asyncio, json, os, secrets, ssl, sys, tempfile
import httpx, psycopg
from nio import AsyncClient, AsyncClientConfig, RoomMessageText

BASE = os.getenv("BASE", "https://teams.amer.test:8443"); CA = os.getenv("CA", "/opt/amer/ca.crt")
HS, ORCH = BASE, BASE + "/api"
ADMIN_PW = os.getenv("ADMIN_PW", "Adm1n-Pass!2026")
AMER_DB = os.getenv("AMER_DB", "postgresql://amer:amer-pass@127.0.0.1/amer")
SYN_DB = os.getenv("SYN_DB", "postgresql://synapse:syn-pass@127.0.0.1/synapse")
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)

GOOD = "Optical-Net#2026"
sfx = secrets.token_hex(3)

async def register(h, user, pw, token=None):
    """Two-step UIA, as the app does. Returns (status, json)."""
    r = await h.post(f"{HS}/_matrix/client/v3/register", json={"username": user, "password": pw, "initial_device_display_name": "reg-test"})
    if r.status_code != 401 or token is None: return r.status_code, r.json()
    sess = r.json()["session"]
    # Complete every UIA stage the server asks for (registration_token, then dummy)
    for _ in range(4):
        done = set(r.json().get("completed", []))
        flow = r.json()["flows"][0]["stages"]
        nxt = next((s for s in flow if s not in done), None)
        auth = {"type": nxt, "session": sess}
        if nxt == "m.login.registration_token": auth["token"] = token
        r = await h.post(f"{HS}/_matrix/client/v3/register", json={"username": user, "password": pw, "auth": auth})
        if r.status_code != 401 or "flows" not in r.json() or set(r.json().get("completed", [])) == done: break
    return r.status_code, r.json()

async def login(h, user, pw):
    r = await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": user}, "password": pw})
    return r.status_code, r.json()

async def main():
    async with httpx.AsyncClient(verify=CA, timeout=20) as h:
        _, a = await login(h, "admin", ADMIN_PW); A = {"Authorization": f"Bearer {a['access_token']}"}
        _, m = await login(h, "moh", "Pass-moh-123"); M = {"Authorization": f"Bearer {m['access_token']}"}

        # --- registration policy ---
        flows = (await h.post(f"{HS}/_matrix/client/v3/register", json={})).json()
        stages = [s for f in flows.get("flows", []) for s in f["stages"]]
        check("1. Server requires an invite code to register", "m.login.registration_token" in stages and all("m.login.registration_token" in f["stages"] for f in flows["flows"]), stages)
        st, j = await register(h, f"nocode{sfx}", GOOD)
        check("2. Sign-up without invite code refused", st == 401 and "access_token" not in j, f"HTTP {st}")

        # --- invite codes via admin API ---
        r = await h.post(f"{ORCH}/v1/admin/invites", headers=M, json={"uses_allowed": 1})
        check("3. Non-admin cannot create invite codes", r.status_code == 403, f"HTTP {r.status_code}")
        r = await h.post(f"{ORCH}/v1/admin/invites", headers=A, json={"uses_allowed": 1, "expiry_days": 7})
        code = r.json().get("token")
        check("4. Admin creates single-use invite code", r.status_code == 200 and code, code)

        st, j = await register(h, f"sara{sfx}", GOOD, token="WRONG-" + secrets.token_hex(3))
        check("5. Invalid invite code refused", st == 401 and "access_token" not in j, j.get("errcode", st))

        # --- password policy ---
        bad = {"short": "Ab1!", "no digit": "Optical-Net#", "no symbol": "OpticalNet2026", "no upper": "optical-net#2026", "no lower": "OPTICAL-NET#2026"}
        res = {k: (await register(h, f"weak{sfx}", v, token=code)) for k, v in bad.items()}
        check("6. Weak passwords refused (5 rules)", all(s_ == 400 for s_, _ in res.values()),
              ", ".join(f"{k}:{j_.get('errcode','')}" for k, (s_, j_) in res.items()))
        bad_name = await register(h, "Bad Name!", GOOD, token=code)
        check("7. Invalid username refused", bad_name[0] == 400, bad_name[1].get("errcode"))

        # --- successful self-registration ---
        avail = (await h.get(f"{HS}/_matrix/client/v3/register/available", params={"username": f"sara{sfx}"})).json()
        check("8. Username availability check", avail.get("available") is True)
        st, j = await register(h, f"sara{sfx}", GOOD, token=code)
        sara = j.get("user_id")
        check("9. Self-registration with invite code succeeds", st == 200 and j.get("access_token"), sara)
        st2, j2 = await register(h, f"omar{sfx}", GOOD, token=code)
        check("10. Single-use code cannot be reused", st2 == 401 and "access_token" not in j2, f"HTTP {st2}")
        st3, j3 = await register(h, f"sara{sfx}", GOOD)
        check("11. Duplicate username refused", st3 == 400 and j3.get("errcode") == "M_USER_IN_USE", j3.get("errcode"))
        st, _ = await login(h, f"sara{sfx}", GOOD)
        check("12. New user signs in", st == 200)
        inv = {t["token"]: t for t in (await h.get(f"{ORCH}/v1/admin/invites", headers=A)).json()}
        check("13. Invite usage recorded (1/1)", inv.get(code, {}).get("completed") == 1)

        # --- admin-created user ---
        r = await h.post(f"{ORCH}/v1/admin/users", headers=A, json={"username": f"omar{sfx}", "password": GOOD, "display_name": "Omar Khalil"})
        omar = r.json().get("user_id")
        check("14. Admin creates a user directly", r.status_code == 200, omar)
        r = await h.post(f"{ORCH}/v1/admin/users", headers=A, json={"username": f"omar{sfx}", "password": GOOD})
        check("15. Admin cannot create a duplicate user", r.status_code == 409)
        st, oj = await login(h, f"omar{sfx}", GOOD)
        prof = (await h.get(f"{HS}/_matrix/client/v3/profile/{omar}")).json()
        check("16. Admin-created user signs in, display name set", st == 200 and prof.get("displayname") == "Omar Khalil")
        users = {u["user_id"]: u for u in (await h.get(f"{ORCH}/v1/admin/users", headers=A)).json()}
        check("17. Both new users listed", sara in users and omar in users, f"{len(users)} accounts")
        r = await h.get(f"{ORCH}/v1/admin/users", headers=M)
        check("18. Non-admin cannot list users", r.status_code == 403)

    # --- new users can use the product: encrypted chat end to end ---
    ctx = ssl.create_default_context(cafile=CA)
    cs = []
    for u in (f"sara{sfx}", f"omar{sfx}"):
        c = AsyncClient(HS, f"@{u}:amer.test", store_path=tempfile.mkdtemp(), ssl=ctx, config=AsyncClientConfig(encryption_enabled=True))
        await c.login(GOOD, device_name="reg-e2e"); cs.append(c)
    s_, o_ = cs
    for _ in range(2): await asyncio.gather(*[c.sync(timeout=1500, full_state=True) for c in cs])
    rid = (await s_.room_create(name="new-users", invite=[omar])).room_id
    await asyncio.gather(*[c.sync(timeout=1500) for c in cs]); await o_.join(rid)
    for _ in range(3): await asyncio.gather(*[c.sync(timeout=1500, full_state=True) for c in cs])
    for c in cs:
        if c.should_upload_keys: await c.keys_upload()
    for _ in range(2): await asyncio.gather(*[c.sync(timeout=1500, full_state=True) for c in cs])
    for c in cs:
        if c.should_query_keys: await c.keys_query()
        for devs in c.device_store.values():
            for d in devs.values():
                if d.device_id != c.device_id: c.verify_device(d)
    txt = "hello-" + secrets.token_hex(3); got = {}
    o_.add_event_callback(lambda r_, e: got.update(b=e.body) if e.body == txt else None, RoomMessageText)
    await s_.room_send(rid, "m.room.message", {"msgtype": "m.text", "body": txt}, ignore_unverified_devices=True)
    for _ in range(10):
        if got: break
        await o_.sync(timeout=1500)
    check("19. New users exchange an encrypted message", got.get("b") == txt)
    for c in cs: await c.close()
    with psycopg.connect(SYN_DB) as c:
        dev = c.execute("SELECT count(*) FROM e2e_device_keys_json WHERE user_id IN (%s,%s)", (sara, omar)).fetchone()[0]
        hashed = c.execute("SELECT password_hash LIKE '$2b$%%' FROM users WHERE name=%s", (omar,)).fetchone()[0]
    check("20. New users' encryption device keys stored", dev >= 2, f"{dev} device key set(s)")
    check("21. Password stored bcrypt-hashed, never plain", hashed is True)

    async with httpx.AsyncClient(verify=CA, timeout=20) as h:
        NEW = "Fresh-Pass#7788"
        r = await h.post(f"{ORCH}/v1/admin/users/{omar}/password", headers=A, json={"password": NEW})
        old_ok = (await login(h, f"omar{sfx}", GOOD))[0] == 200; new_ok = (await login(h, f"omar{sfx}", NEW))[0] == 200
        old_session = (await h.get(f"{HS}/_matrix/client/v3/account/whoami", headers={"Authorization": f"Bearer {oj['access_token']}"})).status_code
        check("22. Password reset: old fails, new works, old sessions signed out", r.status_code == 200 and not old_ok and new_ok and old_session == 401)
        r = await h.post(f"{ORCH}/v1/admin/users/{sara}/deactivate", headers=A)
        st, j = await login(h, f"sara{sfx}", GOOD)
        check("23. Deactivated user cannot sign in", r.status_code == 200 and st == 403, j.get("errcode"))
        r = await h.post(f"{ORCH}/v1/admin/users/@admin:amer.test/deactivate", headers=A)
        check("24. Admin cannot deactivate own account", r.status_code == 400)

    # --- database records ---
    with psycopg.connect(SYN_DB) as c:
        row = c.execute("SELECT deactivated, password_hash IS NULL FROM users WHERE name=%s", (sara,)).fetchone()
        devs = c.execute("SELECT count(*) FROM devices WHERE user_id=%s", (sara,)).fetchone()[0]
    check("25. Deactivation recorded in PostgreSQL: flag set, password and devices removed", row == (1, True) and devs == 0, f"flag={row[0]}, devices={devs}")
    with psycopg.connect(AMER_DB) as c:
        acts = {r[0] for r in c.execute("SELECT DISTINCT action FROM audit_log WHERE action LIKE 'admin.%'")}
    need = {"admin.invite.create", "admin.user.create", "admin.user.password_reset", "admin.user.deactivate"}
    check("26. All admin actions in the audit log", need <= acts, sorted(acts))

    p = sum(r["pass"] for r in R); print(f"\n{p}/{len(R)} registration checks passed")
    json.dump(R, open(os.getenv("OUT", "registration_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)

asyncio.run(main())
