"""Chat feature server flows, live over the Matrix API (no mocks): threads, @mentions, announcement-only
groups, disappearing-message setting, member roles, block (ignore), saved messages, mute."""
import json, os, secrets, sys
import httpx

HS = "http://127.0.0.1:8008"; R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
h = httpx.Client(timeout=15)
def login(u, p): return {"Authorization": f"Bearer {h.post(f'{HS}/_matrix/client/v3/login', json={'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': u}, 'password': p}).json()['access_token']}"}
A, B = login("moh", "Pass-moh-123"), login("tester", "Pass-tester-123")
q = lambda s: s.replace("!", "%21").replace(":", "%3A").replace("$", "%24")
send = lambda H, rid, c, t="m.room.message": h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/send/{t}/{secrets.token_hex(4)}", headers=H, json=c)
msgs = lambda H, rid: h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/messages", headers=H, params={"dir": "b", "limit": 50}).json()["chunk"]

rid = h.post(f"{HS}/_matrix/client/v3/createRoom", headers=A, json={"name": "Optical team", "preset": "private_chat", "invite": ["@tester:amer.test"]}).json()["room_id"]
h.post(f"{HS}/_matrix/client/v3/join/{q(rid)}", headers=B, json={})

# threads
root = send(A, rid, {"msgtype": "m.text", "body": "Ciena slot options?"}).json()["event_id"]
send(B, rid, {"msgtype": "m.text", "body": "Thursday works", "m.relates_to": {"rel_type": "m.thread", "event_id": root, "is_falling_back": True, "m.in_reply_to": {"event_id": root}}})
th = h.get(f"{HS}/_matrix/client/v1/rooms/{q(rid)}/relations/{q(root)}/m.thread", headers=A).json()["chunk"]
check("1. Thread reply attached to its root", len(th) == 1 and th[0]["content"]["body"] == "Thursday works")

# mentions
send(A, rid, {"msgtype": "m.text", "body": "[Tester](https://matrix.to/#/@tester:amer.test) please review", "m.mentions": {"user_ids": ["@tester:amer.test"]},
              "format": "org.matrix.custom.html", "formatted_body": '<a href="https://matrix.to/#/@tester:amer.test">Tester</a> please review'})
n = h.get(f"{HS}/_matrix/client/v3/notifications", headers=B).json()["notifications"]
check("2. @mention produces a highlighted notification for the mentioned person", any("highlight" in str(x["actions"]) for x in n if x["room_id"] == rid))

# announcement-only
pl = h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.power_levels", headers=A).json(); pl["events_default"] = 50
h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.power_levels", headers=A, json=pl)
r = send(B, rid, {"msgtype": "m.text", "body": "can I post?"})
check("3. Announcements only: members cannot post", r.status_code == 403, r.json().get("errcode"))
check("4. Announcements only: admin can still post", send(A, rid, {"msgtype": "m.text", "body": "Maintenance window tonight"}).status_code == 200)
pl["events_default"] = 0; h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.power_levels", headers=A, json=pl)

# roles
pl["users"]["@tester:amer.test"] = 100; r = h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.power_levels", headers=A, json=pl)
check("5. Make member admin", r.status_code == 200 and h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.power_levels", headers=B).json()["users"].get("@tester:amer.test") == 100)

# disappearing messages
r = h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.retention", headers=A, json={"max_lifetime": 86400000})
st = h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/m.room.retention", headers=B).json()
check("6. Disappearing messages policy set and visible to members (server purges hourly)", r.status_code == 200 and st.get("max_lifetime") == 86400000)

# mute
r = h.put(f"{HS}/_matrix/client/v3/pushrules/global/override/{q(rid)}", headers=B, json={"actions": [], "conditions": [{"kind": "event_match", "key": "room_id", "pattern": rid}]})
check("7. Mute chat (push rule)", r.status_code == 200)

# saved messages in account data
h.put(f"{HS}/_matrix/client/v3/user/%40moh%3Aamer.test/account_data/com.amerteams.starred", headers=A, json={rid: [root]})
got = h.get(f"{HS}/_matrix/client/v3/user/%40moh%3Aamer.test/account_data/com.amerteams.starred", headers=A).json()
check("8. Saved messages stored per account", got == {rid: [root]})

# block
h.put(f"{HS}/_matrix/client/v3/user/%40moh%3Aamer.test/account_data/m.ignored_user_list", headers=A, json={"ignored_users": {"@tester:amer.test": {}}})
send(B, rid, {"msgtype": "m.text", "body": "blocked-probe"})
s = h.get(f"{HS}/_matrix/client/v3/sync", headers=A, params={"timeout": 0}).json()
seen = [e["content"].get("body") for e in s.get("rooms", {}).get("join", {}).get(rid, {}).get("timeline", {}).get("events", [])]
check("9. Blocked user's messages are not delivered", "blocked-probe" not in seen)
h.put(f"{HS}/_matrix/client/v3/user/%40moh%3Aamer.test/account_data/m.ignored_user_list", headers=A, json={"ignored_users": {}})

p = sum(x["pass"] for x in R); print(f"\n{p}/{len(R)} chat feature checks passed")
json.dump(R, open(os.getenv("OUT", "chat_features_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)
