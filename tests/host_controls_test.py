"""Meeting host controls and webinar mode, live (Synapse + LiveKit + AI engine, no mocks)."""
import asyncio, json, math, os, secrets, sys
import httpx, numpy as np
from livekit import rtc, api

HS, ORCH = "http://127.0.0.1:8008", "http://127.0.0.1:8080"
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {detail}", flush=True)
q = lambda s: s.replace("!", "%21").replace(":", "%3A")

async def main():
    async with httpx.AsyncClient(timeout=15) as h:
        async def login(u):
            t = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": u}, "password": f"Pass-{u}-123"})).json()["access_token"]
            return {"Authorization": f"Bearer {t}"}
        A, B = await login("moh"), await login("tester")
        rid = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=A, json={"name": "Host test", "preset": "private_chat", "invite": ["@tester:amer.test"],
               "initial_state": [{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}]})).json()["room_id"]
        await h.post(f"{HS}/_matrix/client/v3/join/{q(rid)}", headers=B, json={})
        cid = "meet-" + secrets.token_hex(4)
        tok = lambda H: h.post(f"{ORCH}/v1/calls/token", headers=H, json={"room_id": rid, "call_id": cid})
        ta, tb = (await tok(A)).json(), (await tok(B)).json()
        check("1. Normal meeting: both are presenters", ta["role"] == tb["role"] == "presenter")
        ra, rb = rtc.Room(), rtc.Room()
        await ra.connect(ta["url"], ta["token"]); await rb.connect(tb["url"], tb["token"])
        async def publish(room):
            src = rtc.AudioSource(48000, 1); tr = rtc.LocalAudioTrack.create_audio_track("mic", src)
            await room.local_participant.publish_track(tr, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
            fr = rtc.AudioFrame.create(48000, 1, 480)
            for _ in range(20): await src.capture_frame(fr)
            return src
        await publish(ra); await publish(rb); await asyncio.sleep(1.5)
        ctl = lambda H, action, ident=None: h.post(f"{ORCH}/v1/meetings/control", headers=H, json={"room_id": rid, "call_id": cid, "action": action, "identity": ident})
        r = await ctl(B, "mute_all")
        check("2. Non-host cannot use host controls", r.status_code == 403, r.json().get("detail"))
        lkroom = ta["livekit_room"]
        async def muted(ident):
            async with api.LiveKitAPI("http://127.0.0.1:7880", "APIamer", "amer-test-secret-amer-test-secret-0123") as lk:
                ps = (await lk.room.list_participants(api.ListParticipantsRequest(room=lkroom))).participants
            p = next((p for p in ps if p.identity == ident), None)
            return None if p is None else all(t.muted for t in p.tracks if t.source == api.TrackSource.MICROPHONE)
        r = await ctl(A, "mute", "@tester:amer.test"); await asyncio.sleep(1)
        check("3. Host mutes one participant", r.status_code == 200 and await muted("@tester:amer.test") is True, r.json())
        r = await ctl(A, "mute_all");
        check("4. Host mutes everyone else", r.status_code == 200, r.json())
        r = await ctl(A, "remove", "@tester:amer.test"); await asyncio.sleep(1.5)
        check("5. Host removes a participant", r.status_code == 200 and rb.connection_state != rtc.ConnectionState.CONN_CONNECTED, rb.connection_state)

        # webinar mode
        await h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/com.amerteams.meeting.settings", headers=A, json={"mode": "webinar"})
        tb2, ta2 = (await tok(B)).json(), (await tok(A)).json()
        check("6. Webinar: attendee token cannot publish, host can", tb2["role"] == "attendee" and ta2["role"] == "presenter")
        rb2 = rtc.Room(); await rb2.connect(tb2["url"], tb2["token"])
        try:
            await asyncio.wait_for(publish(rb2), 6); pub_ok = True
        except Exception: pub_ok = False
        check("7. Webinar: media server refuses attendee microphone", not pub_ok)
        await h.put(f"{HS}/_matrix/client/v3/rooms/{q(rid)}/state/com.amerteams.meeting.settings", headers=A, json={"mode": "webinar", "presenters": ["@tester:amer.test"]})
        check("8. Webinar: host promotes attendee to presenter", (await tok(B)).json()["role"] == "presenter")
        r = await ctl(A, "end"); await asyncio.sleep(1.5)
        check("9. Host ends the meeting for everyone", r.status_code == 200 and ra.connection_state != rtc.ConnectionState.CONN_CONNECTED)
        for x in (ra, rb, rb2): await x.disconnect()
    p = sum(x["pass"] for x in R); print(f"\n{p}/{len(R)} host-control checks passed")
    json.dump(R, open(os.getenv("OUT", "host_results.json"), "w"), indent=1); sys.exit(0 if p == len(R) else 1)
asyncio.run(main())
