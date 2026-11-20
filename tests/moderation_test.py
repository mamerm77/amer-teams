"""Channel moderation enforced by the server (Synapse module), on the real stack: in a moderated channel a member's new
post is refused, their reply, reaction and edit go through, a moderator posts freely; switching moderation off lifts it.
Works on encrypted rooms too: only the unencrypted m.relates_to is looked at."""
import asyncio, json, os, secrets, sys
import httpx
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def tok(h, u):
    await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": "Mod-Pass-12345"})
    t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": "Mod-Pass-12345"})).json()["access_token"]
    return {"Authorization": f"Bearer {t}"}, f"@{u}:amer.test"
async def main():
    s = secrets.token_hex(3); n = [0]
    async with httpx.AsyncClient(timeout=30) as h:
        (O, oid), (M, mid) = await tok(h, f"mo{s}"), await tok(h, f"mm{s}")
        ch = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=O, json={"preset": "private_chat", "invite": [mid], "name": "Announcements",
              "initial_state": [{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}]})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/join/{ch}", headers=M, json={})
        def send(X, typ, content): n[0] += 1; return h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/send/{typ}/t{s}{n[0]}", headers=X, json=content)
        enc = lambda rel=None: {"algorithm": "m.megolm.v1.aes-sha2", "ciphertext": "AwgAEn...", "sender_key": "x", "session_id": "y", "device_id": "D", **({"m.relates_to": rel} if rel else {})}
        root = (await send(O, "m.room.encrypted", enc())).json()["event_id"]
        await h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/state/com.amerteams.channel/", headers=O, json={"moderated": True})
        post = await send(M, "m.room.encrypted", enc())
        check("1. Moderated channel: a member's new (encrypted) post is refused by the server", post.status_code == 403, post.text[:120])
        reply = await send(M, "m.room.encrypted", enc({"rel_type": "m.thread", "event_id": root, "is_falling_back": True, "m.in_reply_to": {"event_id": root}}))
        react = await send(M, "m.reaction", {"m.relates_to": {"rel_type": "m.annotation", "event_id": root, "key": "👍"}})
        check("2. The member can still reply in a thread and react", reply.status_code == 200 and react.status_code == 200, (reply.status_code, react.status_code))
        mpost = await send(O, "m.room.encrypted", enc())
        check("3. The owner (moderator) posts freely", mpost.status_code == 200, mpost.status_code)
        await h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/state/com.amerteams.channel/", headers=O, json={"moderated": True, "moderators": [mid]})
        listed = await send(M, "m.room.encrypted", enc())
        await h.put(f"{HS}/_matrix/client/v3/rooms/{ch}/state/com.amerteams.channel/", headers=O, json={"moderated": False})
        free = await send(M, "m.room.encrypted", enc())
        check("4. A member listed as moderator can post; switching moderation off lets everyone post", listed.status_code == 200 and free.status_code == 200, (listed.status_code, free.status_code))
    json.dump(R, open(os.getenv("OUT", "/opt/amer/moderation_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
