"""Partner organisations over real Matrix federation (docs/PARTNERS.md). Two real Synapse servers (amer.test with
the Amer partner policy module, partner.test plain Synapse), TLS between them, real end-to-end encrypted clients
(matrix-nio) on each side, and the real orchestrator. No mocks.

Spec acceptance tests: a non-approved server cannot join; (DLP is on the device: app/test/dlp_test.dart)."""
import asyncio, json, os, re, secrets, subprocess, sys, tempfile, time
import httpx
from nio import AsyncClient, AsyncClientConfig, RoomMessageText, JoinError, RoomInviteError

A, B = os.getenv("HS_A", "http://127.0.0.1:8008"), os.getenv("HS_B", "http://127.0.0.1:8018")
ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
PARTNER_CFG = os.getenv("PARTNER_CFG", "/opt/amer/partner/homeserver.yaml")
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
sfx = secrets.token_hex(3); PW = "Fed-Test-Pass-1!"; U_A, U_B = f"nadia{sfx}", f"sara{sfx}"

async def mk(hs, uid):
    c = AsyncClient(hs, uid, store_path=tempfile.mkdtemp(), config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
    r = await c.login(PW); assert getattr(r, "access_token", None), r
    await c.sync(timeout=1000, full_state=True); return c
async def settle(*cs, n=3):
    for _ in range(n):
        for c in cs:
            await c.sync(timeout=700)
            if c.should_upload_keys: await c.keys_upload()
            if c.should_query_keys: await c.keys_query()
            if c.should_claim_keys: await c.keys_claim(c.get_users_for_key_claiming())
            for devs in c.device_store.values():
                for d in devs.values():
                    if not d.verified and d.device_id != c.device_id: c.verify_device(d)
async def got(c, room, text, secs=25):
    for _ in range(secs):
        await c.sync(timeout=1000)
        if room in c.rooms and any(getattr(e, "body", None) == text for e in c.rooms[room].__dict__.get("_seen", [])): return True
        if text in SEEN.get((c.user_id, room), []): return True
    return False
SEEN: dict = {}
def watch(c):
    def cb(room, ev): SEEN.setdefault((c.user_id, room.room_id), []).append(ev.body)
    c.add_event_callback(cb, RoomMessageText)
async def join_with_retry(c, room, tries=8):
    for _ in range(tries):
        r = await c.join(room)
        if not isinstance(r, JoinError): return r
        await asyncio.sleep(2)
    return r

async def main():
    secret = re.search(r'registration_shared_secret: "?([^"\n]+)"?', open(PARTNER_CFG).read()).group(1)
    subprocess.run([sys.executable, "-m", "synapse._scripts.register_new_matrix_user", "-u", U_B, "-p", PW, "--no-admin", "-k", secret, B], check=True, capture_output=True)
    async with httpx.AsyncClient(timeout=20) as h:
        assert (await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": U_A, "password": PW})).status_code == 200
        await h.post(f"{ORCH}/v1/admin/partners/partner.test", headers=ADM, json={"action": "disconnect"})   # start from no partnership
        await asyncio.sleep(11)                                                                               # the module's cache
        a, b = await mk(A, f"@{U_A}:amer.test"), await mk(B, f"@{U_B}:partner.test"); watch(a); watch(b)
        enc = {"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}
        shared = {"type": "com.amerteams.shared", "state_key": "", "content": {"partners": ["partner.test"]}}
        try:
            rc = await a.room_create(name="Vendor channel", initial_state=[enc, shared])
            assert hasattr(rc, "room_id"), rc
            room = rc.room_id
            ri = await a.room_invite(room, f"@{U_B}:partner.test")
            print("invite before approval:", ri)
            await asyncio.sleep(3); await b.sync(timeout=2000)
            r = await b.join(room)
            check("1. A server that is not an approved partner cannot join a shared channel", isinstance(r, JoinError), r)

            p = (await h.post(f"{ORCH}/v1/admin/partners", headers=ADM, json={"server": "partner.test", "note": "federation test"})).json()
            check("2. Approving on our side alone is not enough (approved_by_us, not active)", p.get("state") == "approved_by_us", p)
            q = (await h.post(f"{ORCH}/v1/federation/handshake", json={"server": "partner.test", "code": p["code"]})).json()
            check("3. The partner confirms with the one-time code: active", q.get("state") == "active", q)
            await asyncio.sleep(11)
            await a.room_invite(room, f"@{U_B}:partner.test"); await asyncio.sleep(2); await b.sync(timeout=2000)
            r = await join_with_retry(b, room)
            check("4. After both sides approve, the partner's user joins the shared channel", not isinstance(r, JoinError), r)
            await settle(a, b, n=4)
            await a.room_send(room, "m.room.message", {"msgtype": "m.text", "body": "Quote attached for review"}, ignore_unverified_devices=True)
            ok_b = await got(b, room, "Quote attached for review")
            await settle(a, b, n=2)
            await b.room_send(room, "m.room.message", {"msgtype": "m.text", "body": "Received, reviewing today"}, ignore_unverified_devices=True)
            ok_a = await got(a, room, "Received, reviewing today")
            check("5. End-to-end encrypted messages flow both ways across the two servers", ok_a and ok_b, (ok_a, ok_b))

            local = (await a.room_create(name="Internal only", invite=[], initial_state=[enc])).room_id
            ri = await a.room_invite(local, f"@{U_B}:partner.test")
            check("6. An ordinary chat stays local: a partner cannot even be invited", isinstance(ri, RoomInviteError), ri)

            await h.post(f"{ORCH}/v1/admin/partners/partner.test", headers=ADM, json={"action": "disconnect"})
            await asyncio.sleep(11)
            await settle(b, n=1)
            await b.room_send(room, "m.room.message", {"msgtype": "m.text", "body": "after disconnect"}, ignore_unverified_devices=True)
            check("7. After disconnecting, the partner's messages no longer arrive", not await got(a, room, "after disconnect", secs=12))
            check("8. Local members keep the channel and its history", "Received, reviewing today" in SEEN.get((a.user_id, room), []) and room in a.rooms)
        finally:
            for x in (a, b): await x.close()
    json.dump(R, open(os.getenv("OUT", "/opt/amer/federation.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed")

asyncio.run(main())
