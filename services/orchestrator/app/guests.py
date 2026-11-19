"""Browser join for guests, and webinars with registration (docs/GUESTS.md, docs/WEBINARS.md).

A guest has no Amer Teams account. A host makes a guest link (or a webinar registration gives one); the guest opens
/join in any modern browser, types a name and gets a media token with an identity starting "guest-". Media stays
end-to-end encrypted: the server never has the call key. The guest's page makes a one-time X25519 key pair and
sends its public key over the meeting's data channel; a host's app admits the guest and sends the call key wrapped
to that public key. Until a host admits them, the guest is in the meeting's lobby and can see and hear nothing.
Webinar guests join as attendees: they cannot publish audio or video (enforced in the token), only ask questions.
"""
from __future__ import annotations
import hashlib, pathlib, re, secrets, time
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from . import auth, config, db, livekit_token
from .meetings import power_level, HOST_LEVEL

router = APIRouter()
STATIC = pathlib.Path(__file__).parent / "static"
_h = lambda c: hashlib.sha256(c.encode()).hexdigest()
_mem: dict[str, dict] = {"links": {}, "webinars": {}, "regs": {}}

async def _host(user, room_id):
    await auth.assert_room_member(user, room_id)
    if await power_level(user, room_id) < HOST_LEVEL: raise HTTPException(403, "Only a meeting host can do this")

# ---------- guest links ----------
class LinkReq(BaseModel):
    room_id: str
    call_id: str
    hours: int = Field(default=24, ge=1, le=24 * 30)
    attendee: bool = False

@router.post("/v1/guests/links")
async def make_link(req: LinkReq, user=Depends(auth.matrix_user)):
    await _host(user, req.room_id)
    code = secrets.token_urlsafe(18); exp = time.time() + req.hours * 3600
    await _put_link(code, req.room_id, req.call_id, user["user_id"], req.attendee, "", exp)
    await db.audit(user["user_id"], "guest.link", f"{req.room_id}|{req.call_id}|{req.hours}h")
    return {"code": code, "path": f"/join#{code}", "expires_at": int(exp)}

async def _put_link(code, room_id, call_id, by, attendee, name, exp, max_uses=50):
    if db.pool is None:
        _mem["links"][_h(code)] = dict(room_id=room_id, call_id=call_id, attendee=attendee, name=name, expires_at=exp, uses=0, max_uses=max_uses); return
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO guest_links (code_hash, room_id, call_id, created_by, attendee, name, expires_at, max_uses) VALUES (%s,%s,%s,%s,%s,%s,to_timestamp(%s),%s)",
                        (_h(code), room_id, call_id, by, attendee, name, exp, max_uses))

async def _use_link(code):
    if db.pool is None:
        l = _mem["links"].get(_h(code))
        if not l or l["expires_at"] < time.time() or l["uses"] >= l["max_uses"]: return None
        l["uses"] += 1; return l
    async with db.pool.connection() as c:
        r = await (await c.execute("UPDATE guest_links SET uses = uses + 1 WHERE code_hash=%s AND expires_at > now() AND uses < max_uses "
                                   "RETURNING room_id, call_id, attendee, name", (_h(code),))).fetchone()
    return dict(zip(("room_id", "call_id", "attendee", "name"), r)) if r else None

class JoinReq(BaseModel):
    code: str = Field(min_length=10, max_length=100)
    name: str = Field(min_length=1, max_length=60)

@router.post("/v1/guests/join")
async def guest_join(req: JoinReq):
    l = await _use_link(req.code)
    if not l: raise HTTPException(403, "This link has expired or is not valid")
    name = re.sub(r"[\x00-\x1f<>]", "", (l.get("name") or req.name)).strip()[:60] or "Guest"
    ident = f"guest-{secrets.token_hex(6)}"
    tok = livekit_token.sign(ident, f"{name} (guest)", livekit_token.room_name(l["room_id"], l["call_id"]), can_publish=not l["attendee"])
    await db.audit(ident, "guest.join", f"{l['room_id']}|{l['call_id']}|{name}")
    return {"token": tok, "url": config.LIVEKIT_PUBLIC_URL, "identity": ident, "attendee": l["attendee"]}

@router.get("/join")
async def join_page(): return FileResponse(STATIC / "join.html", media_type="text/html")
@router.get("/join/{asset}")
async def join_asset(asset: str):
    if asset not in ("livekit-client.umd.js", "livekit-client.e2ee.worker.js", "join.js"): raise HTTPException(404)
    return FileResponse(STATIC / asset, media_type="text/javascript")

