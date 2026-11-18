"""Amer Teams — protocol conformance and persistence tests against live servers over TLS.

Layers tested (all real, no mocks):
  TLS 1.3 + HSTS (Caddy)          Matrix Client-Server API v3 over HTTPS
  Olm (Curve25519/Ed25519)         Megolm (AES-256 ratchet)
  LiveKit signalling over WSS      ICE / DTLS-SRTP transport (WebRTC stats)
  Frame E2EE AES-GCM + key rotation   JWT access tokens (expiry, signature)
  PostgreSQL schema + persistence   hash-chained append-only audit log
"""
import asyncio, base64, hashlib, json, math, os, secrets, ssl, subprocess, sys, tempfile, time
import httpx, jwt, numpy as np, psycopg
from nio import AsyncClient, AsyncClientConfig, RoomMessageText, UnknownEvent
from livekit import rtc, api

BASE = os.getenv("BASE", "https://teams.amer.test:8443")
CA = os.getenv("CA", "/opt/amer/ca.crt")
HS, ORCH = BASE, BASE + "/api"
LK_KEY, LK_SECRET = "APIamer", "amer-test-secret-amer-test-secret-0123"
SYN_DB = os.getenv("SYN_DB", "postgresql://synapse:syn-pass@127.0.0.1/synapse")
AMER_DB = os.getenv("AMER_DB", "postgresql://amer:amer-pass@127.0.0.1/amer")
os.environ["SSL_CERT_FILE"] = CA
R = []
def check(layer, name, ok, detail=""):
    R.append({"layer": layer, "check": name, "pass": bool(ok), "detail": str(detail)})
    print(f"[{'PASS' if ok else 'FAIL'}] {layer:<22} {name}  {detail}", flush=True)

