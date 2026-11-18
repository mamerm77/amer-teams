"""Meetings and calling server flows, tested live over the Matrix API (no mocks):
people directory, Meet-now room with meeting ID, join-by-ID via waiting room (knock), host admits or
declines, scheduled meeting invites, call history events, incoming-call invite delivery."""
import json, os, random, secrets, sys, time
import httpx

HS = os.getenv("HS", "http://127.0.0.1:8008"); SERVER = "amer.test"
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
h = httpx.Client(timeout=15)
def login(u, p): return {"Authorization": f"Bearer {h.post(f'{HS}/_matrix/client/v3/login', json={'type': 'm.login.password', 'identifier': {'type': 'm.id.user', 'user': u}, 'password': p}).json()['access_token']}"}
host, guest, other = login("moh", "Pass-moh-123"), login("tester", "Pass-tester-123"), login("outsider", "Pass-outsider-123")
q = lambda s: s.replace("#", "%23").replace(":", "%3A").replace("!", "%21")

# 1. directory
r = h.post(f"{HS}/_matrix/client/v3/user_directory/search", headers=host, json={"search_term": "test", "limit": 10}).json()
check("1. People directory finds users without a shared room", any(u["user_id"] == "@tester:amer.test" for u in r["results"]), [u["user_id"] for u in r["results"]])

# 2. Meet now: encrypted room, knock join rule, meeting ID alias (same as the app)
mid = str(random.randint(100_000_000, 999_999_999))
room = h.post(f"{HS}/_matrix/client/v3/createRoom", headers=host, json={
    "name": f"Meeting {mid}", "preset": "private_chat", "room_alias_name": f"m-{mid}",
    "initial_state": [{"type": "m.room.join_rules", "state_key": "", "content": {"join_rule": "knock"}},
                      {"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}},
                      {"type": "m.room.history_visibility", "state_key": "", "content": {"history_visibility": "joined"}}]}).json()
rid = room.get("room_id")
st = lambda t: h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/{t}", headers=host).json()
check("2. Meet now creates an encrypted meeting with an ID", rid and st("m.room.encryption").get("algorithm") == "m.megolm.v1.aes-sha2" and st("m.room.join_rules").get("join_rule") == "knock", f"ID {mid[:3]} {mid[3:6]} {mid[6:]}")
res = h.get(f"{HS}/_matrix/client/v3/directory/room/{q(f'#m-{mid}:{SERVER}')}", headers=guest).json()
check("3. Meeting ID resolves for another user", res.get("room_id") == rid)

# 3. join by ID -> waiting room
j = h.post(f"{HS}/_matrix/client/v3/join/{q(f'#m-{mid}:{SERVER}')}", headers=guest, json={})
check("4. Joining directly without approval is refused", j.status_code == 403, j.json().get("errcode"))
k = h.post(f"{HS}/_matrix/client/v3/knock/{q(f'#m-{mid}:{SERVER}')}", headers=guest, json={"reason": "Sara would like to join"})
check("5. Guest knocks (enters the waiting room)", k.status_code == 200, k.json())
mem = h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/members", headers=host, params={"membership": "knock"}).json()["chunk"]
check("6. Host sees the guest waiting", any(m["state_key"] == "@tester:amer.test" for m in mem), [m["state_key"] for m in mem])
h.post(f"{HS}/_matrix/client/v3/knock/{q(f'#m-{mid}:{SERVER}')}", headers=other, json={})
dec = h.post(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/kick", headers=host, json={"user_id": "@outsider:amer.test", "reason": "Not admitted"})
inv = h.post(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/invite", headers=host, json={"user_id": "@tester:amer.test"})
jj = h.post(f"{HS}/_matrix/client/v3/join/{q(rid)}", headers=guest, json={})
check("7. Host admits guest; guest joins the meeting", inv.status_code == 200 and jj.status_code == 200)
ms = {m["state_key"]: m["content"]["membership"] for m in h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/members", headers=host).json()["chunk"]}
check("8. Declined guest is removed from the waiting room", dec.status_code == 200 and ms.get("@outsider:amer.test") == "leave", ms)
oj = h.post(f"{HS}/_matrix/client/v3/join/{q(rid)}", headers=other, json={})
check("9. Declined guest still cannot join", oj.status_code == 403)

# 4. scheduled meeting with invitees + calendar event
sched_id = str(random.randint(100_000_000, 999_999_999))
sr = h.post(f"{HS}/_matrix/client/v3/createRoom", headers=host, json={"name": "Ciena review", "preset": "private_chat", "room_alias_name": f"m-{sched_id}",
     "invite": ["@tester:amer.test"], "initial_state": [{"type": "m.room.join_rules", "state_key": "", "content": {"join_rule": "knock"}},
     {"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}]}).json()["room_id"]
inv_rooms = h.get(f"{HS}/_matrix/client/v3/sync", headers=guest, params={"timeout": 0}).json().get("rooms", {}).get("invite", {})
check("10. Scheduled meeting invite reaches the invitee", sr in inv_rooms)

# 5. call signalling events (encrypted in the app; checked here for delivery and ordering)
cid = secrets.token_hex(6)
for ev in ({"call_id": cid, "media": "video", "body": "Video call"}, ):
    h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/send/com.amerteams.call.invite/{secrets.token_hex(4)}", headers=host, json=ev)
h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/send/com.amerteams.call.end/{secrets.token_hex(4)}", headers=host, json={"call_id": cid, "duration_s": 754, "reason": "hangup"})
msgs = h.get(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/messages", headers=guest, params={"dir": "b", "limit": 20}).json()["chunk"]
types = [m["type"] for m in msgs if m.get("content", {}).get("call_id") == cid]
check("11. Call start and end events delivered in order (call history)", types == ["com.amerteams.call.end", "com.amerteams.call.invite"], types)

p = sum(x["pass"] for x in R); print(f"\n{p}/{len(R)} meeting checks passed")
json.dump(R, open(os.getenv("OUT", "meetings_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)
