"""Browser join for guests and webinar registration, on the real local stack (docs/GUESTS.md, docs/WEBINARS.md).

A real host (livekit rtc, end-to-end encrypted with the call key) and a real browser guest (Chromium running the
/join page). The guest must stay in the lobby without the key, then decode the host's video only after the host
wraps the call key to the guest's one-time X25519 key. The orchestrator never sees the key. No mocks."""
import asyncio, base64, json, os, secrets, sys, time
import httpx, numpy as np
from livekit import rtc
from cryptography.hazmat.primitives.asymmetric.x25519 import X25519PrivateKey, X25519PublicKey
from cryptography.hazmat.primitives.ciphers.aead import AESGCM
from cryptography.hazmat.primitives.hashes import SHA256
from cryptography.hazmat.primitives.kdf.hkdf import HKDF
from cryptography.hazmat.primitives import serialization
from playwright.async_api import async_playwright

HS = os.getenv("HS", "http://127.0.0.1:8008"); ORCH = os.getenv("ORCH", "http://127.0.0.1:8080")
PUBLIC = os.getenv("PUBLIC", "https://teams.amer.test:8443")
ADM = {"Authorization": "Bearer " + open(os.getenv("ADMIN_TOKEN_FILE", "/opt/amer/admin.token")).read().strip()}
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)

def wrap(shared_key: str, guest_pk: bytes, idx: int, to: str) -> dict:
    eph = X25519PrivateKey.generate(); epk = eph.public_key().public_bytes(serialization.Encoding.Raw, serialization.PublicFormat.Raw)
    k = HKDF(algorithm=SHA256(), length=32, salt=epk + guest_pk, info=b"amer-guest-v1").derive(eph.exchange(X25519PublicKey.from_public_bytes(guest_pk)))
    n = os.urandom(12)
    return {"t": "gk", "to": to, "idx": idx, "epk": base64.b64encode(epk).decode(), "nonce": base64.b64encode(n).decode(),
            "ct": base64.b64encode(AESGCM(k).encrypt(n, shared_key.encode(), None)).decode()}

