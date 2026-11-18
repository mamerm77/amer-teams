"""Phone network (SIP/PSTN) via LiveKit SIP.

Security model
- Ordinary phones cannot do end-to-end encryption. Phone calls are therefore a SEPARATE call type in their
  own LiveKit room (never mixed into an end-to-end encrypted meeting). Media is encrypted app<->server
  (DTLS-SRTP) and server<->carrier (SIP over TLS + SRTP, enforced on every trunk), and the app labels them.
- Off by default; an admin enables it and sets which number prefixes may be dialled (e.g. +971).
- Premium-rate and short codes are always refused. Every dial is audited (number masked).
"""
import re, secrets, time
from fastapi import APIRouter, Depends, HTTPException
from livekit import api as lkapi
from pydantic import BaseModel, Field
from . import auth, config, db, livekit_token
from .admin import require_admin

router = APIRouter(prefix="/v1/phone")
E164 = re.compile(r"^\+[1-9]\d{6,14}$")
BLOCKED = ("+9719", "+1900", "+44909", "+4490", "+88")   # premium / satellite ranges always refused

def _lk():
    return lkapi.LiveKitAPI(config.LIVEKIT_HTTP_URL, config.LIVEKIT_API_KEY, config.LIVEKIT_API_SECRET)

async def _settings():
    async with db.pool.connection() as c:
        row = await (await c.execute("SELECT enabled, allowed_prefixes, outbound_trunk_id FROM phone_settings WHERE id = 1")).fetchone()
    return {"enabled": row[0], "allowed_prefixes": row[1], "outbound_trunk_id": row[2]} if row else {"enabled": False, "allowed_prefixes": [], "outbound_trunk_id": None}

def mask(n: str) -> str: return n[:4] + "•" * max(0, len(n) - 6) + n[-2:]

def check_number(number: str, s: dict) -> str:
    n = re.sub(r"[\s\-()]", "", number)
    if not E164.match(n): raise HTTPException(400, "Use international format, for example +971501234567")
    if n.startswith(BLOCKED): raise HTTPException(403, "Premium-rate and satellite numbers are blocked")
    if not any(n.startswith(p) for p in s["allowed_prefixes"]):
        raise HTTPException(403, f"Calls to this destination are not allowed. Allowed: {', '.join(s['allowed_prefixes']) or 'none'}")
    return n

# ---------------- admin: trunks and policy ----------------
class TrunkReq(BaseModel):
    name: str
    address: str = Field(..., description="Carrier SIP address, e.g. sip.carrier.ae:5061")
    numbers: list[str] = Field(..., min_length=1, description="Your DIDs on this trunk, E.164")
    auth_username: str = ""
    auth_password: str = ""
    allowed_inbound_addresses: list[str] = Field(default_factory=list, description="Carrier IP ranges allowed to send calls")

@router.post("/trunks")
async def create_trunks(req: TrunkReq, user=Depends(require_admin)):
    for n in req.numbers:
        if not E164.match(n): raise HTTPException(400, f"{n} is not an E.164 number")
    async with _lk() as lk:
        out = await lk.sip.create_sip_outbound_trunk(lkapi.CreateSIPOutboundTrunkRequest(trunk=lkapi.SIPOutboundTrunkInfo(
            name=f"{req.name} (out)", address=req.address, numbers=req.numbers,
            transport=lkapi.SIPTransport.SIP_TRANSPORT_TLS, media_encryption=lkapi.SIPMediaEncryption.SIP_MEDIA_ENCRYPT_REQUIRE,
            auth_username=req.auth_username, auth_password=req.auth_password)))
        inn = await lk.sip.create_sip_inbound_trunk(lkapi.CreateSIPInboundTrunkRequest(trunk=lkapi.SIPInboundTrunkInfo(
            name=f"{req.name} (in)", numbers=req.numbers, allowed_addresses=req.allowed_inbound_addresses,
            media_encryption=lkapi.SIPMediaEncryption.SIP_MEDIA_ENCRYPT_REQUIRE,
            auth_username=req.auth_username, auth_password=req.auth_password)))
        rule = await lk.sip.create_sip_dispatch_rule(lkapi.CreateSIPDispatchRuleRequest(
            trunk_ids=[inn.sip_trunk_id], name=f"{req.name} inbound",
            rule=lkapi.SIPDispatchRule(dispatch_rule_individual=lkapi.SIPDispatchRuleIndividual(room_prefix="phone-in-"))))
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO phone_settings (id, outbound_trunk_id) VALUES (1, %s) ON CONFLICT (id) DO UPDATE SET outbound_trunk_id = EXCLUDED.outbound_trunk_id", (out.sip_trunk_id,))
    await db.audit(user["user_id"], "phone.trunk.create", f"{req.name} {req.address}")
    return {"outbound_trunk_id": out.sip_trunk_id, "inbound_trunk_id": inn.sip_trunk_id, "dispatch_rule_id": rule.sip_dispatch_rule_id}

