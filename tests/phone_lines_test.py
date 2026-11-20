"""Phone dial-in and inbound call handling on the real stack (docs/PHONE_DIALIN.md): real LiveKit server API (dispatch
rule with PIN), real LiveKit webhooks. A real participant named like the SIP gateway's callers ("sip_<number>") stands
in for the carrier, since no carrier trunk exists locally."""
import asyncio, json, os, secrets, sys
import httpx, jwt, time
from livekit import rtc, api as lkapi
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
LK_KEY, LK_SECRET = os.getenv("LIVEKIT_API_KEY", "devkey"), os.getenv("LIVEKIT_API_SECRET", "devsecret-devsecret-devsecret-32")
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Tel-Pass-123!"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Tel-Pass-123!"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    sfx = secrets.token_hex(3)
    async with httpx.AsyncClient(timeout=30) as h:
        (H, hid), (A, a), (B, b) = await tok(h, f"host{sfx}"), await tok(h, f"rec{sfx}"), await tok(h, f"rec2{sfx}")
        tr = await h.post(f"{ORCH}/v1/phone/trunks", headers=ADM, json={"name": f"Carrier {sfx}", "address": "sip.carrier.example:5061", "numbers": [f"+9712555{secrets.randbelow(10**4):04d}"], "allowed_inbound_addresses": ["198.51.100.0/24"]})
        ids = tr.json()
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=H, json={"name": "Weekly ops", "invite": [a]})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/join/{room}", headers=A, json={})
        no = await h.post(f"{ORCH}/v1/phone/dialin", headers=A, json={"room_id": room})
        d = (await h.post(f"{ORCH}/v1/phone/dialin", headers=H, json={"room_id": room})).json()
        check("1. Only a host opens dial-in; it gives the number and a 6-digit PIN", no.status_code == 403 and len(d["pin"]) == 6 and d["number"].startswith("+"), {k: d[k] for k in ("number", "livekit_room")})
        async with lkapi.LiveKitAPI("http://127.0.0.1:7880", LK_KEY, LK_SECRET) as lk:
            rules = (await lk.sip.list_sip_dispatch_rule(lkapi.ListSIPDispatchRuleRequest())).items
        mine = [x for x in rules if x.rule.dispatch_rule_direct.room_name == d["livekit_room"]]
        check("2. The media server holds a dispatch rule: PIN required, into the meeting's phone bridge", mine and mine[0].rule.dispatch_rule_direct.pin == d["pin"], len(mine))
        again = (await h.post(f"{ORCH}/v1/phone/dialin", headers=H, json={"room_id": room})).json()
        check("3. Opening again returns the same number and PIN", again["pin"] == d["pin"])
        j = (await h.post(f"{ORCH}/v1/phone/dialin/{room}/join", headers=A)).json()
        check("4. A member joins the bridge from the app; it is labelled not end-to-end", j["e2ee"] == "not-possible" and j["token"], j["security"])
        cl = (await h.delete(f"{ORCH}/v1/phone/dialin/{room}", headers=H)).json()
        async with lkapi.LiveKitAPI("http://127.0.0.1:7880", LK_KEY, LK_SECRET) as lk:
            rules = (await lk.sip.list_sip_dispatch_rule(lkapi.ListSIPDispatchRuleRequest())).items
        check("5. Closing dial-in deletes the rule on the media server", cl["closed"] and not [x for x in rules if x.rule.dispatch_rule_direct.room_name == d["livekit_room"]])
        await h.put(f"{ORCH}/v1/phone/line", headers=ADM, json={"hunt_group": [a, b]})
        out = await h.get(f"{ORCH}/v1/phone/inbound", headers=H)
        check("6. Only the hunt group sees incoming calls", out.status_code == 403)
        caller = f"+97150{secrets.randbelow(10**7):07d}"; lkroom = f"phone-in-{caller}"
        now = int(time.time())
        t = jwt.encode({"iss": LK_KEY, "sub": f"sip_{caller}", "name": "Caller", "nbf": now - 5, "exp": now + 600, "video": {"room": lkroom, "roomJoin": True}}, LK_SECRET, algorithm="HS256")
        sipside = rtc.Room(); await sipside.connect("ws://127.0.0.1:7880", t)
        w = []
        for _ in range(15):
            w = [x for x in (await h.get(f"{ORCH}/v1/phone/inbound", headers=A)).json() if x["call"] == lkroom]
            if w: break
            await asyncio.sleep(1)
        check("7. An incoming call (real LiveKit webhook) shows to the hunt group, number masked", w and "•" in w[0]["caller"] and caller not in w[0]["caller"], w)
        r1, r2 = await asyncio.gather(h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/answer", headers=A), h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/answer", headers=B))
        check("8. Two people press Answer at once: exactly one gets the call", sorted([r1.status_code, r2.status_code]) == [200, 409], (r1.status_code, r2.status_code))
        W, Wid, O = (A, a, B) if r1.status_code == 200 else (B, b, A)
        C, cid = await tok(h, f"third{sfx}")
        nc = await h.get(f"{ORCH}/v1/phone/inbound", headers=C)
        tr = await h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/transfer", headers=W, json={"to": cid})
        seen = [x for x in (await h.get(f"{ORCH}/v1/phone/inbound", headers=C)).json() if x["call"] == lkroom]
        other = [x for x in (await h.get(f"{ORCH}/v1/phone/inbound", headers=O)).json() if x["call"] == lkroom]
        check("10. Transfer: the colleague (not on the line) now sees 'transferred to you'; nobody else can take it",
              nc.status_code == 403 and tr.status_code == 200 and seen and seen[0]["transferred_by"] == Wid and not other, (nc.status_code, tr.status_code, seen, other))
        steal = await h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/answer", headers=O)
        ca = await h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/answer", headers=C)
        check("11. Only the transfer target can answer it", steal.status_code == 409 and ca.status_code == 200 and ca.json()["token"], (steal.status_code, ca.status_code))
        notmine = await h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/park", headers=O)
        pk = await h.post(f"{ORCH}/v1/phone/inbound/{lkroom}/park", headers=C)
        code = pk.json().get("code", "")
        listed = [x for x in (await h.get(f"{ORCH}/v1/phone/inbound", headers=O)).json() if x["call"] == lkroom]
        check("12. Park: only the person on the call can park it; it gets a 3-digit code and shows as parked to the line", notmine.status_code == 409 and len(code) == 3 and listed and listed[0]["park_code"] == code, (notmine.status_code, code, listed))
        bad = await h.post(f"{ORCH}/v1/phone/pickup/000", headers=O)
        pu = await h.post(f"{ORCH}/v1/phone/pickup/{code}", headers=O)
        again = await h.post(f"{ORCH}/v1/phone/pickup/{code}", headers=W)
        check("13. Pick up with the code from another person's device; the code then stops working", pu.status_code == 200 and pu.json()["call"] == lkroom and again.status_code == 404 and bad.status_code in (404,), (bad.status_code, pu.status_code, again.status_code))
        f0 = (await h.get(f"{ORCH}/v1/phone/forwarding", headers=A)).json()
        await h.put(f"{ORCH}/v1/phone/forwarding", headers=A, json={"mode": "forward", "target": cid})
        cnow = await h.get(f"{ORCH}/v1/phone/inbound", headers=C)
        await h.put(f"{ORCH}/v1/phone/forwarding", headers=A, json={"mode": "voicemail"})
        b_only = await h.get(f"{ORCH}/v1/phone/inbound", headers=C)
        selfw = await h.put(f"{ORCH}/v1/phone/forwarding", headers=A, json={"mode": "forward", "target": a})
        await h.put(f"{ORCH}/v1/phone/forwarding", headers=A, json={"mode": "off"})
        check("14. Forwarding: forwarding the line to a colleague makes their app ring; switching to voicemail stops it; not to yourself",
              f0["mode"] == "off" and cnow.status_code == 200 and b_only.status_code == 403 and selfw.status_code == 422, (f0, cnow.status_code, b_only.status_code, selfw.status_code))
        await sipside.disconnect()
        async with lkapi.LiveKitAPI("http://127.0.0.1:7880", LK_KEY, LK_SECRET) as lk:
            try: await lk.room.delete_room(lkapi.DeleteRoomRequest(room=lkroom))
            except Exception: pass
            for k in ("outbound_trunk_id", "inbound_trunk_id"):
                try: await lk.sip.delete_sip_trunk(lkapi.DeleteSIPTrunkRequest(sip_trunk_id=ids[k]))
                except Exception: pass
        gone = []
        for _ in range(15):
            gone = [x for x in (await h.get(f"{ORCH}/v1/phone/inbound", headers=A)).json() if x["call"] == lkroom]
            if not gone: break
            await asyncio.sleep(1)
        check("9. When the call ends, it leaves the list", not gone, gone)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/phone_lines_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