async def main():
    sfx = secrets.token_hex(3); pw = "Guest-Test-Pass-1!"
    async with httpx.AsyncClient(timeout=20) as h:
        assert (await h.post(f"{ORCH}/v1/admin/users", headers=ADM, json={"username": f"host{sfx}", "password": pw})).status_code == 200
        tok = (await h.post(f"{HS}/_matrix/client/v3/login", json={"type": "m.login.password", "identifier": {"type": "m.id.user", "user": f"host{sfx}"}, "password": pw})).json()["access_token"]
        H = {"Authorization": f"Bearer {tok}"}
        room = (await h.post(f"{HS}/_matrix/client/v3/createRoom", headers=H, json={"name": "Guest test"})).json()["room_id"]
        call_id = f"meet-{room}"
        link = (await h.post(f"{ORCH}/v1/guests/links", headers=H, json={"room_id": room, "call_id": call_id})).json()
        check("1. A host makes a guest link (code stored hashed, 24 h)", "code" in link and link["path"].startswith("/join#"), {k: v for k, v in link.items() if k != "code"})
        ct = (await h.post(f"{ORCH}/v1/calls/token", headers=H, json={"room_id": room, "call_id": call_id, "display_name": "Host"})).json()

        K = base64.b64encode(os.urandom(32)).decode()               # the call key, as the app hands it to the frame encryptor
        lk = rtc.Room(); got = asyncio.Queue()
        lk.on("data_received", lambda p: got.put_nowait((p.participant.identity if p.participant else "", json.loads(p.data.decode()))))
        await lk.connect(os.getenv("LK_WS", "ws://127.0.0.1:7880"), ct["token"], rtc.RoomOptions(e2ee=rtc.E2EEOptions(key_provider_options=rtc.KeyProviderOptions(shared_key=K.encode()))))
        src = rtc.VideoSource(320, 240); track = rtc.LocalVideoTrack.create_video_track("cam", src)
        await lk.local_participant.publish_track(track, rtc.TrackPublishOptions(source=rtc.TrackSource.SOURCE_CAMERA))
        frame = np.zeros((240, 320, 4), np.uint8); frame[..., 0] = 230; frame[..., 1] = 40; frame[..., 2] = 40; frame[..., 3] = 255   # red
        async def pump():
            while True:
                src.capture_frame(rtc.VideoFrame(320, 240, rtc.VideoBufferType.RGBA, frame.tobytes())); await asyncio.sleep(1 / 15)
        pumper = asyncio.create_task(pump())

        async with async_playwright() as p:
            b = await p.chromium.launch(args=["--use-fake-ui-for-media-stream", "--use-fake-device-for-media-stream", "--host-resolver-rules=MAP teams.amer.test 127.0.0.1", "--disable-features=WebRtcHideLocalIpsWithMdns"])
            ctx = await b.new_context(ignore_https_errors=True); page = await ctx.new_page()
            page.on("console", lambda m: print("  page:", m.type, m.text)); page.on("pageerror", lambda e: print("  pageerror:", e))
            await page.goto(f"{PUBLIC}/join#{link['code']}")
            check("2. The join link's code is removed from the address bar", "#" not in page.url, page.url)
            await page.fill("#name", "Sara"); await page.click("#go")
            try: await page.wait_for_function("document.getElementById('st').textContent.includes('lobby')", timeout=20000)
            except Exception: print("msg:", await page.text_content("#msg"), "| st:", await page.text_content("#st")); raise
            ident, hello = None, None
            t0 = time.time()
            while time.time() - t0 < 20:
                ident, m = await asyncio.wait_for(got.get(), 20)
                if m.get("t") == "gk-hello" and ident.startswith("guest-"): hello = m; break
            check("3. The guest joins the lobby and announces a one-time X25519 key", hello is not None and len(base64.b64decode(hello["pk"])) == 32, ident)
            names = [q.name for q in lk.remote_participants.values()]
            check("4. The guest shows as a guest by name", "Sara (guest)" in names, names)
            await asyncio.sleep(3)
            dark = await page.evaluate("[...document.querySelectorAll('video')].filter(v => v.videoWidth > 0).length")
            check("5. Without the key, the guest's page decodes no video (lobby)", dark == 0, dark)

            await lk.local_participant.publish_data(json.dumps(wrap(K, base64.b64decode(hello["pk"]), 0, ident)).encode(), reliable=True, topic="meeting")
            await page.wait_for_function("document.getElementById('st').textContent.includes('Admitted')", timeout=20000)
            colour = None
            for _ in range(30):
                colour = await page.evaluate("""() => { const v = [...document.querySelectorAll('video')].find(v => v.videoWidth > 0); if (!v) return null;
                  const c = document.createElement('canvas'); c.width = 32; c.height = 24; const g = c.getContext('2d'); g.drawImage(v, 0, 0, 32, 24);
                  const d = g.getImageData(0, 0, 32, 24).data; let r = 0, gg = 0, bb = 0; for (let i = 0; i < d.length; i += 4) { r += d[i]; gg += d[i+1]; bb += d[i+2]; }
                  const n = d.length / 4; return [r / n, gg / n, bb / n]; }""")
                if colour and colour[0] > 150 and colour[1] < 100: break
                await asyncio.sleep(1)
            check("6. Admitted: the guest decrypts and shows the host's end-to-end encrypted video (red frame)", bool(colour) and colour[0] > 150 and colour[1] < 100 and colour[2] < 100, colour)

            await page.fill("#q", "When is the next release?"); await page.click("#ask")
            q = None
            for _ in range(10):
                try: _, m = await asyncio.wait_for(got.get(), 5)
                except asyncio.TimeoutError: continue
                if m.get("t") == "qa" and m.get("op") == "ask": q = m; break
            check("7. Q&A: the guest's question reaches the host", q and q["q"] == "When is the next release?" and q["name"] == "Sara", q)
            await lk.local_participant.publish_data(json.dumps({"t": "qa", "op": "answered", "id": q["id"]}).encode(), reliable=True, topic="meeting")
            await page.wait_for_function("document.getElementById('ql').textContent.includes('✓')", timeout=10000)
            check("8. Q&A: the host marks it answered on the guest's screen", True)

            # webinar: register through the page, join as an attendee
            w = (await h.post(f"{ORCH}/v1/webinars", headers=H, json={"room_id": room, "call_id": call_id, "title": "Quarterly town hall"})).json()
            p2 = await ctx.new_page(); await p2.goto(f"{PUBLIC}/join?w={w['slug']}")
            await p2.wait_for_function("document.getElementById('wtitle').textContent === 'Quarterly town hall'", timeout=10000)
            await p2.fill("#rname", "Omar"); await p2.fill("#remail", f"omar{sfx}@example.com"); await p2.click("#rgo")
            await p2.wait_for_function("document.getElementById('rmsg').textContent.includes('registered')", timeout=10000)
            check("9. Webinar: a person registers on the public page and gets a personal join link", True)
            regs = (await h.get(f"{ORCH}/v1/webinars/{w['slug']}/registrations", headers=H)).json()["registrations"]
            check("10. Webinar: the host sees the registration", [r["name"] for r in regs] == ["Omar"], regs)
            await p2.click("#go")
            await p2.wait_for_function("document.getElementById('st').textContent.includes('lobby')", timeout=20000)
            omar = None
            for _ in range(20):
                omar = next((q for q in lk.remote_participants.values() if q.name == "Omar (guest)"), None)
                if omar: break
                await asyncio.sleep(0.5)
            check("11. Webinar: the registrant joins as an attendee and cannot publish (enforced in the token)",
                  omar is not None and not omar.permissions.can_publish and await p2.evaluate("document.getElementById('mic').hidden"), omar.permissions)
            again = (await h.post(f"{ORCH}/v1/webinars/{w['slug']}/close", headers=H)).json()
            r2 = await h.post(f"{ORCH}/v1/webinars/public/{w['slug']}/register", json={"name": "Late", "email": f"late{sfx}@example.com"})
            check("12. Webinar: after the host closes registration, nobody else can register", r2.status_code == 404, r2.status_code)
            await b.close()
        pumper.cancel(); await lk.disconnect()
    ok = all(r["pass"] for r in R)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/guest_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if ok else 1)

asyncio.run(main())
