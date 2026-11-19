"""The other person in the in-use UI test: 'bob', a real end-to-end encrypted Matrix client (matrix-nio + Olm/Megolm)
that also joins real encrypted LiveKit calls using the post-quantum hybrid key (tools/pq_hybrid.py).

Behaviour (driven by what the app's user 'moh' does, or by text commands moh sends):
- replies "pong from Bob" to "ping"; sends read receipts for everything
- calls (protocol v2): sends ringing, then answers, publishes a 440 Hz tone, stays until hang-up
- "bob: decline next" / "bob: busy next" / "bob: ignore next" change how the next call is handled
- "bob: in 8s post updates": three unread messages (one mentions moh) for the catch-up digest
- "bob: call me" / "bob: video call me": bob calls moh
Writes a log of everything it saw to $PEER_LOG for the test report.
"""
import asyncio, base64, json, math, os, sys, tempfile, time
import httpx, numpy as np
from nio import AsyncClient, AsyncClientConfig, RoomMessageText, UnknownEvent
from livekit import rtc
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "tools"))
import pq_hybrid as pq

HS = os.getenv("HS", "http://localhost")
API = os.getenv("ORCH", f"{HS}/api")
SERVER = os.getenv("SERVER_NAME", "amer.test")
MOH, BOB = f"@moh:{SERVER}", f"@bob:{SERVER}"
LOG = open(os.getenv("PEER_LOG", "peer.log"), "a", buffering=1)
b64, unb64 = (lambda b: base64.b64encode(b).decode()), base64.b64decode
def ev_out(ev): return {**ev, "kc": b64(ev["kc"]), "wraps": {k: {f: b64(v) for f, v in w.items()} for k, w in ev["wraps"].items()}}
def ev_in(c): return {**c, "kc": unb64(c["kc"]), "key_index": int(c["key_index"]), "wraps": {k: {f: unb64(v) for f, v in w.items()} for k, w in c["wraps"].items()}}
def log(*a): print(time.strftime("%H:%M:%S"), *a, file=LOG); print("[peer]", *a, flush=True)

