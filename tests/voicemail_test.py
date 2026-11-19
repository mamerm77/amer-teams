"""Voicemail on the real stack (docs/PHONE_DIALIN.md): a call nobody answers is recorded by the connector service
and posted, end-to-end encrypted, into the voicemail chat; a person decrypts it and gets a WAV of the caller's audio.
A LiveKit participant named like the SIP gateway's callers stands in for the carrier and speaks a test tone."""
import asyncio, io, json, math, os, secrets, struct, sys, tempfile, time, wave
import httpx, jwt
from livekit import rtc
from nio import AsyncClient, AsyncClientConfig, RoomMessageAudio, RoomEncryptedAudio, crypto
HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
LK_KEY, LK_SECRET = os.getenv("LIVEKIT_API_KEY", "devkey"), os.getenv("LIVEKIT_API_SECRET", "")
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def main():
    sfx = secrets.token_hex(3); u = f"recep{sfx}"; pw = "Vm-Test-123!"
    async with httpx.AsyncClient(timeout=30) as h:
        await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": u, "password": pw})
        c = AsyncClient(HS, f"@{u}:amer.test", store_path=tempfile.mkdtemp(), config=AsyncClientConfig(encryption_enabled=True, store_sync_tokens=True))
        await c.login(pw); await c.sync(timeout=3000)
        if c.should_upload_keys: await c.keys_upload()
        room = (await c.room_create(name="Phone line voicemail", initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])).room_id
        await h.put(f"{ORCH}/v1/phone/line", headers=ADM, json={"hunt_group": [f"@{u}:amer.test"], "voicemail_room": room})
        await c.room_invite(room, "@connectors:amer.test")
        for _ in range(20):
            await c.sync(timeout=2000); mem = await c.joined_members(room)
            if any(m.user_id == "@connectors:amer.test" for m in getattr(mem, "members", [])): break
        await asyncio.sleep(3)
        caller = f"+97150{secrets.randbelow(10**7):07d}"; lk = f"phone-in-{caller}"; now = int(time.time())
        t = jwt.encode({"iss": LK_KEY, "sub": f"sip_{caller}", "name": "Caller", "nbf": now - 5, "exp": now + 600, "video": {"room": lk, "roomJoin": True, "canPublish": True}}, LK_SECRET, algorithm="HS256")
        sip = rtc.Room(); await sip.connect("ws://127.0.0.1:7880", t)
        src = rtc.AudioSource(48000, 1); await sip.local_participant.publish_track(rtc.LocalAudioTrack.create_audio_track("voice", src), rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        heard_beep = asyncio.Event()
        async def listen(track):
            async for ev in rtc.AudioStream(track):
                if max(abs(x) for x in struct.unpack(f"<{len(bytes(ev.frame.data))//2}h", bytes(ev.frame.data))) > 3000: heard_beep.set(); break
        sip.on("track_subscribed", lambda tr, *_: asyncio.ensure_future(listen(tr)))
        async def speak(seconds):
            for i in range(seconds * 100):
                pcm = struct.pack("<480h", *[int(6000 * math.sin(2 * math.pi * 440 * (i * 480 + n) / 48000)) for n in range(480)])
                await src.capture_frame(rtc.AudioFrame(pcm, 48000, 1, 480))
        t0 = time.time()
        try: await asyncio.wait_for(heard_beep.wait(), 60)
        except asyncio.TimeoutError: pass
        check("1. Nobody answers: after about 30 s voicemail picks up and plays the tone", heard_beep.is_set(), f"{time.time() - t0:.0f} s")
        await speak(4); await sip.disconnect()
        vm = None
        for _ in range(30):
            s = await c.sync(timeout=2000)
            for ev in (s.rooms.join.get(room).timeline.events if room in s.rooms.join else []):
                if isinstance(ev, (RoomMessageAudio, RoomEncryptedAudio)) and "Voicemail" in ev.body: vm = ev
            if vm: break
        check("2. The voicemail is posted end-to-end encrypted into the voicemail chat, number masked", vm and "•" in vm.body and caller not in vm.body, vm.body if vm else None)
        secs = None
        if isinstance(vm, RoomEncryptedAudio):
            d = await c.download(vm.url); data = crypto.attachments.decrypt_attachment(d.body, vm.key["k"], vm.hashes["sha256"], vm.iv)
            w = wave.open(io.BytesIO(data)); fr = w.readframes(w.getnframes()); secs = w.getnframes() / w.getframerate()
            peak = max(abs(x) for x in struct.unpack(f"<{len(fr)//2}h", fr))
            check("3. The person decrypts a WAV holding the caller's audio", 3 <= secs <= 6 and peak > 2000, f"{secs:.1f} s, peak {peak}")
        else: check("3. The person decrypts a WAV holding the caller's audio", False, type(vm).__name__)
        late = await h.post(f"{ORCH}/v1/phone/inbound/{lk}/answer", headers={"Authorization": f"Bearer {c.access_token}"})
        check("4. A call taken by voicemail can no longer be answered", late.status_code in (409, 404), late.status_code)
        await c.close()
    json.dump(R, open(os.getenv("OUT", "/opt/amer/voicemail_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
