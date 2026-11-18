"""Amer Teams — real end-to-end test against live servers (no mocks).

Covers:
  1. Login for real Matrix users
  2. Encrypted room creation (server policy), invite, join
  3. Megolm-encrypted message delivery and decryption by the recipient
  4. Server-side storage holds ciphertext only (plaintext not in the DB)
  5. Call key distribution inside the encrypted room
  6. Orchestrator call-token service: member OK, non-member refused
  7. Real LiveKit call: audio published with AES-GCM frame encryption,
     received and decrypted by the peer holding the key
  8. A participant with a wrong key cannot recover the audio
Usage:  python e2e_real.py  (env: HS, ORCH, LK, SYNAPSE_DB)
"""
import asyncio, base64, json, math, os, secrets, sys, tempfile, time
import psycopg
import httpx, numpy as np
from nio import AsyncClient, AsyncClientConfig, RoomMessageText, UnknownEvent, InviteMemberEvent
from livekit import rtc, api

HS = os.getenv("HS", "http://127.0.0.1:8008")
ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
LK_KEY, LK_SECRET = os.getenv("LK_KEY", "APIamer"), os.getenv("LK_SECRET", "amer-test-secret-amer-test-secret-0123")
DB = os.getenv("SYNAPSE_DB", "postgresql://synapse:syn-pass@127.0.0.1/synapse")
def q(sql, *a):
    with psycopg.connect(DB) as c: return c.execute(sql.replace("?", "%s"), a).fetchall()
results = []

def check(name, ok, detail=""):
    results.append((name, bool(ok), detail))
    print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)

async def mk(user):
    store = tempfile.mkdtemp()
    c = AsyncClient(HS, f"@{user}:amer.test", store_path=store,
                    config=AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True))
    r = await c.login(f"Pass-{user}-123", device_name=f"e2e-{user}")
    return c, r

def trust_all(c):
    for uid, devs in c.device_store.items():
        for d in devs.values():
            if d.device_id != c.device_id: c.verify_device(d)

async def sync(*cs, n=2):
    for _ in range(n):
        await asyncio.gather(*[c.sync(timeout=1500, full_state=True) for c in cs])

