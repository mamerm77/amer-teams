"""People, contacts and invitations (Microsoft Teams parity; docs/PEOPLE.md).

- Directory search by name, username, email or phone, across everyone on this server.
- Your contact details (email, phone, job title, department, office), shown on your profile card.
- Contacts and contact groups (like Teams' Calls > Contacts), private to you.
- Invite someone who has no account yet, by email or phone: a one-time sign-up link (emailed when SMTP is set,
  otherwise shown to you to share). When they sign up, your app adds them to the teams and chats you chose and to
  your contacts.
"""
from __future__ import annotations
import hashlib, json, os, re, secrets, urllib.parse
import httpx
from fastapi import APIRouter, Depends, HTTPException
from fastapi.responses import FileResponse
from pydantic import BaseModel, Field
from . import auth, config, db
from .admin import _syn, mxid

router = APIRouter(prefix="/v1/people")
public = APIRouter()
EMAIL = re.compile(r"^[^@\s]+@[^@\s]+\.[^@\s]+$")
PHONE = re.compile(r"^\+?[0-9 ()-]{7,20}$")
INVITE_DAYS = int(os.getenv("PEOPLE_INVITE_DAYS", "14"))

def _phone(p: str | None) -> str | None:
    if not p: return None
    d = re.sub(r"[^0-9+]", "", p)
    return d if PHONE.match(p.strip()) else None

def _need():
    if db.pool is None: raise HTTPException(503, "People needs the database")

async def _profiles(ids: list[str]) -> dict[str, dict]:
    if not ids: return {}
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, email, phone, title, dept, office, manager FROM people_profile WHERE user_id = ANY(%s)", (ids,))).fetchall()
    return {r[0]: dict(zip(("email", "phone", "title", "dept", "office", "manager"), r[1:])) for r in rows}

async def _directory() -> list[dict]:
    j = await _syn("GET", "/_synapse/admin/v2/users?limit=1000&guests=false&deactivated=false")
    return [{"user_id": u["name"], "display_name": u.get("displayname") or u["name"]} for u in j["users"]
            if not u["name"].startswith(("@guest-", "@voicemail", "@amer-"))]

# ---------- directory ----------
@router.get("/search")
async def search(q: str = "", limit: int = 30, user=Depends(auth.matrix_user)):
    """Everyone on this server matching the name, username, email or phone (prefix or contained)."""
    _need(); s = q.strip().lower(); digits = re.sub(r"[^0-9]", "", s)
    people = await _directory(); prof = await _profiles([p["user_id"] for p in people])
    out = []
    for p in people:
        if p["user_id"] == user["user_id"]: continue
        pr = prof.get(p["user_id"], {})
        hay = " ".join(x for x in (p["display_name"], p["user_id"], pr.get("email"), pr.get("title"), pr.get("dept")) if x).lower()
        ph = re.sub(r"[^0-9]", "", pr.get("phone") or "")
        if not s or s in hay or (len(digits) >= 4 and digits in ph):
            out.append({**p, **{k: v for k, v in pr.items() if v}})
    out.sort(key=lambda p: (not p["display_name"].lower().startswith(s), p["display_name"].lower()))
    return {"results": out[:max(1, min(limit, 100))], "can_invite": bool(EMAIL.match(q.strip()) or _phone(q))}

@router.get("/org/{uid}")
async def org(uid: str, user=Depends(auth.matrix_user)):
    """Org chart around a person: managers up the chain (from contact cards), the person, and direct reports."""
    _need()
    names = {p["user_id"]: p["display_name"] for p in await _directory()}
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, title, manager FROM people_profile")).fetchall()
    card = {u: (t, m) for u, t, m in rows}
    chain, cur = [], uid
    for _ in range(10):
        m = card.get(cur, (None, None))[1]
        if not m or m in chain or m == uid: break
        chain.insert(0, m); cur = m
    who = lambda u: {"user_id": u, "display_name": names.get(u, u), "title": card.get(u, (None, None))[0]}
    return {"managers": [who(u) for u in chain], "person": who(uid), "reports": [who(u) for u, (_, m) in card.items() if m == uid]}

@router.get("/profile/{uid}")
async def profile(uid: str, user=Depends(auth.matrix_user)):
    _need(); return {"user_id": uid, **(await _profiles([uid])).get(uid, {})}

