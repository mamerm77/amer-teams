"""Connector service (docs/TOOL_CONNECTORS.md). Receives tool webhooks on /hooks/{id}/{secret}, asks the orchestrator
whether the hook is genuine, and posts the formatted event into the chat as the end-to-end encrypted connectors
account. Joins only rooms that have a connector."""
import asyncio, json, logging, os, time
import io, math, struct, wave
import httpx, uvicorn
from fastapi import FastAPI, HTTPException, Request
from nio import AsyncClient, AsyncClientConfig, InviteMemberEvent, LoginResponse
from formatters import render

HS = os.getenv("HS", "http://synapse:8008"); ORCH = os.getenv("ORCH", "http://orchestrator:8080")
USER = os.getenv("AMER_CONNECTOR_USER", "connectors"); PASSWORD = os.environ.get("AMER_CONNECTOR_PASSWORD", "")
SECRET = os.environ.get("AMER_CONNECTOR_SECRET", ""); STORE = os.getenv("STORE_DIR", "/data/connectors")
logging.basicConfig(level=logging.INFO, format="%(asctime)s connectors %(levelname)s %(message)s"); log = logging.getLogger("connectors")
app = FastAPI(title="Amer connectors"); c: AsyncClient | None = None
H = {"X-Amer-Connector": SECRET}

async def login():
    global c
    os.makedirs(STORE, exist_ok=True); sess = os.path.join(STORE, "session.json")
    cfg = AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True)
    if os.path.exists(sess):
        s = json.load(open(sess)); c = AsyncClient(HS, s["user_id"], device_id=s["device_id"], store_path=STORE, config=cfg); c.restore_login(s["user_id"], s["device_id"], s["access_token"])
    else:
        server = os.getenv("SERVER_NAME"); c = AsyncClient(HS, f"@{USER}:{server}" if server else USER, store_path=STORE, config=cfg)
        r = await c.login(PASSWORD, device_name="Amer connectors")
        if not isinstance(r, LoginResponse): raise SystemExit(f"connectors login failed: {r}")
        json.dump({"user_id": r.user_id, "device_id": r.device_id, "access_token": r.access_token}, open(sess, "w")); os.chmod(sess, 0o600)
    await c.set_displayname("Connectors")

async def allowed_rooms() -> set[str]:
    async with httpx.AsyncClient(timeout=10) as x:
        r = await x.get(f"{ORCH}/v1/connectors/internal/rooms", headers=H)
    return set(r.json().get("rooms", [])) if r.status_code == 200 else set()

async def on_invite(room, ev: InviteMemberEvent):
    if ev.state_key != c.user_id or ev.membership != "invite": return
    if room.room_id in await allowed_rooms(): await c.join(room.room_id); log.info("joined %s", room.room_id)
    else: await c.room_leave(room.room_id); log.info("refused invite to %s (no connector there)", room.room_id)

def trust():
    for devs in c.device_store.values():
        for d in devs.values():
            if d.device_id != c.device_id and not d.verified: c.verify_device(d)

@app.post("/hooks/{cid}/{token}")
async def hook(cid: str, token: str, request: Request):
    async with httpx.AsyncClient(timeout=10) as x:
        r = await x.post(f"{ORCH}/v1/connectors/internal/check", headers=H, json={"id": cid, "token": token})
    if r.status_code != 200: raise HTTPException(403, "Unknown connector or wrong secret")
    info = r.json()
    try: body = await request.json()
    except Exception: body = {"text": (await request.body()).decode(errors="replace")}
    if info["room_id"] not in c.rooms:
        raise HTTPException(409, "The connectors account has not joined that chat yet: invite it from the chat")
    if c.should_query_keys: await c.keys_query()
    trust()
    text = render(info["kind"], info["name"], body if isinstance(body, dict) else {"text": str(body)}, dict(request.headers))
    res = await c.room_send(info["room_id"], "m.room.message", {"msgtype": "m.notice", "body": text, "com.amerteams.connector": cid}, ignore_unverified_devices=True)
    log.info("posted %s event to %s", info["kind"], info["room_id"][:8])        # no content in logs
    return {"ok": True, "event_id": getattr(res, "event_id", None)}

