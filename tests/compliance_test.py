"""Compliance archiving, live: real Synapse, real end-to-end encrypted clients (matrix-nio + Olm/Megolm), the real
archiver process, PostgreSQL and the orchestrator admin API. No mocks."""
import asyncio, json, os, secrets, subprocess, sys, tempfile, time
import httpx, psycopg
from nio import AsyncClient, AsyncClientConfig, RoomMessageText

HS, ORCH, SERVER = "http://127.0.0.1:8008", "http://127.0.0.1:8080", "amer.test"
DSN = os.getenv("DATABASE_URL", "postgresql://amer:amer-pass@127.0.0.1:5432/amer")
ADM = {"Authorization": "Bearer " + open("/opt/amer/admin.token").read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)

sfx = secrets.token_hex(3)
ALICE, CAROL, ARCH, MALLORY = f"alice{sfx}", f"carol{sfx}", f"archive{sfx}", f"mallory{sfx}"
PW = "Comp-Test-Pass-1!"

async def mk(user):
    c = AsyncClient(HS, f"@{user}:{SERVER}", store_path=tempfile.mkdtemp(), config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
    await c.login(PW, device_name=f"{user} test"); await c.sync(timeout=1000, full_state=True)
    return c

async def settle(*cs, n=3):
    for _ in range(n):
        for c in cs:
            await c.sync(timeout=500)
            if c.should_upload_keys: await c.keys_upload()
            if c.should_query_keys: await c.keys_query()
            if c.should_claim_keys: await c.keys_claim(c.get_users_for_key_claiming())
            for uid, devs in c.device_store.items():
                for d in devs.values():
                    if not d.verified and d.device_id != c.device_id: c.verify_device(d)

async def send(c, room, body, **extra):
    r = await c.room_send(room, "m.room.message", {"msgtype": "m.text", "body": body, **extra}, ignore_unverified_devices=True)
    return r.event_id

def rows(sql, a=()):
    with psycopg.connect(DSN) as c: return c.execute(sql, a).fetchall()

async def main():
    async with httpx.AsyncClient(timeout=20) as h:
        for u in (ALICE, CAROL, ARCH, MALLORY):
            r = await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": PW})
            assert r.status_code == 200, r.text
        tenant = f"acme{sfx}"
        r = await h.post(f"{ORCH}/v1/admin/tenants", headers=ADM, json={"tenant": tenant, "name": "Acme Business", "compliance_enabled": True,
                                                                       "compliance_user": f"@{ARCH}:{SERVER}", "retention_days": 365})
        await h.post(f"{ORCH}/v1/admin/tenants/members", headers=ADM, json={"user_id": f"@{ALICE}:{SERVER}", "tenant": tenant})
        check("1. Business tenant with compliance archiving configured", r.status_code == 200, r.text)

        store = tempfile.mkdtemp()
        env = {**os.environ, "HS": HS, "ARCHIVER_USER": ARCH, "ARCHIVER_PASSWORD": PW, "SERVER_NAME": SERVER, "DATABASE_URL": DSN, "STORE_DIR": store}
        for k in ("HTTPS_PROXY", "https_proxy", "HTTP_PROXY", "http_proxy"): env.pop(k, None)
        arch = subprocess.Popen([sys.executable, "-u", os.path.join(os.path.dirname(__file__), "..", "services", "archiver", "archiver.py")],
                                env=env, stdout=open(os.path.join(store, "log"), "w"), stderr=subprocess.STDOUT)
        for _ in range(60):
            if os.path.exists(os.path.join(store, "ready")): break
            await asyncio.sleep(1)
        check("2. Archiver signed in with its own encrypted device", os.path.exists(os.path.join(store, "ready")), open(os.path.join(store, "log")).read()[-300:])

        a, c, m = await mk(ALICE), await mk(CAROL), await mk(MALLORY)
        try:
            # business conversation: Alice (acme, compliance) and Carol (public) with the archiver invited first, as the app does
            room = (await a.room_create(invite=[f"@{CAROL}:{SERVER}", f"@{ARCH}:{SERVER}"],
                    initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])).room_id
            await c.join(room)
            for _ in range(30):
                if rows("SELECT 1 FROM compliance_rooms WHERE room_id=%s", (room,)): break
                await asyncio.sleep(1)
            check("3. Archiver joins when invited by a compliance-tenant member", bool(rows("SELECT tenant FROM compliance_rooms WHERE room_id=%s", (room,))))
            await asyncio.sleep(3); await settle(a, c)
            e1 = await send(a, room, f"Quarterly figures are confidential {sfx}")
            e2 = await send(c, room, "Understood, I will not share them")
            await a.room_send(room, "m.reaction", {"m.relates_to": {"rel_type": "m.annotation", "event_id": e2, "key": "👍"}}, ignore_unverified_devices=True)
            await a.room_send(room, "m.room.message", {"msgtype": "m.text", "body": f"* Quarterly figures are strictly confidential {sfx}",
                "m.new_content": {"msgtype": "m.text", "body": f"Quarterly figures are strictly confidential {sfx}"},
                "m.relates_to": {"rel_type": "m.replace", "event_id": e1}}, ignore_unverified_devices=True)
            e5 = await send(c, room, "message I will delete")
            await c.room_redact(room, e5, reason="mistake")
            got = []
            for _ in range(40):
                got = rows("SELECT type, sender, body FROM compliance_archive WHERE room_id=%s ORDER BY id", (room,))
                if len([g for g in got if g[0] == "m.room.redaction"]) >= 1 and len(got) >= 6: break
                await asyncio.sleep(1)
            bodies = [g[2] or "" for g in got]
            check("4. Messages archived decrypted (server holds only ciphertext)", any(f"confidential {sfx}" in b for b in bodies) and "Understood, I will not share them" in bodies, got)
            check("5. Edits archived alongside the original", any("strictly confidential" in b for b in bodies) and any(b == f"Quarterly figures are confidential {sfx}" for b in bodies))
            check("6. Reactions archived", any(g[0] == "m.reaction" for g in got))
            check("7. Deleted message kept, deletion archived as its own event", "message I will delete" in bodies and any(g[0] == "m.room.redaction" for g in got))
            check("8. Nothing undecryptable (keys shared with the archiver)", not any(g[0] == "undecryptable" for g in got), [g[0] for g in got])
            syn_dsn = os.getenv("SYNAPSE_DSN", "postgresql://synapse:syn-pass@127.0.0.1:5432/synapse")
            with psycopg.connect(syn_dsn) as sdb:
                n_room = sdb.execute("SELECT count(*) FROM events WHERE room_id=%s AND type='m.room.encrypted'", (room,)).fetchone()[0]
                leaked = sdb.execute("SELECT count(*) FROM event_json WHERE room_id=%s AND json LIKE %s", (room, f"%confidential {sfx}%")).fetchone()[0]
                plain = sdb.execute("SELECT count(*) FROM events WHERE room_id=%s AND type = 'm.room.message'", (room,)).fetchone()[0]   # (nio, the test client, sends reactions in clear; the app's own events are audited in CI)
            check("9. Synapse's own database holds the same messages only as ciphertext", n_room >= 4 and leaked == 0 and plain == 0,
                  f"encrypted events={n_room}, plaintext matches={leaked}, unencrypted message events={plain}")

            # public users are never archived
            proom = (await c.room_create(invite=[f"@{ARCH}:{SERVER}", f"@{MALLORY}:{SERVER}"],
                     initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])).room_id
            await m.join(proom); await asyncio.sleep(6); await settle(c, m)
            await send(c, proom, "private chat between public users")
            await asyncio.sleep(6)
            check("10. Invite from a public user is rejected: no archiving of public users",
                  not rows("SELECT 1 FROM compliance_rooms WHERE room_id=%s", (proom,)) and not rows("SELECT 1 FROM compliance_archive WHERE room_id=%s", (proom,)))

            # administrator views
            r = await h.get(f"{ORCH}/v1/admin/compliance/search", params={"tenant": tenant, "q": "confidential"}, headers={"Authorization": f"Bearer {a.access_token}"})
            check("11. Search is administrator-only", r.status_code == 403, r.status_code)
            r = await h.get(f"{ORCH}/v1/admin/compliance/search", params={"tenant": tenant, "q": "confidential"}, headers=ADM)
            check("12. Full-text search finds the messages", r.status_code == 200 and len(r.json()) >= 2, r.text[:200])
            r = await h.get(f"{ORCH}/v1/admin/compliance/search", params={"tenant": tenant, "sender": f"@{CAROL}:{SERVER}"}, headers=ADM)
            check("13. Search by person", r.status_code == 200 and r.json() and all(x["sender"] == f"@{CAROL}:{SERVER}" for x in r.json()), len(r.json()))
            r = await h.get(f"{ORCH}/v1/admin/compliance/export", params={"tenant": tenant}, headers=ADM)
            lines = [json.loads(l) for l in r.text.splitlines() if l.strip()]
            check("14. Export: NDJSON with hashes for e-discovery", r.status_code == 200 and len(lines) >= 6 and all("hash" in l and "prev_hash" in l for l in lines), len(lines))
            r = await h.get(f"{ORCH}/v1/admin/compliance/verify", params={"tenant": tenant}, headers=ADM)
            check("15. Hash chain verifies", r.json().get("ok") is True, r.json())
            audit = (await h.get(f"{ORCH}/v1/audit", headers=ADM)).json()
            check("16. Searches and exports are themselves audited", {"compliance.search", "compliance.export", "compliance.verify"} <= {x["action"] for x in audit})

            # integrity
            with psycopg.connect(DSN, autocommit=True) as db:
                try: db.execute("UPDATE compliance_archive SET body='changed' WHERE room_id=%s", (room,)); upd = False
                except psycopg.Error as ex: upd = "append-only" in str(ex)
                check("17. Archive rows cannot be changed (database refuses UPDATE)", upd)
                try: db.execute("DELETE FROM compliance_archive WHERE room_id=%s", (room,)); dele = False
                except psycopg.Error as ex: dele = "retention purge" in str(ex)
                check("18. Archive rows cannot be deleted outside the retention purge", dele)
                try:
                    with db.transaction():
                        db.execute("SET LOCAL amer.purge='on'"); db.execute("DELETE FROM compliance_archive WHERE room_id=%s", (room,))
                    early = False
                except psycopg.Error as ex: early = "still within retention" in str(ex)
                check("19. Even the purge cannot remove rows still within retention", early)
                # tamper with the trigger disabled (as a rogue DBA could): the hash chain must expose it
                db.execute("ALTER TABLE compliance_archive DISABLE TRIGGER compliance_archive_guard")
                db.execute("UPDATE compliance_archive SET content = jsonb_set(content, '{body}', '\"forged\"') WHERE id = (SELECT min(id) FROM compliance_archive WHERE room_id=%s AND type='m.room.message')", (room,))
                db.execute("ALTER TABLE compliance_archive ENABLE TRIGGER compliance_archive_guard")
            r = await h.get(f"{ORCH}/v1/admin/compliance/verify", params={"tenant": tenant}, headers=ADM)
            check("20. Tampering by a database administrator is detected by the hash chain", r.json().get("ok") is False and r.json().get("broken_at"), r.json())
        finally:
            arch.terminate()
            for x in (a, c, m): await x.close()
    json.dump(R, open(os.getenv("OUT", "/opt/amer/compliance.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed")

asyncio.run(main())
