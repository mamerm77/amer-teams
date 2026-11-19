"""Meeting rooms on the real local stack (docs/ROOMS.md): booking, no double booking under a race, privacy of titles,
room-device pairing, book-now, check-in and no-show release. Real orchestrator and PostgreSQL. No mocks."""
import asyncio, datetime as dt, json, os, secrets, sys
import httpx, psycopg
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080"); DB = os.getenv("DB", "postgresql://amer:amer-pass@127.0.0.1:5432/amer")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Room-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Room-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}
def at(mins): return (dt.datetime.now(dt.timezone.utc) + dt.timedelta(minutes=mins)).replace(microsecond=0).isoformat()
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=20) as h:
        A, B = await tok(h, f"maya{sfx}"), await tok(h, f"omar{sfx}")
        room = (await h.post(f"{ORCH}/v1/rooms", headers=ADM, json={"name": f"Falcon {sfx}", "site": "Abu Dhabi HQ, 12F", "capacity": 8, "equipment": ["screen", "video bar"]})).json()
        check("1. An administrator adds a room", room["id"].startswith("rm_"), room)
        b1 = await h.post(f"{ORCH}/v1/rooms/bookings", headers=A, json={"room_id": room["id"], "start": at(60), "end": at(120), "title": "Vendor pricing", "show_title": False})
        check("2. Booking a free slot works", b1.status_code == 200, b1.text[:80])
        r1, r2 = await asyncio.gather(*(h.post(f"{ORCH}/v1/rooms/bookings", headers=H, json={"room_id": room["id"], "start": at(180), "end": at(240)}) for H in (A, B)))
        check("3. Two people booking the same slot at the same moment: exactly one wins (database constraint)", sorted([r1.status_code, r2.status_code]) == [200, 409], (r1.status_code, r2.status_code))
        ov = await h.post(f"{ORCH}/v1/rooms/bookings", headers=B, json={"room_id": room["id"], "start": at(90), "end": at(100)})
        check("4. An overlapping booking is refused", ov.status_code == 409, ov.text[:80])
        lst = {x["id"]: x for x in (await h.get(f"{ORCH}/v1/rooms", headers=B, params={"start": at(0), "end": at(300), "capacity": 6})).json()}
        bk = lst[room["id"]]["bookings"]
        check("5. Others see 'Booked', not the private title", any(x["title"] == "Booked" and x["organiser"].startswith(f"@maya") for x in bk), bk)
        few = [x["id"] for x in (await h.get(f"{ORCH}/v1/rooms", headers=B, params={"capacity": 20})).json()]
        check("6. Filtering by capacity leaves out rooms too small", room["id"] not in few)
        code = (await h.post(f"{ORCH}/v1/rooms/{room['id']}/pair", headers=ADM)).json()["device_code"]
        D = {"X-Room-Device": code}
        bad = await h.get(f"{ORCH}/v1/room-device/today", headers={"X-Room-Device": "nope-nope"})
        today = (await h.get(f"{ORCH}/v1/room-device/today", headers=D)).json()
        check("7. The paired room tablet sees today's schedule; an unpaired one is refused", bad.status_code == 401 and today["room"]["name"] == f"Falcon {sfx}" and today["free"], today["room"])
        check("8. The tablet shows 'Booked', not private titles", all(i["title"] == "Booked" for i in today["today"]), today["today"])
        now = (await h.post(f"{ORCH}/v1/room-device/book-now", headers=D, json={"minutes": 30})).json()
        today = (await h.get(f"{ORCH}/v1/room-device/today", headers=D)).json()
        check("9. Book now from the tablet: the room shows busy and checked in", not today["free"] and today["current"]["id"] == now["id"] and today["current"]["checked_in"], today["current"])
        early = await h.post(f"{ORCH}/v1/rooms/bookings/{b1.json()['id']}/check-in", headers=A)
        check("10. Check-in opens only 15 minutes before the start", early.status_code == 409, early.text[:80])
        # a booking that started 11 minutes ago with nobody checked in (put in place directly, since bookings cannot start in the past)
        bid = f"bk_test{sfx}"
        r2room = (await h.post(f"{ORCH}/v1/rooms", headers=ADM, json={"name": f"Oryx {sfx}", "capacity": 4})).json()
        async with await psycopg.AsyncConnection.connect(DB) as c:
            await c.execute("INSERT INTO room_bookings (id, room_id, during, organiser) VALUES (%s,%s,tstzrange(now() - interval '11 minutes', now() + interval '20 minutes'),%s)", (bid, r2room["id"], f"@maya{sfx}:amer.test"))
            await c.commit()
        lst = {x["id"]: x for x in (await h.get(f"{ORCH}/v1/rooms", headers=B)).json()}
        check("11. Nobody checked in 10 minutes after the start: the room is released and shows free", lst[r2room["id"]]["free"], lst[r2room["id"]]["bookings"])
        cx = await h.delete(f"{ORCH}/v1/rooms/bookings/{b1.json()['id']}", headers=B)
        cy = await h.delete(f"{ORCH}/v1/rooms/bookings/{b1.json()['id']}", headers=A)
        check("12. Only the organiser can cancel", cx.status_code == 404 and cy.status_code == 200, (cx.status_code, cy.status_code))
    json.dump(R, open(os.getenv("OUT", "/opt/amer/rooms_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