async def main():
    moh, r1 = await mk("moh"); tester, r2 = await mk("tester"); outsider, r3 = await mk("outsider")
    check("1. Login (3 real users)", all(getattr(r, "access_token", None) for r in (r1, r2, r3)))
    await sync(moh, tester, outsider)

    # 2. room
    cr = await moh.room_create(name="E2E test room", invite=["@tester:amer.test"])
    rid = cr.room_id
    await sync(moh, tester)
    await tester.join(rid); await sync(moh, tester, n=3)
    st = await moh.room_get_state_event(rid, "m.room.encryption")
    check("2. Room is encrypted by server policy", getattr(st, "content", {}).get("algorithm") == "m.megolm.v1.aes-sha2",
          str(getattr(st, "content", st))[:80])

    # 3. encrypted message
    for c in (moh, tester):
        if c.should_upload_keys: await c.keys_upload()
        await c.keys_query() if c.should_query_keys else None
    await sync(moh, tester); trust_all(moh); trust_all(tester)
    secret_text = f"OSNR margin 3.4 dB secret-{secrets.token_hex(4)}"
    got = asyncio.Event(); recv = {}
    def on_msg(room, ev):
        if isinstance(ev, RoomMessageText) and ev.body == secret_text: recv["body"] = ev.body; got.set()
    tester.add_event_callback(on_msg, RoomMessageText)
    await moh.room_send(rid, "m.room.message", {"msgtype": "m.text", "body": secret_text}, ignore_unverified_devices=True)
    for _ in range(10):
        await sync(tester, n=1)
        if got.is_set(): break
    check("3. Tester receives and decrypts Megolm message", recv.get("body") == secret_text)

    # 4. ciphertext at rest
    rows = q("select json from event_json where room_id=?", rid)
    leaked = any(secret_text in r[0] for r in rows)
    enc = sum('"m.room.encrypted"' in r[0] for r in rows)
    check("4. Server stores ciphertext only", not leaked and enc > 0, f"{enc} encrypted events, plaintext found={leaked}")

    # 5. call key distribution
    K = secrets.token_bytes(32); call_id = secrets.token_hex(6)
    keyev = {}
    def on_unknown(room, ev):
        if ev.type == "com.amerteams.call.key" and ev.source.get("content", {}).get("call_id") == call_id:
            keyev.update(ev.source["content"])
    tester.add_event_callback(on_unknown, UnknownEvent)
    await moh.room_send(rid, "com.amerteams.call.key",
                        {"call_id": call_id, "key": base64.b64encode(K).decode(), "key_index": 0, "alg": "AES-GCM-256"},
                        ignore_unverified_devices=True)
    for _ in range(10):
        await sync(tester, n=1)
        if keyev: break
    K_rx = base64.b64decode(keyev.get("key", "")) if keyev else b""
    check("5. Call key delivered inside encrypted room", K_rx == K)

    # 6. token service
    async with httpx.AsyncClient() as h:
        async def tok(c):
            return await h.post(f"{ORCH}/v1/calls/token", headers={"Authorization": f"Bearer {c.access_token}"},
                                json={"room_id": rid, "call_id": call_id, "display_name": c.user_id})
        tm, tt, to = await tok(moh), await tok(tester), await tok(outsider)
    check("6a. Member gets LiveKit token", tm.status_code == 200 and tm.json()["e2ee"] == "required")
    check("6b. Non-member refused", to.status_code == 403, f"HTTP {to.status_code}")
    lk_url, lk_room = tm.json()["url"], tm.json()["livekit_room"]

    # 7/8. live call with frame encryption
    def e2ee(key): return rtc.E2EEOptions(key_provider_options=rtc.KeyProviderOptions(shared_key=key))
    pub, sub, spy = rtc.Room(), rtc.Room(), rtc.Room()
    await pub.connect(lk_url, tm.json()["token"], rtc.RoomOptions(e2ee=e2ee(K)))
    await sub.connect(lk_url, tt.json()["token"], rtc.RoomOptions(e2ee=e2ee(K_rx)))
    spy_tok = api.AccessToken(LK_KEY, LK_SECRET).with_identity("spy").with_grants(api.VideoGrants(room_join=True, room=lk_room)).to_jwt()
    await spy.connect(lk_url, spy_tok, rtc.RoomOptions(e2ee=e2ee(secrets.token_bytes(32))))
    check("7a. Both participants connected to SFU with E2EE", pub.isconnected() and sub.isconnected())

    SR, F = 48000, 480; freq = 440.0
    src = rtc.AudioSource(SR, 1)
    track = rtc.LocalAudioTrack.create_audio_track("mic", src)
    await pub.local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))

    async def collect(room, label, secs=6):
        samples = []
        fut = asyncio.get_event_loop().create_future()
        def on_sub(t, *_):
            if t.kind == rtc.TrackKind.KIND_AUDIO and not fut.done(): fut.set_result(t)
        room.on("track_subscribed", on_sub)
        for p in room.remote_participants.values():
            for pubn in p.track_publications.values():
                if pubn.track and pubn.track.kind == rtc.TrackKind.KIND_AUDIO and not fut.done(): fut.set_result(pubn.track)
        try: t = await asyncio.wait_for(fut, 10)
        except asyncio.TimeoutError: return np.zeros(1)
        stream = rtc.AudioStream(t, sample_rate=SR, num_channels=1)
        end = time.time() + secs
        async for ev in stream:
            samples.append(np.frombuffer(ev.frame.data, dtype=np.int16))
            if time.time() > end: break
        return np.concatenate(samples) if samples else np.zeros(1)

    async def produce(secs=9):
        n = 0
        for _ in range(int(secs * SR / F)):
            t = (np.arange(F) + n) / SR; n += F
            data = (np.sin(2 * math.pi * freq * t) * 12000).astype(np.int16)
            fr = rtc.AudioFrame.create(SR, 1, F); np.copyto(np.frombuffer(fr.data, dtype=np.int16), data)
            await src.capture_frame(fr)

    def tone_ratio(x):
        x = x[-SR * 3:].astype(float)
        if x.size < SR or np.abs(x).max() < 50: return 0.0, float(np.abs(x).mean())
        spec = np.abs(np.fft.rfft(x)); f = np.fft.rfftfreq(x.size, 1 / SR)
        band = spec[(f > 430) & (f < 450)].sum(); return band / spec.sum(), float(np.abs(x).mean())

    prod = asyncio.create_task(produce())
    a_sub, a_spy = await asyncio.gather(collect(sub, "sub"), collect(spy, "spy"))
    await prod
    r_sub, lvl_sub = tone_ratio(a_sub); r_spy, lvl_spy = tone_ratio(a_spy)
    check("7b. Peer with key hears the 440 Hz tone (decrypted)", r_sub > 0.5, f"tone energy {r_sub:.2f}, level {lvl_sub:.0f}")
    check("8. Participant with wrong key cannot recover audio", r_spy < 0.2, f"tone energy {r_spy:.2f}, level {lvl_spy:.0f}")

    # 9. live ops telemetry sees the call
    async with httpx.AsyncClient() as h:
        await asyncio.sleep(6)
        o = (await h.get(f"{ORCH}/v1/ops/status", headers={"Authorization": f"Bearer {moh.access_token}"})).json()
    check("9. Ops telemetry reports the live call", (o["now"]["media"].get("participants") or 0) >= 2,
          f"calls={o['now']['media'].get('active_calls')} participants={o['now']['media'].get('participants')}")
    for r in (pub, sub, spy): await r.disconnect()

    # 10. Teams = Matrix spaces with encrypted channels
    sp = await moh.room_create(name="Optical Transport", space=True, invite=["@tester:amer.test"])
    ch = await moh.room_create(name="DWDM Core", invite=["@tester:amer.test"])
    await moh.room_put_state(sp.room_id, "m.space.child", {"via": ["amer.test"]}, state_key=ch.room_id)
    await moh.room_put_state(ch.room_id, "m.space.parent", {"via": ["amer.test"], "canonical": True}, state_key=sp.room_id)
    async with httpx.AsyncClient() as h:
        hier = (await h.get(f"{HS}/_matrix/client/v1/rooms/{sp.room_id}/hierarchy", headers={"Authorization": f"Bearer {moh.access_token}"})).json()
    kids = [r["room_id"] for r in hier.get("rooms", [])]
    che = await moh.room_get_state_event(ch.room_id, "m.room.encryption")
    check("10. Team (space) contains encrypted channel", ch.room_id in kids and getattr(che, "content", {}).get("algorithm") == "m.megolm.v1.aes-sha2")

    # 11. encrypted file sharing
    import io, hashlib
    blob = b"Optical strategy 2027-2030 CONFIDENTIAL " * 200
    up, keys = await moh.upload(lambda *_: io.BytesIO(blob), content_type="application/octet-stream", filename="strategy.txt", encrypt=True, filesize=len(blob))
    stored = (await moh.download(up.content_uri)).body
    from nio.crypto import decrypt_attachment
    plain = decrypt_attachment(stored, keys["key"]["k"], keys["hashes"]["sha256"], keys["iv"])
    check("11. File stored encrypted, recipient-decryptable", b"CONFIDENTIAL" not in stored and plain == blob, f"{len(stored)} bytes ciphertext")

    # 12. calendar meeting delivered encrypted
    meet = {"meeting_id": secrets.token_hex(4), "title": "Ciena review", "start": "2026-11-20T11:00:00+04:00", "duration_min": 30}
    mev = {}
    def on_meet(room, ev):
        if ev.type == "com.amerteams.meeting" and ev.source["content"].get("meeting_id") == meet["meeting_id"]: mev.update(ev.source["content"])
    tester.add_event_callback(on_meet, UnknownEvent)
    await moh.room_send(rid, "com.amerteams.meeting", meet, ignore_unverified_devices=True)
    for _ in range(10):
        await sync(tester, n=1)
        if mev: break
    rows = q("select json from event_json where room_id=?", rid)
    check("12. Meeting invite delivered and encrypted at rest", mev.get("title") == "Ciena review" and not any("Ciena review" in r[0] for r in rows))

    for c in (moh, tester, outsider): await c.close()
    passed = sum(ok for _, ok, _ in results)
    print(f"\n{passed}/{len(results)} checks passed")
    json.dump([{"check": n, "pass": ok, "detail": d} for n, ok, d in results], open(os.getenv("OUT", "e2e_results.json"), "w"), indent=1)
    sys.exit(0 if passed == len(results) else 1)

asyncio.run(main())
