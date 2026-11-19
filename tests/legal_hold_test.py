"""Legal hold on the real stack (docs/LEGAL_HOLD.md): Synapse (with the Amer module) refuses redactions and retention
changes in a held room and redactions by a held person; release restores normal behaviour."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Hold-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Hold-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def send(h, H, room, n): return (await h.put(f"{HS}/_matrix/client/v3/rooms/{room}/send/m.room.message/t{n}{secrets.token_hex(3)}", headers=H, json={"msgtype": "m.text", "body": f"msg {n}"})).json()["event_id"]
async def redact(h, H, room, ev): return await h.put(f"{HS}/_matrix/client/v3/rooms/{room}/redact/{ev}/r{secrets.token_hex(4)}", headers=H, json={"reason": "cleanup"})
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=20) as h:
        (A, a), (B, b) = await tok(h, f"legal{sfx}"), await tok(h, f"sales{sfx}")
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=A, json={"name": "Tender 2026-14"})).json()["room_id"]
        other = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=B, json={"name": "Sales private"})).json()["room_id"]
        e1 = await send(h, A, room, 1)
        hold = (await h.post(f"{ORCH}/v1/admin/legal-holds", headers=ADM, json={"scope": "room", "target": room, "matter": "Tender dispute"})).json()
        uh = (await h.post(f"{ORCH}/v1/admin/legal-holds", headers=ADM, json={"scope": "user", "target": b, "matter": "Tender dispute"})).json()
        await asyncio.sleep(11)                                            # the module's cache
        r = await redact(h, A, room, e1)
        check("1. In a held room, Synapse refuses deleting a message", r.status_code == 403, r.text[:100])
        r = await h.put(f"{HS}/_matrix/client/v3/rooms/{room}/state/m.room.retention/", headers=A, json={"max_lifetime": 86400000})
        check("2. In a held room, Synapse refuses switching on auto-delete", r.status_code == 403, r.text[:100])
        e2 = await send(h, B, other, 2); r = await redact(h, B, other, e2)
        check("3. A held person cannot delete their messages anywhere", r.status_code == 403, r.text[:100])
        e3 = await send(h, A, room, 3)
        check("4. People keep talking normally in a held room", bool(e3))
        lst = (await h.get(f"{ORCH}/v1/admin/legal-holds", headers=ADM)).json()
        check("5. Administrators see active holds with matter and who placed them", any(x["id"] == hold["id"] and x["matter"] == "Tender dispute" for x in lst))
        await h.post(f"{ORCH}/v1/admin/legal-holds/{hold['id']}/release", headers=ADM); await h.post(f"{ORCH}/v1/admin/legal-holds/{uh['id']}/release", headers=ADM)
        await asyncio.sleep(11)
        r = await redact(h, A, room, e1)
        check("6. After release, deleting works again", r.status_code == 200, r.text[:100])
    json.dump(R, open(os.getenv("OUT", "/opt/amer/legal_hold_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