class Peer:
    def __init__(self):
        self.c = AsyncClient(HS, BOB, store_path=tempfile.mkdtemp(), config=AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True))
        self.mode = "answer"; self.room = None; self.pk, self.sk = pq.keygen()
        self.calls = {}; self.pq_devs = {}; self.lk = None; self.src = None; self.tone_task = None

    async def send(self, typ, content):
        self.trust()
        await self.c.room_send(self.room, typ, content, ignore_unverified_devices=True)

    def trust(self):
        for uid, devs in self.c.device_store.items():
            for d in devs.values():
                if d.device_id != self.c.device_id and not d.verified: self.c.verify_device(d)

    async def keys(self):
        if self.c.should_upload_keys: await self.c.keys_upload()
        if self.c.should_query_keys: await self.c.keys_query()
        if self.c.should_claim_keys: await self.c.keys_claim(self.c.get_users_for_key_claiming())

    async def setup(self):
        await self.c.login("Bob-Pass-123!", device_name="Bob (test peer)")
        await self.c.sync(timeout=1000, full_state=True); await self.keys()
        async with httpx.AsyncClient(timeout=15) as h:
            mt = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": "moh"}, "password": "Moh-Pass-123!",
                                                                    "initial_device_display_name": "setup (deleted)"})).json()
            M = {"Authorization": f"Bearer {mt['access_token']}"}
            r = await self.c.room_create(is_direct=True, invite=[MOH], initial_state=[{"type": "m.room.encryption", "state_key": "", "content": {"algorithm": "m.megolm.v1.aes-sha2"}}])
            self.room = r.room_id
            await h.post(f"{HS}/_matrix/client/v3/join/{self.room}", headers=M, json={})
            await h.put(f"{HS}/_matrix/client/v3/user/{MOH}/account_data/m.direct", headers=M, json={BOB: [self.room]})
            await h.put(f"{HS}/_matrix/client/v3/user/{BOB}/account_data/m.direct", headers={"Authorization": f"Bearer {self.c.access_token}"}, json={MOH: [self.room]})
            await h.post(f"{HS}/_matrix/client/v3/logout", headers=M)          # the app signs in with its own device
        await self.c.set_displayname("Bob Tester")
        await self.c.sync(timeout=1000); await self.keys()
        await self.send("com.amerteams.pq.device", {"user_id": BOB, "device_id": self.c.device_id, "alg": "ML-KEM-768",
                                                     "pk": base64.b64encode(self.pk).decode(), "body": "🔐 Quantum-safe device key"})
        log("ready", self.room, self.c.device_id)
        open(os.getenv("PEER_READY", "peer.ready"), "w").write(self.room)

    def base(self, cid): return {"call_id": cid, "party_id": self.c.device_id, "version": 2}
    def advert(self): return {"pq_alg": "ML-KEM-768", "pq_pk": b64(self.pk)}

    async def on_text(self, room, ev):
        if ev.sender == BOB: return
        log("text", repr(ev.body))
        await self.c.room_read_markers(room.room_id, ev.event_id, ev.event_id)
        b = ev.body.strip().lower()
        if b == "ping": await self.send("m.room.message", {"msgtype": "m.text", "body": "pong from Bob"})
        elif b.startswith("bob: decline next"): self.mode = "decline"
        elif b.startswith("bob: busy next"): self.mode = "busy"
        elif b.startswith("bob: ignore next"): self.mode = "ignore"
        elif b.startswith("bob: call me") or b.startswith("bob: video call me"): asyncio.create_task(self.call_moh(video="video" in b))
        elif b.startswith("bob: hang up"): asyncio.create_task(self.hangup_all())
        elif b.startswith("bob: type"):
            await self.c.room_typing(self.room, True, timeout=15000); await asyncio.sleep(10); await self.c.room_typing(self.room, False)
        elif b.startswith("bob: mention me"):
            await self.send("m.room.message", {"msgtype": "m.text", "body": "Moh Amer please review the plan",
                "format": "org.matrix.custom.html", "formatted_body": f'<a href="https://matrix.to/#/{MOH}">Moh Amer</a> please review the plan',
                "m.mentions": {"user_ids": [MOH]}})
        elif b.startswith("bob: in 8s post updates"):        # unread messages for the catch-up digest
            async def updates():
                await asyncio.sleep(8)
                for body, men in (("The OTN protection test passed on the Dubai ring.", False),
                                  ("Decision: we ship the RFP response on Sunday.", False),
                                  ("Moh Amer can you send the vendor comparison today?", True)):
                    await self.send("m.room.message", {"msgtype": "m.text", "body": body, **({"m.mentions": {"user_ids": [MOH]}} if men else {})})
            asyncio.create_task(updates())
        elif b.startswith("bob: in 20s say hi"):
            async def later():
                await asyncio.sleep(20); await self.send("m.room.message", {"msgtype": "m.text", "body": "hello while blocked"})
            asyncio.create_task(later())
        elif b.startswith("bob: in 20s call me"):
            async def later_call():
                await asyncio.sleep(20); await self.call_moh(video=False)
            asyncio.create_task(later_call())

    async def on_unknown(self, room, ev):
        t, c = ev.type, ev.source.get("content", {})
        if ev.sender == BOB or not t.startswith("com.amerteams."): return
        log("event", t, {k: v for k, v in c.items() if k in ("call_id", "reason", "outcome", "media", "key_index")})
        cid = c.get("call_id")
        if t == "com.amerteams.pq.device" and c.get("user_id") == ev.sender:
            self.pq_devs[f"{c['user_id']}|{c['device_id']}"] = (c["user_id"], c["device_id"], unb64(c["pk"])); return
        if c.get("pq_alg") == "ML-KEM-768" and c.get("pq_pk") and c.get("party_id"):      # key carried in invite / answer
            self.pq_devs[f"{ev.sender}|{c['party_id']}"] = (ev.sender, c["party_id"], unb64(c["pq_pk"]))
        if t == "com.amerteams.call.invite" and c.get("version") == 2:
            mode, self.mode = self.mode, "answer"
            if mode == "ignore": return
            if mode == "busy": await self.send("com.amerteams.call.reject", {**self.base(cid), "reason": "busy"}); return
            await self.send("com.amerteams.call.ringing", self.base(cid)); await asyncio.sleep(3)
            if mode == "decline": await self.send("com.amerteams.call.reject", {**self.base(cid), "reason": "declined"}); return
            self.calls[cid] = {"role": "callee"}
            await self.send("com.amerteams.call.answer", {**self.base(cid), **self.advert()})
        elif t == "com.amerteams.call.answer" and cid in self.calls and self.calls[cid]["role"] == "caller":
            await self.share_key(cid)
            await self.join(cid)
        elif t == "com.amerteams.call.key" and cid in self.calls and f"{BOB}|{self.c.device_id}" in c.get("wraps", {}):
            k = pq.open_call_key_event(ev_in(c), BOB, self.c.device_id, self.sk)
            log("got call key index", c.get("key_index"))
            if self.calls[cid].get("joined"): self.lk.e2ee_manager.key_provider.set_shared_key(base64.b64encode(k), c.get("key_index", 0))
            else: self.calls[cid]["key"] = (k, c.get("key_index", 0)); await self.join(cid)
        elif t in ("com.amerteams.call.hangup", "com.amerteams.call.end") and cid in self.calls:
            await self.leave(cid)

    async def call_moh(self, video=False):
        cid = f"bob{int(time.time())}"; self.calls[cid] = {"role": "caller"}
        await self.send("com.amerteams.call.invite", {**self.base(cid), **self.advert(), "media": "video" if video else "audio", "lifetime_ms": 45000,
                                                      "body": "📹 Video call" if video else "📞 Voice call"})
        log("calling moh", cid)

    async def share_key(self, cid):
        devs = [v for v in self.pq_devs.values() if v[0] != BOB] + [(BOB, self.c.device_id, self.pk)]
        ev, k = pq.new_call_key_event(cid, 0, devs)
        await self.send("com.amerteams.call.key", ev_out(ev))
        self.calls[cid]["key"] = (k, 0)
        log("shared key for", [f"{u}|{d}" for u, d, _ in devs])

    async def join(self, cid):
        st = self.calls[cid]
        if st.get("joined") or "key" not in st: return
        async with httpx.AsyncClient(timeout=15) as h:
            t = (await h.post(f"{API}/v1/calls/token", headers={"Authorization": f"Bearer {self.c.access_token}"}, json={"room_id": self.room, "call_id": cid, "display_name": "Bob Tester"})).json()
        k, idx = st["key"]
        opts = rtc.RoomOptions(e2ee=rtc.E2EEOptions(key_provider_options=rtc.KeyProviderOptions(shared_key=base64.b64encode(k))))
        self.lk = rtc.Room(); await self.lk.connect(t["url"], t["token"], options=opts)
        self.src = rtc.AudioSource(48000, 1)
        tr = rtc.LocalAudioTrack.create_audio_track("mic", self.src)
        await self.lk.local_participant.publish_track(tr, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_MICROPHONE))
        st["joined"] = True; log("joined media", cid, "participants", len(self.lk.remote_participants))
        self.tone_task = asyncio.create_task(self.tone())

    async def tone(self):
        n = 480; ph = 0
        while True:
            fr = rtc.AudioFrame.create(48000, 1, n)
            a = np.frombuffer(fr.data, dtype=np.int16)
            a[:] = (np.sin(2 * math.pi * 440 * (np.arange(n) + ph) / 48000) * 8000).astype(np.int16); ph += n
            await self.src.capture_frame(fr)

    async def leave(self, cid):
        if self.tone_task: self.tone_task.cancel(); self.tone_task = None
        if self.lk: await self.lk.disconnect(); self.lk = None
        self.calls.pop(cid, None); log("left", cid)

    async def hangup_all(self):
        for cid in list(self.calls):
            await self.send("com.amerteams.call.hangup", {**self.base(cid), "reason": "user_hangup"})
            await self.leave(cid)

    async def run(self):
        await self.setup()
        self.c.add_event_callback(self.on_text, RoomMessageText)
        self.c.add_event_callback(self.on_unknown, UnknownEvent)
        while True:
            await self.c.sync(timeout=3000); await self.keys(); self.trust()

asyncio.run(Peer().run())