class Me(BaseModel):
    email: str | None = Field(default=None, max_length=200); phone: str | None = Field(default=None, max_length=30)
    title: str | None = Field(default=None, max_length=100); dept: str | None = Field(default=None, max_length=100); office: str | None = Field(default=None, max_length=100)
    manager: str | None = Field(default=None, max_length=200)

@router.put("/me")
async def set_me(req: Me, user=Depends(auth.matrix_user)):
    _need()
    if req.email and not EMAIL.match(req.email): raise HTTPException(422, "That email address does not look right")
    if req.phone and not _phone(req.phone): raise HTTPException(422, "Phone numbers need 7 to 20 digits, e.g. +971 50 123 4567")
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO people_profile (user_id, email, phone, title, dept, office, manager) VALUES (%s,%s,%s,%s,%s,%s,%s) ON CONFLICT (user_id) DO UPDATE SET "
                        "email=EXCLUDED.email, phone=EXCLUDED.phone, title=EXCLUDED.title, dept=EXCLUDED.dept, office=EXCLUDED.office, manager=EXCLUDED.manager, updated_at=now()",
                        (user["user_id"], (req.email or "").strip().lower() or None, _phone(req.phone), req.title, req.dept, req.office, req.manager if req.manager != user["user_id"] else None))
    return {"ok": True}

# ---------- contacts and groups ----------
@router.get("/contacts")
async def contacts(user=Depends(auth.matrix_user)):
    _need(); me = user["user_id"]
    async with db.pool.connection() as c:
        cs = await (await c.execute("SELECT user_id, favourite, note FROM contacts WHERE owner=%s", (me,))).fetchall()
        gs = await (await c.execute("SELECT name, members FROM contact_groups WHERE owner=%s ORDER BY name", (me,))).fetchall()
    names = {p["user_id"]: p["display_name"] for p in await _directory()}
    prof = await _profiles([u for u, _, _ in cs])
    out = [{"user_id": u, "display_name": names.get(u, u), "favourite": f, "note": n, **{k: v for k, v in prof.get(u, {}).items() if v}} for u, f, n in cs]
    out.sort(key=lambda x: (not x["favourite"], x["display_name"].lower()))
    return {"contacts": out, "groups": [{"name": n, "members": m} for n, m in gs]}

class Contact(BaseModel): user_id: str; favourite: bool = False; note: str = Field(default="", max_length=300)

@router.put("/contacts")
async def add_contact(req: Contact, user=Depends(auth.matrix_user)):
    _need()
    if req.user_id == user["user_id"]: raise HTTPException(422, "You are always in your own contacts")
    if req.user_id not in {p["user_id"] for p in await _directory()}: raise HTTPException(404, "No such person on this server")
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO contacts (owner, user_id, favourite, note) VALUES (%s,%s,%s,%s) ON CONFLICT (owner, user_id) DO UPDATE SET favourite=EXCLUDED.favourite, note=EXCLUDED.note",
                        (user["user_id"], req.user_id, req.favourite, req.note))
    return {"ok": True}

@router.delete("/contacts/{uid}")
async def remove_contact(uid: str, user=Depends(auth.matrix_user)):
    _need()
    async with db.pool.connection() as c:
        await c.execute("DELETE FROM contacts WHERE owner=%s AND user_id=%s", (user["user_id"], uid))
        for name, members in await (await c.execute("SELECT name, members FROM contact_groups WHERE owner=%s", (user["user_id"],))).fetchall():
            if uid in members: await c.execute("UPDATE contact_groups SET members=%s WHERE owner=%s AND name=%s", (json.dumps([m for m in members if m != uid]), user["user_id"], name))
    return {"ok": True}

class Group(BaseModel): name: str = Field(min_length=1, max_length=60); members: list[str] = []

