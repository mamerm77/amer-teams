"""Post-quantum hybrid call keys — tests (protocol amer-pq-hybrid-v1).

Part A  cryptographic checks of the reference implementation
Part B  writes deterministic test vectors for the Dart client (app/test/pq_vectors.json);
        CI runs `flutter test` which must reproduce them byte for byte
Part C  live: device keys and hybrid call keys exchanged over real Megolm between two users,
        then a real LiveKit call encrypted with the derived key
"""
import asyncio, base64, hashlib, json, math, os, secrets, ssl, sys, tempfile, time
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import pq_hybrid as pq
from kyber_py.ml_kem import ML_KEM_768 as MLKEM

R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
b64 = lambda b: base64.b64encode(b).decode()

# ---------------- Part A ----------------
pk, sk = pq.keygen()
check("A1. ML-KEM-768 sizes per FIPS 203 (pk 1184, sk 2400, ct 1088)", (len(pk), len(sk)) == (1184, 2400) and len(MLKEM.encaps(pk)[1]) == 1088)
pk2, sk2 = pq.keygen()
ev, K = pq.new_call_key_event("call1", 0, [("@sara:x", "DEV1", pk), ("@omar:x", "DEV2", pk2)])
check("A2. Each member device derives the same call key", pq.open_call_key_event(ev, "@sara:x", "DEV1", sk) == K == pq.open_call_key_event(ev, "@omar:x", "DEV2", sk2))
try: pq.open_call_key_event(ev, "@sara:x", "DEV1", sk2); bad = False
except pq.TamperError: bad = True
check("A3. Another device's secret key cannot open a wrap", bad)
t = dict(ev); t["wraps"] = dict(ev["wraps"]); w = dict(t["wraps"]["@sara:x|DEV1"]); w["ct"] = bytes([w["ct"][0] ^ 1]) + w["ct"][1:]; t["wraps"]["@sara:x|DEV1"] = w
try: pq.open_call_key_event(t, "@sara:x", "DEV1", sk); bad = False
except pq.TamperError: bad = True
check("A4. Tampered ciphertext is rejected", bad)
try: pq.unwrap(sk, ev["wraps"]["@sara:x|DEV1"], "call1", 1, "@sara:x", "DEV1"); bad = False
except pq.TamperError: bad = True
check("A5. Wrap cannot be replayed into another key index", bad)
k_pq = pq.unwrap(sk, ev["wraps"]["@sara:x|DEV1"], "call1", 0, "@sara:x", "DEV1")
check("A6. Breaking only the classical layer (K_c) is not enough", pq.call_key(ev["kc"], os.urandom(32), "call1", 0) != K)
check("A7. Breaking only ML-KEM (K_pq) is not enough", pq.call_key(os.urandom(32), k_pq, "call1", 0) != K)
check("A8. Key changes with rotation index", pq.call_key(ev["kc"], k_pq, "call1", 1) != K)

# ---------------- Part B: cross-implementation vectors ----------------
vec = []
for i in range(3):
    seed, m = hashlib.sha512(f"amer-seed-{i}".encode()).digest(), hashlib.sha256(f"amer-m-{i}".encode()).digest()
    vpk, vsk = pq.keygen(seed)
    ss, ct = MLKEM._encaps_internal(vpk, m)
    kc, kpq = hashlib.sha256(f"kc{i}".encode()).digest(), hashlib.sha256(f"kpq{i}".encode()).digest()
    wr = pq.wrap(vpk, kpq, f"call-{i}", i, "@moh:amer.test", f"DEV{i}", m)
    vec.append({"seed": b64(seed), "m": b64(m), "pk_sha256": hashlib.sha256(vpk).hexdigest(), "sk_sha256": hashlib.sha256(vsk).hexdigest(),
                "ct_sha256": hashlib.sha256(ct).hexdigest(), "ss": b64(ss), "call_id": f"call-{i}", "key_index": i,
                "user": "@moh:amer.test", "device": f"DEV{i}", "kc": b64(kc), "kpq": b64(kpq),
                "w": b64(wr["w"]), "t": b64(wr["t"]), "K": b64(pq.call_key(kc, kpq, f"call-{i}", i))})
out = os.path.join(os.path.dirname(__file__), "..", "app", "test", "pq_vectors.json")
json.dump(vec, open(out, "w"), indent=1)
check("B1. Deterministic vectors written for the Dart client", os.path.getsize(out) > 0, f"{len(vec)} vectors")

