"""People, contacts and invitations on the real stack (Microsoft Teams parity, docs/PEOPLE.md)."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:220]}", flush=True)
async def login(h, u, pw):
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": pw})).json()
    return {"Authorization": f"Bearer {t['access_token']}"} if "access_token" in t else None
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Ppl-Pass-1234", "display_name": u.capitalize()})
    return await login(h, u, "Ppl-Pass-1234"), f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=30) as h:
        (A, a), (B, b), (C, c) = await tok(h, f"layla{sfx}"), await tok(h, f"omar{sfx}"), await tok(h, f"noor{sfx}")
        bad = await h.put(f"{ORCH}/v1/people/me", headers=B, json={"email": "not-an-email"})
        await h.put(f"{ORCH}/v1/people/me", headers=B, json={"email": f"omar.{sfx}@example.ae", "phone": "+971 50 555 " + sfx[:4].replace('a','1').replace('b','2').replace('c','3').replace('d','4').replace('e','5').replace('f','6'), "title": "Optical planner", "dept": "Transport"})
        me = (await h.get(f"{ORCH}/v1/people/profile/{b}", headers=A)).json()
        check("1. You set your contact details (email, phone, title, department); bad email refused", bad.status_code == 422 and me.get("title") == "Optical planner", me)
        by_mail = (await h.get(f"{ORCH}/v1/people/search", headers=A, params={"q": f"omar.{sfx}@exa"})).json()["results"]
        by_name = (await h.get(f"{ORCH}/v1/people/search", headers=A, params={"q": f"Omar{sfx}"[:6]})).json()["results"]
        by_phone = (await h.get(f"{ORCH}/v1/people/search", headers=A, params={"q": me["phone"][-6:]})).json()["results"]
        by_dept = (await h.get(f"{ORCH}/v1/people/search", headers=A, params={"q": "transport"})).json()["results"]
        check("2. Find people by email, name, phone or department", all(any(p["user_id"] == b for p in r) for r in (by_mail, by_name, by_phone, by_dept)), [len(r) for r in (by_mail, by_name, by_phone, by_dept)])
        await h.put(f"{ORCH}/v1/people/contacts", headers=A, json={"user_id": b, "favourite": True})
        g = (await h.put(f"{ORCH}/v1/people/groups", headers=A, json={"name": "Optical team", "members": [b, c, "@nobody:amer.test"]})).json()
        cs = (await h.get(f"{ORCH}/v1/people/contacts", headers=A)).json()
        check("3. Contacts and a contact group: favourite first, group members become contacts, unknown people dropped",
              cs["contacts"][0]["user_id"] == b and {x["user_id"] for x in cs["contacts"]} == {b, c} and g["members"] == [b, c] and cs["groups"][0]["name"] == "Optical team", cs)
        other = (await h.get(f"{ORCH}/v1/people/contacts", headers=B)).json()
        check("4. Contacts are private: Omar does not see Layla's contacts or groups", not other["contacts"] and not other["groups"], other)
        await h.delete(f"{ORCH}/v1/people/contacts/{c}", headers=A)
        cs = (await h.get(f"{ORCH}/v1/people/contacts", headers=A)).json()
        check("5. Removing a contact also takes them out of your groups", cs["groups"][0]["members"] == [b], cs["groups"])
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=A, json={"preset": "private_chat", "name": "Project X"})).json()["room_id"]
        notmine = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=B, json={"preset": "private_chat"})).json()["room_id"]
        bad2 = await h.post(f"{ORCH}/v1/people/invite", headers=A, json={"name": "Sara", "email": "sara@x.ae", "rooms": [notmine]})
        dup = await h.post(f"{ORCH}/v1/people/invite", headers=A, json={"name": "Omar", "email": f"omar.{sfx}@example.ae"})
        inv = await h.post(f"{ORCH}/v1/people/invite", headers=A, json={"name": "Sara Khalid", "email": f"sara.{sfx}@example.ae", "rooms": [room]})
        j = inv.json(); token = j.get("link", "#").split("#")[1]
        check("6. Invite someone new by email: a one-time sign-up link and a message to share; not for chats you are not in, not for existing people",
              inv.status_code == 200 and "/welcome#" in j["link"] and "Amer Teams" in j["message"] and bad2.status_code == 403 and dup.status_code == 409, (inv.status_code, bad2.status_code, dup.status_code))
        info = (await h.get(f"{ORCH}/v1/welcome/{token}")).json()
        weak = await h.post(f"{ORCH}/v1/welcome/{token}", json={"username": f"sara{sfx}", "password": "short"})
        ok = await h.post(f"{ORCH}/v1/welcome/{token}", json={"username": f"sara{sfx}", "password": "Sara-Pass-12345", "display_name": "Sara Khalid"})
        again = await h.post(f"{ORCH}/v1/welcome/{token}", json={"username": f"sara2{sfx}", "password": "Sara-Pass-12345"})
        S = await login(h, f"sara{sfx}", "Sara-Pass-12345")
        check("7. The invited person opens the link (no sign-in), creates her account and can sign in; the link works once",
              info.get("name") == "Sara Khalid" and weak.status_code == 422 and ok.status_code == 200 and again.status_code == 404 and S is not None, (weak.status_code, ok.status_code, again.status_code))
        sent = (await h.get(f"{ORCH}/v1/people/invites", headers=A)).json()
        mine = [x for x in sent if x["name"] == "Sara Khalid"]
        check("8. The inviter's app sees she joined, with her user id and the chats to add her to", mine and mine[0]["status"] == "joined" and mine[0]["user_id"] == f"@sara{sfx}:amer.test" and mine[0]["rooms"] == [room], mine)
        await h.post(f"{ORCH}/v1/people/invites/{mine[0]['id']}/added", headers=A)
        cs = (await h.get(f"{ORCH}/v1/people/contacts", headers=A)).json(); sc = (await h.get(f"{ORCH}/v1/people/contacts", headers=S)).json()
        prof = (await h.get(f"{ORCH}/v1/people/profile/@sara{sfx}:amer.test", headers=A)).json()
        check("9. She becomes a contact of the inviter and the inviter of hers; her email is on her profile",
              any(x["user_id"] == f"@sara{sfx}:amer.test" for x in cs["contacts"]) and any(x["user_id"] == a for x in sc["contacts"]) and prof.get("email") == f"sara.{sfx}@example.ae", prof)
        found = (await h.get(f"{ORCH}/v1/people/search", headers=B, params={"q": f"sara.{sfx}@"})).json()["results"]
        check("10. Everyone can now find her by email", any(p["user_id"] == f"@sara{sfx}:amer.test" for p in found), found)
        await h.put(f"{ORCH}/v1/people/me", headers=B, json={"title": "Optical planner", "manager": a})
        await h.put(f"{ORCH}/v1/people/me", headers=C, json={"title": "Engineer", "manager": b})
        o = (await h.get(f"{ORCH}/v1/people/org/{b}", headers=A)).json()
        check("11. Organisation chart from the one contact card: Omar's manager is Layla, Noor reports to Omar",
              [m["user_id"] for m in o["managers"]] == [a] and [r["user_id"] for r in o["reports"]] == [c] and o["person"]["title"] == "Optical planner", o)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/people_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