async def mk(u):
    sslctx = ssl.create_default_context(cafile=CA)
    c = AsyncClient(HS, f"@{u}:amer.test", store_path=tempfile.mkdtemp(), ssl=sslctx,
                    config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
    await c.login(f"Pass-{u}-123", device_name=f"proto-{u}")
    return c

async def sync(*cs, n=1):
    for _ in range(n): await asyncio.gather(*[c.sync(timeout=1500, full_state=True) for c in cs])

async def wait_for(cond, *cs, tries=12):
    for _ in range(tries):
        if cond(): return True
        await sync(*cs)
    return cond()

def tone(freq, SR=48000):
    n = [0]
    def frame(F=480):
        t = (np.arange(F) + n[0]) / SR; n[0] += F
        fr = rtc.AudioFrame.create(SR, 1, F)
        np.copyto(np.frombuffer(fr.data, dtype=np.int16), (np.sin(2 * math.pi * freq * t) * 12000).astype(np.int16))
        return fr
    return frame

def energy(x, f0, SR=48000):
    x = x[-SR * 2:].astype(float)
    if x.size < SR // 2 or np.abs(x).max() < 50: return 0.0
    s = np.abs(np.fft.rfft(x)); f = np.fft.rfftfreq(x.size, 1 / SR)
    return float(s[(f > f0 - 10) & (f < f0 + 10)].sum() / s.sum())

async def record(room, secs):
    fut = asyncio.get_event_loop().create_future()
    def got(t, *_):
        if t.kind == rtc.TrackKind.KIND_AUDIO and not fut.done(): fut.set_result(t)
    room.on("track_subscribed", got)
    for p in room.remote_participants.values():
        for pb in p.track_publications.values():
            if pb.track and pb.track.kind == rtc.TrackKind.KIND_AUDIO and not fut.done(): fut.set_result(pb.track)
    try: t = await asyncio.wait_for(fut, 10)
    except asyncio.TimeoutError: return np.zeros(1)
    out, end = [], time.time() + secs
    async for ev in rtc.AudioStream(t, sample_rate=48000, num_channels=1):
        out.append(np.frombuffer(ev.frame.data, dtype=np.int16).copy())
        if time.time() > end: break
    return np.concatenate(out)

async def main():
    # ---------- TLS ----------
    out = subprocess.run(["openssl", "s_client", "-connect", "teams.amer.test:8443", "-servername", "teams.amer.test", "-CAfile", CA],
                         input=b"", capture_output=True, timeout=10).stdout.decode()
    check("TLS", "TLS 1.3 negotiated, certificate verified", "TLSv1.3" in out and "Verify return code: 0" in out)
    old = subprocess.run(["openssl", "s_client", "-connect", "teams.amer.test:8443", "-tls1_1"], input=b"", capture_output=True, timeout=10)
    check("TLS", "TLS 1.1 and below refused", b"Cipher is (NONE)" in old.stdout or old.returncode != 0)
    async with httpx.AsyncClient(verify=CA, http2=False) as h:
        r = await h.get(f"{HS}/_matrix/client/versions")
        check("TLS", "HSTS header present", "max-age=63072000" in r.headers.get("strict-transport-security", ""))
        try:
            import certifi; await httpx.AsyncClient(verify=ssl.create_default_context(cafile=certifi.where()), trust_env=False).get(f"{HS}/_matrix/client/versions")
            check("TLS", "Untrusted certificate rejected by client", False)
        except Exception:
            check("TLS", "Untrusted certificate rejected by client", True)
        # ---------- Matrix CS API ----------
        v = r.json()["versions"]
        check("Matrix C-S API", "Spec versions advertised (v1.1+)", "v1.1" in v, ", ".join(v[-3:]))
        bad = await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": "moh"}, "password": "wrong"})
        check("Matrix C-S API", "Wrong password rejected (M_FORBIDDEN)", bad.status_code == 403 and bad.json().get("errcode") == "M_FORBIDDEN")
        un = await h.get(f"{HS}/_matrix/client/v3/account/whoami")
        check("Matrix C-S API", "Unauthenticated request rejected", un.status_code == 401)

    moh, tester, outsider = await mk("moh"), await mk("tester"), await mk("outsider")
    await sync(moh, tester, outsider, n=2)
    for c in (moh, tester):
        if c.should_upload_keys: await c.keys_upload()
    async with httpx.AsyncClient(verify=CA) as h:
        q = (await h.post(f"{HS}/_matrix/client/v3/keys/query", headers={"Authorization": f"Bearer {moh.access_token}"},
                          json={"device_keys": {"@tester:amer.test": [tester.device_id]}})).json()
    dk = q["device_keys"]["@tester:amer.test"][tester.device_id]
    check("Olm", "Device keys published (curve25519 + ed25519, signed)",
          any(k.startswith("curve25519:") for k in dk["keys"]) and any(k.startswith("ed25519:") for k in dk["keys"]) and "signatures" in dk,
          ", ".join(dk["algorithms"]))

    rid = (await moh.room_create(name="proto", invite=["@tester:amer.test"])).room_id
    await sync(moh, tester); await tester.join(rid); await sync(moh, tester, n=3)
    await moh.keys_query(); await tester.keys_query()
    for c in (moh, tester):
        for devs in c.device_store.values():
            for d in devs.values():
                if d.device_id != c.device_id: c.verify_device(d)
    txt = "megolm-probe-" + secrets.token_hex(4); got = {}
    tester.add_event_callback(lambda r_, e: got.update(b=e.body) if e.body == txt else None, RoomMessageText)
    await moh.room_send(rid, "m.room.message", {"msgtype": "m.text", "body": txt}, ignore_unverified_devices=True)
    await wait_for(lambda: "b" in got, tester)
    olm_sessions = sum(len(v) for v in moh.olm.session_store._entries.values()) if hasattr(moh.olm.session_store, "_entries") else len(list(moh.olm.session_store))
    check("Olm", "Olm session established to peer device", olm_sessions > 0, f"{olm_sessions} session(s)")
    with psycopg.connect(SYN_DB) as c:
        ev = c.execute("SELECT json FROM event_json WHERE room_id=%s", (rid,)).fetchall()
    enc = [json.loads(e[0]) for e in ev if '"m.room.encrypted"' in e[0]]
    check("Megolm", "Message decrypted by recipient", got.get("b") == txt)
    check("Megolm", "Ciphertext uses m.megolm.v1.aes-sha2 in DB", enc and enc[-1]["content"]["algorithm"] == "m.megolm.v1.aes-sha2" and not any(txt in e[0] for e in ev),
          f"{len(enc)} encrypted event(s) in PostgreSQL")

    # ---------- LiveKit signalling + JWT ----------
    K0 = secrets.token_bytes(32); call_id = secrets.token_hex(6); keys = {}
    def on_key(r_, e):
        c_ = e.source.get("content", {})
        if e.type == "com.amerteams.call.key" and c_.get("call_id") == call_id: keys[c_["key_index"]] = base64.b64decode(c_["key"])
    tester.add_event_callback(on_key, UnknownEvent)
    await moh.room_send(rid, "com.amerteams.call.key", {"call_id": call_id, "key": base64.b64encode(K0).decode(), "key_index": 0}, ignore_unverified_devices=True)
    await wait_for(lambda: 0 in keys, tester)
    async with httpx.AsyncClient(verify=CA) as h:
        tk = lambda c: h.post(f"{ORCH}/v1/calls/token", headers={"Authorization": f"Bearer {c.access_token}"}, json={"room_id": rid, "call_id": call_id})
        tm, tt = (await tk(moh)).json(), (await tk(tester)).json()
    claims = jwt.decode(tm["token"], LK_SECRET, algorithms=["HS256"])
    check("JWT", "Token is HS256, scoped to one room, expires", claims["video"]["room"] == tm["livekit_room"] and claims["exp"] - claims["nbf"] <= 3700)
    wss = BASE.replace("https", "wss") + "/livekit"
    async def try_join(tok):
        r_ = rtc.Room()
        try: await asyncio.wait_for(r_.connect(wss, tok), 8); await r_.disconnect(); return True
        except Exception: return False
    now_ = int(time.time())
    expired = jwt.encode({**claims, "sub": "late", "nbf": now_ - 1200, "exp": now_ - 600}, LK_SECRET, algorithm="HS256")  # expired 10 min ago
    forged = jwt.encode({**claims, "sub": "forger"}, "wrong-secret-wrong-secret-wrong-sec", algorithm="HS256")
    check("JWT", "Expired token refused by SFU", not await try_join(expired))
    check("JWT", "Forged signature refused by SFU", not await try_join(forged))

    e2ee = lambda k: rtc.RoomOptions(e2ee=rtc.E2EEOptions(key_provider_options=rtc.KeyProviderOptions(shared_key=k)))
    pub, sub, old = rtc.Room(), rtc.Room(), rtc.Room()
    await pub.connect(wss, tm["token"], e2ee(K0)); await sub.connect(wss, tt["token"], e2ee(keys[0]))
    otok = api.AccessToken(LK_KEY, LK_SECRET).with_identity("ex-member").with_grants(api.VideoGrants(room_join=True, room=tm["livekit_room"])).to_jwt()
    await old.connect(wss, otok, e2ee(K0))
    check("LiveKit signalling", "Clients joined over WSS (TLS)", pub.isconnected() and sub.isconnected())

    src = rtc.AudioSource(48000, 1); gen = tone(440)
    await pub.local_participant.publish_track(rtc.LocalAudioTrack.create_audio_track("mic", src), rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
    stop = asyncio.Event()
    async def produce():
        while not stop.is_set(): await src.capture_frame(gen())
    prod = asyncio.create_task(produce())
    a_sub, a_old = await asyncio.gather(record(sub, 4), record(old, 4))
    check("Frame E2EE (AES-GCM)", "Key 0: member decrypts audio", energy(a_sub, 440) > 0.5, f"{energy(a_sub, 440):.2f}")

    # ---------- ICE / DTLS-SRTP from WebRTC stats ----------
    st = await pub.get_rtc_stats()
    blob = str(st)
    check("ICE", "ICE candidate pair succeeded", "SUCCEEDED" in blob.upper() or "succeeded" in blob)
    check("DTLS-SRTP", "DTLS transport connected", "dtls_state" in blob.lower() and ("CONNECTED" in blob.upper()))
    srtp = [s for s in blob.split(",") if "srtp_cipher" in s.lower()]
    check("DTLS-SRTP", "SRTP cipher negotiated", any(("AES" in s.upper() or "AEAD" in s.upper()) for s in srtp), srtp[0].strip()[:60] if srtp else "")

    # ---------- key rotation: member leaves -> new key, ex-member locked out ----------
    K1 = secrets.token_bytes(32)
    await moh.room_send(rid, "com.amerteams.call.key", {"call_id": call_id, "key": base64.b64encode(K1).decode(), "key_index": 1}, ignore_unverified_devices=True)
    await wait_for(lambda: 1 in keys, tester)
    for room_, k_ in ((pub, K1), (sub, keys[1])):          # every member installs key 1 and switches to it
        room_.e2ee_manager.key_provider.set_shared_key(k_, 1)
        for fc in room_.e2ee_manager.frame_cryptors(): fc.set_key_index(1)
    await asyncio.sleep(1.5)
    a_sub2, a_old2 = await asyncio.gather(record(sub, 4), record(old, 4))
    stop.set(); await prod
    check("Frame E2EE (AES-GCM)", "Key 1 delivered via Megolm", keys.get(1) == K1)
    check("Frame E2EE (AES-GCM)", "After rotation: member still decrypts", energy(a_sub2, 440) > 0.5, f"{energy(a_sub2, 440):.2f}")
    check("Frame E2EE (AES-GCM)", "After rotation: holder of old key locked out", energy(a_old2, 440) < 0.2, f"{energy(a_old2, 440):.2f}")
    for r_ in (pub, sub, old): await r_.disconnect()

    # ---------- PostgreSQL persistence ----------
    with psycopg.connect(SYN_DB) as c:
        n_tables = c.execute("SELECT count(*) FROM information_schema.tables WHERE table_schema='public'").fetchone()[0]
        enc_ok = c.execute("SELECT datcollate, pg_encoding_to_char(encoding) FROM pg_database WHERE datname='synapse'").fetchone()
    check("PostgreSQL (Synapse)", "Schema created, UTF8 + C collation", n_tables > 100 and enc_ok == ("C", "UTF8"), f"{n_tables} tables, {enc_ok}")
    async with httpx.AsyncClient(verify=CA) as h:
        H = {"Authorization": f"Bearer {moh.access_token}"}
        await h.post(f"{ORCH}/v1/agents/trans", headers=H, json={"enabled": False})
    subprocess.run(["pkill", "-f", "bin/uvicorn app.main"]); await asyncio.sleep(1)
    subprocess.Popen("exec >/dev/null 2>&1 </dev/null; cd /home/claude/amer-teams/services/orchestrator && . /opt/amer/venv/bin/activate && "
                     "SYNAPSE_URL=http://127.0.0.1:8008 LIVEKIT_HTTP_URL=http://127.0.0.1:7880 LIVEKIT_API_KEY=APIamer SYNAPSE_ADMIN_TOKEN=$(cat /opt/amer/admin.token) "
                     f"LIVEKIT_API_SECRET={LK_SECRET} LIVEKIT_PUBLIC_URL={wss} setsid uvicorn app.main:app --port 8080 >> /opt/amer/orch.log 2>&1 &",
                     shell=True, executable="/bin/bash")
    await asyncio.sleep(6)
    async with httpx.AsyncClient(verify=CA) as h:
        ag = {a["id"]: a for a in (await h.get(f"{ORCH}/v1/agents", headers=H)).json()}
        ver = (await h.get(f"{ORCH}/v1/audit/verify", headers=H)).json()
        await h.post(f"{ORCH}/v1/agents/trans", headers=H, json={"enabled": True})
    check("PostgreSQL (Amer)", "Agent setting survives service restart", ag["trans"]["enabled"] is False)
    with psycopg.connect(AMER_DB) as c:
        tabs = {r[0] for r in c.execute("SELECT tablename FROM pg_tables WHERE schemaname='public'")}
        calls = c.execute("SELECT count(*) FROM call_sessions WHERE call_id=%s", (call_id,)).fetchone()[0]
        joins = c.execute("SELECT count(*) FROM audit_log WHERE action='call.join' AND detail=%s", (call_id,)).fetchone()[0]
        samples = c.execute("SELECT count(*) FROM ops_samples").fetchone()[0]
    need = {"audit_log", "agent_config", "ai_requests", "call_sessions", "ops_samples", "media_samples", "schema_migrations"}
    check("PostgreSQL (Amer)", "All 7 tables created by migration", need <= tabs)
    check("PostgreSQL (Amer)", "Call sessions and audit rows written", calls == 2 and joins == 2, f"{calls} sessions, {joins} audit rows")
    check("PostgreSQL (Amer)", "Monitoring samples persisted", samples > 0, f"{samples} rows")
    check("Audit integrity", "Hash chain verifies", ver["intact"] and ver["entries"] > 0, f"{ver['entries']} entries")
    try:
        with psycopg.connect(AMER_DB) as c: c.execute("UPDATE audit_log SET detail='tampered' WHERE id=(SELECT min(id) FROM audit_log)")
        check("Audit integrity", "Tampering blocked by append-only trigger", False)
    except psycopg.errors.RaiseException:
        check("Audit integrity", "Tampering blocked by append-only trigger", True)

    for c in (moh, tester, outsider): await c.close()
    p = sum(r["pass"] for r in R); print(f"\n{p}/{len(R)} protocol checks passed")
    json.dump(R, open(os.getenv("OUT", "protocol_results.json"), "w"), indent=1)
    sys.exit(0 if p == len(R) else 1)

asyncio.run(main())
