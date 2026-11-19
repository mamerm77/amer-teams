"""A second device of the same user ('moh') for the in-use test: starts emoji (SAS) verification with the app's device,
records the 7 emoji it computed to $OUT, confirms them, and reports whether the app's device ended up verified.
Uses matrix-nio's own SAS implementation, so the app is checked against an independent implementation of the spec."""
import asyncio, json, os, sys, tempfile
from nio import (AsyncClient, AsyncClientConfig, KeyVerificationAccept, KeyVerificationCancel, KeyVerificationKey,
                 KeyVerificationMac, ToDeviceError)

HS = os.getenv("HS", "http://localhost"); SERVER = os.getenv("SERVER_NAME", "amer.test")
ME = f"@moh:{SERVER}"; OUT = os.getenv("OUT", "moh2.json")
state = {"stage": "start", "emoji": [], "verified": False}
def save(**k): state.update(k); json.dump(state, open(OUT, "w"))

async def main():
    c = AsyncClient(HS, ME, store_path=tempfile.mkdtemp(), config=AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True))
    await c.login("Moh-Pass-123!", device_name="Moh second device (test)")
    await c.sync(timeout=2000, full_state=True)
    if c.should_upload_keys: await c.keys_upload()
    await c.keys_query()
    app_dev = next((d for d in c.device_store[ME].values() if d.device_id != c.device_id and "setup" not in (d.display_name or "")), None)
    if not app_dev: save(stage="error", error="app device not found"); return
    save(stage="starting", app_device=app_dev.device_id)

    async def on_accept(ev):
        sas = c.key_verifications[ev.transaction_id]; await c.to_device(sas.share_key()); save(stage="key-shared")
    async def on_key(ev):
        sas = c.key_verifications[ev.transaction_id]
        save(stage="emoji", emoji=[e[1] for e in sas.get_emoji()])          # names, e.g. "Dog", "Pizza"
        await asyncio.sleep(15)                                              # let the app show and the test compare them
        await c.confirm_short_auth_string(ev.transaction_id); save(stage="confirmed")
    async def on_mac(ev):
        sas = c.key_verifications[ev.transaction_id]
        try:
            for m in sas.get_mac():
                r = await c.to_device(m)
                if isinstance(r, ToDeviceError): save(stage="error", error=str(r))
        except Exception as e: save(stage="error", error=str(e)); return
        save(stage="done", verified=sas.verified)
    async def on_cancel(ev): save(stage="cancelled", error=getattr(ev, "reason", "cancelled"))
    c.add_to_device_callback(on_accept, KeyVerificationAccept)
    c.add_to_device_callback(on_key, KeyVerificationKey)
    c.add_to_device_callback(on_mac, KeyVerificationMac)
    c.add_to_device_callback(on_cancel, KeyVerificationCancel)

    await c.start_key_verification(app_dev); save(stage="started")
    for _ in range(90):                                                      # up to ~3 minutes
        await c.sync(timeout=2000)
        if state["stage"] in ("done", "cancelled", "error"): break
    await c.close()

asyncio.run(main())