# ---------------- Part C: live over Megolm + LiveKit ----------------
async def live():
    import httpx, numpy as np
    from nio import AsyncClient, AsyncClientConfig, UnknownEvent
    from livekit import rtc
    BASE, CA = "https://teams.amer.test:8443", "/opt/amer/ca.crt"
    ctx = ssl.create_default_context(cafile=CA)
    async def mk(u):
        c = AsyncClient(BASE, f"@{u}:amer.test", store_path=tempfile.mkdtemp(), ssl=ctx, config=AsyncClientConfig(encryption_enabled=True))
        await c.login(f"Pass-{u}-123", device_name="pq"); return c
    moh, tester = await mk("moh"), await mk("tester")
    cs = (moh, tester)
    async def sync(n=1):
        for _ in range(n): await asyncio.gather(*[c.sync(timeout=1500, full_state=True) for c in cs])
    await sync(2)
    rid = (await moh.room_create(name="pq-call", invite=["@tester:amer.test"])).room_id
    await sync(); await tester.join(rid); await sync(3)
    for c in cs:
        if c.should_upload_keys: await c.keys_upload()
    await sync(2)
    for c in cs:
        if c.should_query_keys: await c.keys_query()
        for devs in c.device_store.values():
            for d in devs.values():
                if d.device_id != c.device_id: c.verify_device(d)
    seen = {}
    def on(room, e):
        if e.type.startswith("com.amerteams."): seen.setdefault(e.type, []).append(e.source["content"])
    for c in cs: c.add_event_callback(on, UnknownEvent)
    # each device publishes its ML-KEM-768 public key inside the encrypted room
    keys = {}
    for c in cs:
        p_, s_ = pq.keygen(); keys[c.user_id] = (c.device_id, p_, s_)
        await c.room_send(rid, "com.amerteams.pq.device", {"user_id": c.user_id, "device_id": c.device_id, "alg": "ML-KEM-768", "pk": b64(p_)}, ignore_unverified_devices=True)
    for _ in range(8):
        await sync()
        if len(seen.get("com.amerteams.pq.device", [])) >= 2: break
    devs = {(d["user_id"], d["device_id"]): base64.b64decode(d["pk"]) for d in seen.get("com.amerteams.pq.device", [])}
    check("C1. Device ML-KEM public keys exchanged inside encrypted room", len(devs) == 2, f"{len(devs)} devices")
    call_id = secrets.token_hex(6)
    ev, K = pq.new_call_key_event(call_id, 0, [(u, d, p_) for (u, d), p_ in devs.items()])
    wire = {**ev, "kc": b64(ev["kc"]), "wraps": {k: {f: b64(v) for f, v in w.items()} for k, w in ev["wraps"].items()}}
    await moh.room_send(rid, "com.amerteams.call.key", wire, ignore_unverified_devices=True)
    for _ in range(8):
        await sync()
        if any(e.get("call_id") == call_id for e in seen.get("com.amerteams.call.key", [])): break
    got = next(e for e in seen.get("com.amerteams.call.key", []) if e.get("call_id") == call_id)
    check("C2. Hybrid key event is %d KB for 2 devices (Megolm-encrypted)" % (len(json.dumps(got)) // 1024), got["alg"] == pq.ALG)
    did, _, tsk = keys[tester.user_id]
    rx = {**got, "kc": base64.b64decode(got["kc"]), "wraps": {k: {f: base64.b64decode(v) for f, v in w.items()} for k, w in got["wraps"].items()}}
    K_rx = pq.open_call_key_event(rx, tester.user_id, did, tsk)
    check("C3. Recipient derives identical hybrid call key", K_rx == K)
    async with httpx.AsyncClient(verify=CA) as h:
        tk = lambda c: h.post(f"{BASE}/api/v1/calls/token", headers={"Authorization": f"Bearer {c.access_token}"}, json={"room_id": rid, "call_id": call_id})
        tm, tt = (await tk(moh)).json(), (await tk(tester)).json()
    opts = lambda k: rtc.RoomOptions(e2ee=rtc.E2EEOptions(key_provider_options=rtc.KeyProviderOptions(shared_key=k)))
    pub, sub, classical = rtc.Room(), rtc.Room(), rtc.Room()
    await pub.connect(tm["url"], tm["token"], opts(K)); await sub.connect(tt["url"], tt["token"], opts(K_rx))
    from livekit import api
    ctok = api.AccessToken("APIamer", "amer-test-secret-amer-test-secret-0123").with_identity("classical-only").with_grants(api.VideoGrants(room_join=True, room=tm["livekit_room"])).to_jwt()
    await classical.connect(tm["url"], ctok, opts(pq.call_key(ev["kc"], os.urandom(32), call_id, 0)))  # attacker who broke only Megolm
    SR = 48000; src = rtc.AudioSource(SR, 1)
    await pub.local_participant.publish_track(rtc.LocalAudioTrack.create_audio_track("mic", src), rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
    stop = asyncio.Event(); n = [0]
    async def produce():
        while not stop.is_set():
            fr = rtc.AudioFrame.create(SR, 1, 480); t_ = (np.arange(480) + n[0]) / SR; n[0] += 480
            np.copyto(np.frombuffer(fr.data, dtype=np.int16), (np.sin(2 * math.pi * 440 * t_) * 12000).astype(np.int16)); await src.capture_frame(fr)
    async def rec(room):
        fut = asyncio.get_event_loop().create_future()
        room.on("track_subscribed", lambda tr, *_: fut.done() or fut.set_result(tr))
        for p in room.remote_participants.values():
            for pb in p.track_publications.values():
                if pb.track and not fut.done(): fut.set_result(pb.track)
        tr = await asyncio.wait_for(fut, 10); xs, end = [], time.time() + 4
        async for e in rtc.AudioStream(tr, sample_rate=SR, num_channels=1):
            xs.append(np.frombuffer(e.frame.data, dtype=np.int16).copy())
            if time.time() > end: break
        x = np.concatenate(xs)[-SR * 2:].astype(float)
        if np.abs(x).max() < 50: return 0.0
        s = np.abs(np.fft.rfft(x)); f = np.fft.rfftfreq(x.size, 1 / SR); return float(s[(f > 430) & (f < 450)].sum() / s.sum())
    task = asyncio.create_task(produce())
    e_sub, e_cl = await asyncio.gather(rec(sub), rec(classical)); stop.set(); await task
    check("C4. Live call with hybrid key: member hears audio", e_sub > 0.5, f"tone energy {e_sub:.2f}")
    check("C5. Attacker holding only the classical secret hears nothing", e_cl < 0.2, f"tone energy {e_cl:.2f}")
    for r_ in (pub, sub, classical): await r_.disconnect()
    for c in cs: await c.close()

if "--offline" not in sys.argv: asyncio.run(live())
p = sum(r["pass"] for r in R); print(f"\n{p}/{len(R)} post-quantum checks passed")
json.dump(R, open(os.getenv("OUT", "pq_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)