@app.get("/healthz")
async def health(): return {"status": "ok", "user": c.user_id if c else None}

async def sync_loop():
    while True:
        try:
            await c.sync(timeout=10000, full_state=True)
            if c.should_upload_keys: await c.keys_upload()
            if c.should_query_keys: await c.keys_query()
            if c.should_claim_keys: await c.keys_claim(c.get_users_for_key_claiming())
        except Exception as e:
            log.warning("sync failed, retrying: %s", e); await asyncio.sleep(5)

# ---------- voicemail: record phone calls nobody answered (docs/PHONE_DIALIN.md) ----------
VM_MAX_S = int(os.getenv("VOICEMAIL_MAX_S", "120"))

async def record_voicemail(job: dict):
    from livekit import rtc
    room = rtc.Room(); frames: list[bytes] = []; rate = 48000; done = asyncio.Event()
    async def take(track):
        nonlocal rate
        async for ev in rtc.AudioStream(track, sample_rate=48000, num_channels=1):
            frames.append(bytes(ev.frame.data)); rate = ev.frame.sample_rate
            if sum(len(f) for f in frames) >= VM_MAX_S * rate * 2: done.set(); break
    room.on("track_subscribed", lambda t, *_: asyncio.ensure_future(take(t)) if t.kind == rtc.TrackKind.KIND_AUDIO else None)
    room.on("participant_disconnected", lambda *_: done.set())
    await room.connect(job["url"], job["token"])
    src = rtc.AudioSource(48000, 1); tr = rtc.LocalAudioTrack.create_audio_track("beep", src)
    await room.local_participant.publish_track(tr, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
    for i in range(50):                                     # half a second of 880 Hz: "leave a message after the tone"
        pcm = struct.pack("<480h", *[int(9000 * math.sin(2 * math.pi * 880 * (i * 480 + n) / 48000)) for n in range(480)])
        await src.capture_frame(rtc.AudioFrame(pcm, 48000, 1, 480))
    try: await asyncio.wait_for(done.wait(), VM_MAX_S + 5)
    except asyncio.TimeoutError: pass
    await room.disconnect()
    pcm = b"".join(frames); secs = len(pcm) // 2 // rate
    if secs < 1: return await post_text(job["room_id"], f"📞 Missed call from {job['caller']} (no message left)")
    buf = io.BytesIO()
    with wave.open(buf, "wb") as w: w.setnchannels(1); w.setsampwidth(2); w.setframerate(rate); w.writeframes(pcm)
    data = buf.getvalue()
    up, keys = await c.upload(lambda *_: data, content_type="audio/wav", filename="voicemail.wav", encrypt=True, filesize=len(data))
    trust()
    await c.room_send(job["room_id"], "m.room.message", {"msgtype": "m.audio", "body": f"Voicemail from {job['caller']} ({secs} s)",
        "info": {"mimetype": "audio/wav", "size": len(data), "duration": secs * 1000}, "file": {"url": up.content_uri, **keys}}, ignore_unverified_devices=True)
    log.info("voicemail posted (%d s)", secs)

async def post_text(room_id, text):
    trust(); await c.room_send(room_id, "m.room.message", {"msgtype": "m.notice", "body": text}, ignore_unverified_devices=True)

async def voicemail_loop():
    while True:
        await asyncio.sleep(5)
        try:
            async with httpx.AsyncClient(timeout=10) as x:
                r = await x.post(f"{ORCH}/v1/phone/voicemail/claim", headers=H)
            job = r.json() if r.status_code == 200 else {}
            if job.get("call") and job.get("room_id") in c.rooms: await record_voicemail(job)
        except Exception as e:
            log.warning("voicemail: %s", type(e).__name__)

async def main():
    await login(); c.add_event_callback(on_invite, InviteMemberEvent)
    srv = uvicorn.Server(uvicorn.Config(app, host="0.0.0.0", port=int(os.getenv("PORT", "8070")), log_level="warning"))
    await asyncio.gather(sync_loop(), srv.serve(), voicemail_loop())

if __name__ == "__main__": asyncio.run(main())