@router.put("/groups")
async def set_group(req: Group, user=Depends(auth.matrix_user)):
    _need(); me = user["user_id"]
    known = {p["user_id"] for p in await _directory()}
    members = list(dict.fromkeys(m for m in req.members if m in known and m != me))
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO contact_groups (owner, name, members) VALUES (%s,%s,%s) ON CONFLICT (owner, name) DO UPDATE SET members=EXCLUDED.members", (me, req.name.strip(), json.dumps(members)))
        for m in members:   # people in a group are also contacts
            await c.execute("INSERT INTO contacts (owner, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (me, m))
    return {"ok": True, "members": members}

@router.delete("/groups/{name}")
async def delete_group(name: str, user=Depends(auth.matrix_user)):
    _need()
    async with db.pool.connection() as c: await c.execute("DELETE FROM contact_groups WHERE owner=%s AND name=%s", (user["user_id"], name))
    return {"ok": True}

# ---------- invite people who have no account yet ----------
class Invite(BaseModel):
    name: str = Field(min_length=1, max_length=100); email: str | None = None; phone: str | None = None
    rooms: list[str] = []      # teams or chats to add them to (you must be a member)

def _base() -> str: return os.getenv("PUBLIC_BASE_URL", f"https://{config.SERVER_NAME}").rstrip("/")

async def _mail(to: str, subject: str, body: str) -> bool:
    host = os.getenv("SMTP_HOST")
    if not host: return False
    import smtplib, ssl, asyncio
    from email.message import EmailMessage
    m = EmailMessage(); m["From"] = os.getenv("SMTP_FROM", f"Amer Teams <no-reply@{config.SERVER_NAME}>"); m["To"] = to; m["Subject"] = subject; m.set_content(body)
    def send():
        with smtplib.SMTP(host, int(os.getenv("SMTP_PORT", "587")), timeout=15) as s:
            s.starttls(context=ssl.create_default_context())
            if os.getenv("SMTP_USER"): s.login(os.environ["SMTP_USER"], os.getenv("SMTP_PASSWORD", ""))
            s.send_message(m)
    try: await asyncio.to_thread(send); return True
    except Exception: return False

@router.post("/invite")
async def invite(req: Invite, user=Depends(auth.matrix_user)):
    _need(); me = user["user_id"]
    if os.getenv("PEOPLE_INVITE", "members") == "admins":
        from .admin import require_admin; await require_admin(user)
    email = (req.email or "").strip().lower() or None; phone = _phone(req.phone)
    if not email and not phone: raise HTTPException(422, "Give an email address or a phone number")
    if email and not EMAIL.match(email): raise HTTPException(422, "That email address does not look right")
    async with db.pool.connection() as c:
        if email and await (await c.execute("SELECT 1 FROM people_profile WHERE lower(email)=%s", (email,))).fetchone():
            raise HTTPException(409, "Someone with that email already has an account: search for them instead")
        n = (await (await c.execute("SELECT count(*) FROM people_invites WHERE inviter=%s AND created_at > now() - interval '1 day'", (me,))).fetchone())[0]
        if n >= 50: raise HTTPException(429, "You have sent 50 invitations today")
    for r in req.rooms: await auth.assert_room_member(user, r)
    token = secrets.token_urlsafe(24)
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO people_invites (token_hash, inviter, name, email, phone, rooms, expires_at) VALUES (%s,%s,%s,%s,%s,%s, now() + make_interval(days => %s))",
                        (hashlib.sha256(token.encode()).hexdigest(), me, req.name.strip(), email, phone, json.dumps(req.rooms), INVITE_DAYS))
    await db.audit(me, "people.invite", email or (phone[:4] + "…"))
    link = f"{_base()}/welcome#{token}"
    mailed = await _mail(email, f"{me.split(':')[0].lstrip('@')} invited you to Amer Teams",
                         f"Hello {req.name},\n\nYou have been invited to Amer Teams, an end-to-end encrypted workspace.\nCreate your account here (valid {INVITE_DAYS} days, one use):\n{link}\n") if email else False
    return {"link": link, "emailed": mailed, "expires_in_days": INVITE_DAYS,
            "message": f"Hello {req.name}, I'd like you to join me on Amer Teams. Create your account here: {link}"}

@router.get("/invites")
async def my_invites(user=Depends(auth.matrix_user)):
    """Invitations you sent; claimed ones tell your app who to add to which teams and chats."""
    _need()
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT token_hash, name, email, phone, rooms, extract(epoch from created_at)::bigint, expires_at < now(), claimed_by, added FROM people_invites "
                                      "WHERE inviter=%s ORDER BY created_at DESC LIMIT 100", (user["user_id"],))).fetchall()
    return [{"id": t[:16], "name": n, "email": e, "phone": p, "rooms": r, "created_at": ca, "status": "joined" if cb else ("expired" if ex else "pending"),
             "user_id": cb, "added": a} for t, n, e, p, r, ca, ex, cb, a in rows]