# ---------- webinars with registration ----------
class Webinar(BaseModel):
    room_id: str
    call_id: str
    title: str = Field(min_length=1, max_length=120)
    starts_at: int | None = None
    capacity: int = Field(default=500, ge=1, le=10000)

@router.post("/v1/webinars")
async def create_webinar(req: Webinar, user=Depends(auth.matrix_user)):
    await _host(user, req.room_id)
    slug = secrets.token_urlsafe(8)
    w = dict(slug=slug, room_id=req.room_id, call_id=req.call_id, title=req.title, starts_at=req.starts_at, open=True, capacity=req.capacity)
    if db.pool is None: _mem["webinars"][slug] = w
    else:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO webinars (slug, room_id, call_id, title, starts_at, created_by, capacity) VALUES (%s,%s,%s,%s,to_timestamp(%s),%s,%s)",
                            (slug, req.room_id, req.call_id, req.title, req.starts_at, user["user_id"], req.capacity))
    await db.audit(user["user_id"], "webinar.create", f"{req.room_id}|{slug}")
    return {"slug": slug, "path": f"/join?w={slug}"}

async def _webinar(slug):
    if db.pool is None: return _mem["webinars"].get(slug)
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT slug, room_id, call_id, title, extract(epoch from starts_at)::bigint, open, capacity FROM webinars WHERE slug=%s", (slug,))).fetchone()
    return dict(zip(("slug", "room_id", "call_id", "title", "starts_at", "open", "capacity"), r)) if r else None

async def _regs(slug):
    if db.pool is None: return [r for r in _mem["regs"].values() if r["slug"] == slug]
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT email, name, extract(epoch from registered_at)::bigint, extract(epoch from joined_at)::bigint FROM webinar_registrations WHERE slug=%s ORDER BY registered_at", (slug,))).fetchall()
    return [dict(zip(("email", "name", "registered_at", "joined_at"), r)) for r in rows]

@router.get("/v1/webinars/public/{slug}")
async def webinar_info(slug: str):
    w = await _webinar(slug)
    if not w: raise HTTPException(404, "No such webinar")
    return {"title": w["title"], "starts_at": w["starts_at"], "open": w["open"] and len(await _regs(slug)) < w["capacity"]}

class Registration(BaseModel):
    name: str = Field(min_length=1, max_length=60)
    email: str = Field(pattern=r"^[^@\s]{1,64}@[^@\s]{1,190}\.[A-Za-z]{2,}$")

@router.post("/v1/webinars/public/{slug}/register")
async def register(slug: str, req: Registration):
    """Registration gives a personal join code (one person, ten uses). Sending it by email needs a mail connector."""
    w = await _webinar(slug)
    if not w or not w["open"]: raise HTTPException(404, "Registration is closed")
    regs = await _regs(slug); email = req.email.lower()
    if len(regs) >= w["capacity"] and all(r["email"] != email for r in regs): raise HTTPException(409, "This webinar is full")
    code = secrets.token_urlsafe(18)
    if db.pool is None: _mem["regs"][(slug, email)] = dict(slug=slug, email=email, name=req.name, registered_at=int(time.time()), joined_at=None)
    else:
        async with db.pool.connection() as c:
            await c.execute("INSERT INTO webinar_registrations (slug, email, name, code_hash) VALUES (%s,%s,%s,%s) ON CONFLICT (slug, email) DO UPDATE SET name=EXCLUDED.name, code_hash=EXCLUDED.code_hash",
                            (slug, email, req.name, _h(code)))
    exp = (w["starts_at"] or time.time()) + 2 * 86400
    await _put_link(code, w["room_id"], w["call_id"], f"webinar:{slug}", True, req.name, max(exp, time.time() + 3600), max_uses=10)
    await db.audit(f"webinar:{slug}", "webinar.register", email.split("@")[-1])        # domain only, not the address
    return {"code": code, "path": f"/join#{code}", "title": w["title"], "starts_at": w["starts_at"]}

@router.get("/v1/webinars/{slug}/registrations")
async def registrations(slug: str, user=Depends(auth.matrix_user)):
    w = await _webinar(slug)
    if not w: raise HTTPException(404, "No such webinar")
    await _host(user, w["room_id"])
    return {"title": w["title"], "registrations": await _regs(slug)}

@router.post("/v1/webinars/{slug}/close")
async def close(slug: str, user=Depends(auth.matrix_user)):
    w = await _webinar(slug)
    if not w: raise HTTPException(404, "No such webinar")
    await _host(user, w["room_id"])
    if db.pool is None: w["open"] = False
    else:
        async with db.pool.connection() as c: await c.execute("UPDATE webinars SET open=false WHERE slug=%s", (slug,))
    return {"open": False}
