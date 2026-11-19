"""A second device of the same user ('moh') for the in-use test: starts emoji (SAS) verification with the app's device,
records the 7 emoji it computed to $OUT, confirms them, and reports whether the app's device ended up verified.
Uses matrix-nio's own SAS implementation, so the app is checked against an independent implementation of the spec."""
import asyncio, json, os, sys, tempfile
import time, uuid
from nio import (AsyncClient, AsyncClientConfig, KeyVerificationAccept, KeyVerificationCancel, KeyVerificationKey,
                 KeyVerificationMac, ToDeviceError, UnknownToDeviceEvent)
from nio.crypto.sas import Sas
from nio.event_builders import ToDeviceMessage
from nio.crypto.olm_machine import Olm
from nio.events.to_device import ToDeviceEvent, KeyVerificationEvent

# matrix-nio decrypts Olm to-device messages but keeps only room-key types and drops the rest ("unsupported Olm
# event"). The app (matrix-dart-sdk) sends verification messages Olm-encrypted, which the spec allows, so feed
# decrypted verification messages to nio's own SAS state machine and to the callbacks.
_orig_handle = Olm._handle_olm_event
def _handle_olm_event(self, sender, sender_key, payload):
    if str(payload.get("type", "")).startswith("m.key.verification."):
        ev = ToDeviceEvent.parse_event({"sender": sender, "type": payload["type"], "content": payload.get("content", {})})
        if isinstance(ev, KeyVerificationEvent): self.handle_key_verification(ev)
        return ev
    return _orig_handle(self, sender, sender_key, payload)
Olm._handle_olm_event = _handle_olm_event

# matrix-nio 0.26 compares the SAS commitment as a hex SHA-256, but the spec (and matrix-dart-sdk) use unpadded
# base64, so nio wrongly reports a commitment mismatch against every spec-compliant client. Check it per spec.
import base64, hashlib
from nio.api import Api
def _check_commitment(self, key):
    d = hashlib.sha256(key.encode() + Api.to_canonical_json(self.start_verification().content).encode()).digest()
    return self.commitment in (base64.b64encode(d).decode().rstrip("="), d.hex())
Sas._check_commitment = _check_commitment

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
        if sas.canceled: save(stage="error", error=f"nio cancelled: {sas.cancel_code} {sas.cancel_reason}"); return
        save(stage="emoji", emoji=[e[0] for e in sas.get_emoji()], names=[e[1] for e in sas.get_emoji()],   # the emoji themselves; names differ by library ("Wrench"/"Spanner")
             diag={"txid": sas.transaction_id, "we_started": sas.we_started_it, "agreement": sas.chosen_key_agreement, "mac": sas.chosen_mac_method,
                   "own": [sas.own_user, sas.own_device], "other": [sas.other_olm_device.user_id, sas.other_olm_device.device_id],
                   "info_shape": sas._extra_info.replace(sas.pubkey, "<OUR_SAS_KEY>").replace(sas.their_sas_key or "-", "<THEIR_SAS_KEY>")})
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

    # Current spec (v1.1+): request -> ready -> start. matrix-nio only implements start onwards, so the request /
    # ready step is done here and nio's SAS then runs on the same transaction.
    txid = uuid.uuid4().hex
    async def on_unknown(ev):
        t, cont = ev.source.get("type"), ev.source.get("content", {})
        if str(t).startswith("m.key.verification."): state.setdefault("seen", []).append(t); save()
        if t == "m.key.verification.ready" and cont.get("transaction_id") == txid and txid not in c.key_verifications:
            sas = Sas(ME, c.device_id, c.olm.account.identity_keys["ed25519"], app_dev, transaction_id=txid)
            c.olm.key_verifications[txid] = sas
            await c.to_device(sas.start_verification()); save(stage="started (after ready)")
    c.add_to_device_callback(on_unknown, UnknownToDeviceEvent)
    # give the app time to learn about this new device (device-list update), as a real second device would
    for _ in range(5): await c.sync(timeout=2000)
    async def request():
        await c.to_device(ToDeviceMessage("m.key.verification.request", ME, app_dev.device_id,
            {"from_device": c.device_id, "methods": ["m.sas.v1"], "timestamp": int(time.time() * 1000), "transaction_id": txid}))
    await request(); save(stage="requested")
    for n in range(90):                                                      # up to ~3 minutes; re-request until the app answers
        if n % 10 == 9 and state["stage"] == "requested": await request()
        await c.sync(timeout=2000)
        if c.outgoing_to_device_messages: await c.send_to_device_messages()   # e.g. nio's own cancels reach the app
        if state["stage"] in ("done", "cancelled", "error"): break
    await c.close()

asyncio.run(main())