@router.post("/invites/{iid}/added")
async def mark_added(iid: str, user=Depends(auth.matrix_user)):
    _need()
    async with db.pool.connection() as c:
        await c.execute("UPDATE people_invites SET added=true WHERE inviter=%s AND token_hash LIKE %s AND claimed_by IS NOT NULL", (user["user_id"], iid + "%"))
        r = await (await c.execute("SELECT claimed_by FROM people_invites WHERE inviter=%s AND token_hash LIKE %s", (user["user_id"], iid + "%"))).fetchone()
        if r and r[0]: await c.execute("INSERT INTO contacts (owner, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (user["user_id"], r[0]))
    return {"ok": True}

@router.delete("/invites/{iid}")
async def cancel_invite(iid: str, user=Depends(auth.matrix_user)):
    _need()
    async with db.pool.connection() as c:
        await c.execute("DELETE FROM people_invites WHERE inviter=%s AND token_hash LIKE %s AND claimed_by IS NULL", (user["user_id"], iid + "%"))
    return {"ok": True}

# ---------- the invited person creates an account (public, no sign-in) ----------
async def _invite_by(token: str):
    async with db.pool.connection() as c:
        return await (await c.execute("SELECT token_hash, inviter, name, email, phone, claimed_by, expires_at < now() FROM people_invites WHERE token_hash=%s",
                                      (hashlib.sha256(token.encode()).hexdigest(),))).fetchone()

@public.get("/welcome")
async def welcome_page(): return FileResponse(os.path.join(os.path.dirname(__file__), "static", "welcome.html"))

@public.get("/v1/welcome/{token}")
async def welcome_info(token: str):
    r = await _invite_by(token)
    if not r or r[5] or r[6]: raise HTTPException(404, "This invitation was already used, has expired or was cancelled")
    return {"name": r[2], "invited_by": r[1], "server": config.SERVER_NAME, "suggested_username": re.sub(r"[^a-z0-9._-]", "", (r[3] or r[2]).split("@")[0].lower().replace(" ", "."))[:30]}

class Claim(BaseModel): username: str; password: str = Field(min_length=10, max_length=200); display_name: str = Field(default="", max_length=100)

@public.post("/v1/welcome/{token}")
async def claim(token: str, req: Claim):
    r = await _invite_by(token)
    if not r or r[5] or r[6]: raise HTTPException(404, "This invitation was already used, has expired or was cancelled")
    if not (re.search(r"[A-Za-z]", req.password) and re.search(r"[0-9]", req.password)): raise HTTPException(422, "Use at least 10 characters with letters and numbers")
    uid = mxid(req.username)
    async with httpx.AsyncClient(timeout=10) as c:
        if (await c.get(f"{config.SYNAPSE_URL}/_synapse/admin/v2/users/{urllib.parse.quote(uid)}", headers={"Authorization": f"Bearer {config.SYNAPSE_ADMIN_TOKEN}"})).status_code == 200:
            raise HTTPException(409, "That username is taken: choose another")
    async with db.pool.connection() as c:   # claim first, so one link makes one account even if used twice at once
        ok = await (await c.execute("UPDATE people_invites SET claimed_by=%s, claimed_at=now() WHERE token_hash=%s AND claimed_by IS NULL RETURNING inviter", (uid, r[0]))).fetchone()
    if not ok: raise HTTPException(409, "This invitation was just used")
    await _syn("PUT", f"/_synapse/admin/v2/users/{urllib.parse.quote(uid)}", json={"password": req.password, "displayname": req.display_name.strip() or r[2], "admin": False})
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO people_profile (user_id, email, phone) VALUES (%s,%s,%s) ON CONFLICT (user_id) DO NOTHING", (uid, r[3], r[4]))
        await c.execute("INSERT INTO contacts (owner, user_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (uid, r[1]))
    await db.audit(uid, "people.invite.claimed", r[1])
    return {"user_id": uid, "server": config.SERVER_NAME, "invited_by": r[1]}