@router.get("/trunks")
async def list_trunks(user=Depends(require_admin)):
    async with _lk() as lk:
        o = (await lk.sip.list_sip_outbound_trunk(lkapi.ListSIPOutboundTrunkRequest())).items
        i = (await lk.sip.list_sip_inbound_trunk(lkapi.ListSIPInboundTrunkRequest())).items
        r = (await lk.sip.list_sip_dispatch_rule(lkapi.ListSIPDispatchRuleRequest())).items
    enc = lambda t: lkapi.SIPMediaEncryption.Name(t.media_encryption)
    return {"outbound": [{"id": t.sip_trunk_id, "name": t.name, "address": t.address, "numbers": list(t.numbers), "media_encryption": enc(t),
                          "transport": lkapi.SIPTransport.Name(t.transport)} for t in o],
            "inbound": [{"id": t.sip_trunk_id, "name": t.name, "numbers": list(t.numbers), "media_encryption": enc(t)} for t in i],
            "dispatch_rules": [{"id": x.sip_dispatch_rule_id, "name": x.name, "trunks": list(x.trunk_ids)} for x in r]}

@router.delete("/trunks/{trunk_id}")
async def delete_trunk(trunk_id: str, user=Depends(require_admin)):
    async with _lk() as lk:
        await lk.sip.delete_sip_trunk(lkapi.DeleteSIPTrunkRequest(sip_trunk_id=trunk_id))
    async with db.pool.connection() as c:     # forget it as the outbound line if it was one
        await c.execute("UPDATE phone_settings SET outbound_trunk_id = NULL WHERE outbound_trunk_id = %s", (trunk_id,))
    await db.audit(user["user_id"], "phone.trunk.delete", trunk_id)
    return {"ok": True}

class PolicyReq(BaseModel):
    enabled: bool
    allowed_prefixes: list[str] = Field(default_factory=lambda: ["+971"])

@router.put("/policy")
async def set_policy(req: PolicyReq, user=Depends(require_admin)):
    for p in req.allowed_prefixes:
        if not re.match(r"^\+\d{1,6}$", p): raise HTTPException(400, f"{p} is not a valid prefix like +971")
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO phone_settings (id, enabled, allowed_prefixes) VALUES (1, %s, %s) "
                        "ON CONFLICT (id) DO UPDATE SET enabled = EXCLUDED.enabled, allowed_prefixes = EXCLUDED.allowed_prefixes", (req.enabled, req.allowed_prefixes))
    await db.audit(user["user_id"], "phone.policy", f"enabled={req.enabled} prefixes={','.join(req.allowed_prefixes)}")
    return {"ok": True}

@router.get("/policy")
async def get_policy(user=Depends(auth.matrix_user)):
    s = await _settings(); return {"enabled": s["enabled"], "allowed_prefixes": s["allowed_prefixes"], "trunk_configured": bool(s["outbound_trunk_id"])}

# ---------------- users: dial out ----------------
class DialReq(BaseModel):
    number: str
    display_name: str = ""

@router.post("/dial")
async def dial(req: DialReq, user=Depends(auth.matrix_user)):
    s = await _settings()
    if not s["enabled"]: raise HTTPException(403, "Phone calls are switched off by your administrator")
    if not s["outbound_trunk_id"]: raise HTTPException(503, "No phone line (SIP trunk) is configured yet")
    n = check_number(req.number, s)
    room = f"phone-out-{secrets.token_hex(6)}"
    try:
        async with _lk() as lk:
            p = await lk.sip.create_sip_participant(lkapi.CreateSIPParticipantRequest(
                sip_trunk_id=s["outbound_trunk_id"], sip_call_to=n, room_name=room,
                participant_identity=f"phone:{mask(n)}", participant_name=req.display_name or mask(n), play_dialtone=True))
    except Exception as e:
        await db.audit(user["user_id"], "phone.dial.failed", f"{mask(n)} {type(e).__name__}")
        raise HTTPException(502, f"The phone gateway could not place the call ({type(e).__name__}). Check that the SIP service is running.")
    await db.audit(user["user_id"], "phone.dial", mask(n))
    token = livekit_token.sign(user["user_id"], user["user_id"], room)
    return {"url": config.LIVEKIT_PUBLIC_URL, "token": token, "livekit_room": room, "sip_call_id": p.sip_call_id,
            "e2ee": "not-possible", "security": "Encrypted to the phone network (TLS + SRTP), not end-to-end"}
