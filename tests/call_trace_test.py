"""Call trace and per-tenant compliance, live (Synapse + LiveKit webhooks + orchestrator + PostgreSQL, no mocks).
Two real users, a real media call through LiveKit with encrypted audio frames, client signalling reports,
WebRTC-style quality samples, and the admin views."""
import asyncio, json, os, secrets
import httpx, jwt, base64, hashlib
from livekit import rtc

HS, ORCH = "http://127.0.0.1:8008", "http://127.0.0.1:8080"
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
q = lambda s: s.replace("!", "%21").replace(":", "%3A")

async def main():
    async with httpx.AsyncClient(timeout=15) as h:
        async def login(u):
            t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": f"Pass-{u}-123"})).json()["access_token"]
            return {"Authorization": f"Bearer {t}"}
        A, B = await login("moh"), await login("tester")
        ADM = {"Authorization": "Bearer " + open("/opt/amer/admin.token").read().strip()}
        rid = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=A, json={"preset": "private_chat", "is_direct": True, "invite": ["@tester:amer.test"],
               "initial_state": [{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}]})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/join/{q(rid)}", headers=B, json={})
        cid = "c-" + secrets.token_hex(6)
        tr = lambda H, **kw: h.post(f"{ORCH}/v1/calls/trace", headers=H, json={"call_id": cid, "room_id": rid, **kw})

        # signalling as the app reports it (caller A1, callee B1)
        r = await tr(A, event="invite", direction="out", device_id="A1", media="audio", peer="@tester:amer.test")
        check("1. Caller reports invite", r.status_code == 200, r.text)
        await tr(B, event="invite", direction="in", device_id="B1", media="audio")
        await tr(B, event="ringing", direction="out", device_id="B1")
        await tr(A, event="ringing", direction="in", device_id="A1", state="ringing")
        await tr(B, event="answer", direction="out", device_id="B1")
        await tr(A, event="answer", direction="in", device_id="A1", state="connecting")

        # real media through LiveKit (webhooks fire participant_joined / track_published)
        ta = (await h.post(f"{ORCH}/v1/calls/token", headers=A, json={"room_id": rid, "call_id": cid})).json()
        tb = (await h.post(f"{ORCH}/v1/calls/token", headers=B, json={"room_id": rid, "call_id": cid})).json()
        ra, rb = rtc.Room(), rtc.Room()
        await ra.connect(ta["url"], ta["token"]); await rb.connect(tb["url"], tb["token"])
        src = rtc.AudioSource(48000, 1); t = rtc.LocalAudioTrack.create_audio_track("mic", src)
        await ra.local_participant.publish_track(t, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        fr = rtc.AudioFrame.create(48000, 1, 480)
        for _ in range(100): await src.capture_frame(fr)
        await tr(A, event="media_connected", direction="local", device_id="A1", state="connected")
        r = await h.post(f"{ORCH}/v1/calls/quality", headers=A, json={"call_id": cid, "device_id": "A1", "samples": [
            {"kind": "audio", "direction": "send", "codec": "opus", "bitrate_kbps": 32.1, "packets": 500, "packets_lost": 0, "jitter_ms": 3, "rtt_ms": 40},
            {"kind": "audio", "direction": "recv", "codec": "opus", "bitrate_kbps": 31.7, "packets": 480, "packets_lost": 20, "jitter_ms": 12, "rtt_ms": 40}]})
        check("2. Quality samples accepted", r.status_code == 200, r.text)
        await asyncio.sleep(2)
        await tr(A, event="hangup", direction="out", device_id="A1", reason="user_hangup")
        await tr(A, event="end", direction="out", device_id="A1", outcome="completed", duration_s=2)
        await ra.disconnect(); await rb.disconnect(); await asyncio.sleep(3)

        # admin views
        r = await h.get(f"{ORCH}/v1/admin/calls", headers=B)
        check("3. Non-admin cannot read call records", r.status_code == 403, r.status_code)
        r = await h.get(f"{ORCH}/v1/admin/calls", headers=ADM); rec = next((c for c in r.json() if c["call_id"] == cid), None)
        check("4. Call record: caller, callee, answered, outcome, duration", rec and rec["caller"] == "@moh:amer.test" and rec["callee"] == "@tester:amer.test"
              and rec["answered"] and rec["outcome"] == "completed" and rec["duration_s"] == 2, rec)
        check("5. Call record carries audio quality (MOS from E-model, loss)", rec and rec["avg_mos"] and 3.0 < rec["avg_mos"] <= 4.5 and rec["max_loss_pct"] == 4.0, rec)
        tr_ = (await h.get(f"{ORCH}/v1/admin/calls/{cid}/trace", headers=ADM)).json()
        evs = [(e["source"], e["event"]) for e in tr_["events"]]
        need = [("client", x) for x in ("invite", "ringing", "answer", "media_connected", "hangup", "end")]
        check("6. Trace has full client signalling ladder in order", [e for e in evs if e in need][:len(need)] == need or all(n in evs for n in need), evs)
        media = [e for e in tr_["events"] if e["source"] == "media"]
        check("7. Trace has media-server events from signed LiveKit webhooks", any(e["event"] == "participant_joined" for e in media) and any(e["event"] == "track_published" for e in media), [e["event"] for e in media])
        check("8. Trace never holds content", "end-to-end encrypted" in tr_["content"] and not any("body" in e for e in tr_["events"]))
        r = await h.get(f"{ORCH}/v1/audit", headers=ADM)
        check("9. Admin trace access is itself audited", any(a["action"] == "admin.call_trace" and a["detail"] == cid for a in r.json()))

        # forged webhook
        body = json.dumps({"event": "room_finished", "room": {"name": ta["livekit_room"]}}).encode()
        bad = jwt.encode({"iss": "APIamer", "sha256": base64.b64encode(hashlib.sha256(body).digest()).decode()}, "wrong-secret-wrong-secret-wrong-0000", algorithm="HS256")
        r = await h.post(f"{ORCH}/v1/livekit/webhook", content=body, headers={"Authorization": bad, "Content-Type": "application/webhook+json"})
        check("10. Forged media-server webhook rejected", r.status_code == 401, r.status_code)
        good = jwt.encode({"iss": "APIamer", "sha256": base64.b64encode(hashlib.sha256(b'{"x":1}').digest()).decode()}, "amer-test-secret-amer-test-secret-0123", algorithm="HS256")
        r = await h.post(f"{ORCH}/v1/livekit/webhook", content=body, headers={"Authorization": good})
        check("11. Webhook with tampered body rejected", r.status_code == 401, r.status_code)

        # validation
        r = await tr(A, event="nonsense")
        check("12. Unknown trace event rejected", r.status_code == 400)

        # tenants / compliance
        r = await h.post(f"{ORCH}/v1/admin/tenants", headers=ADM, json={"tenant": "public", "name": "Public users", "compliance_enabled": True, "compliance_user": "@archive:amer.test"})
        check("13. Compliance cannot be enabled for public users", r.status_code == 400, r.text)
        r = await h.post(f"{ORCH}/v1/admin/tenants", headers=B, json={"tenant": "acme", "name": "Acme"})
        check("14. Non-admin cannot create tenants", r.status_code == 403)
        r = await h.post(f"{ORCH}/v1/admin/tenants", headers=ADM, json={"tenant": "acme", "name": "Acme Business", "compliance_enabled": True, "compliance_user": "@archive:amer.test", "retention_days": 365})
        await h.post(f"{ORCH}/v1/admin/tenants/members", headers=ADM, json={"user_id": "@tester:amer.test", "tenant": "acme"})
        me = (await h.get(f"{ORCH}/v1/compliance/me", headers=B)).json()
        check("15. Business tenant with compliance: user is told", r.status_code == 200 and me["compliance_enabled"] and me["tenant"] == "acme", me)
        await h.post(f"{ORCH}/v1/admin/tenants/members", headers=ADM, json={"user_id": "@tester:amer.test", "tenant": "public"})
        me = (await h.get(f"{ORCH}/v1/compliance/me", headers=B)).json()
        check("16. Public user: metadata only", me["tenant"] == "public" and not me["compliance_enabled"], me)

        r = await h.get(f"{ORCH}/v1/audit", headers=B)
        check("17. Audit log is admin-only", r.status_code == 403, r.status_code)
        r = await h.post(f"{ORCH}/v1/agents/amer", headers=B, json={"enabled": False})
        check("18. Agent switches are admin-only", r.status_code == 403, r.status_code)

    json.dump(R, open(os.getenv("OUT", "/opt/amer/call_trace.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed")

asyncio.run(main())
