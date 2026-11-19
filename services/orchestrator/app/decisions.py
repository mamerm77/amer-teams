"""Decision ledger (docs/DECISIONS.md).

A decision's text lives only in the chat, end-to-end encrypted. The server keeps a tamper-evident ledger of
metadata: who owns it, when it is due, its status, its version, who confirmed it, and a hash of the text.

Quorum is checked here, not claimed by a client: each participant confirms with their own sign-in, presenting
the hash of the text they saw. Only when the owner and at least one other member have confirmed the same text
hash within 72 hours of the proposal does the decision enter the ledger. A change is a new version that
supersedes the old one; the old one stays visible. Every ledger entry is chained to the previous one by SHA-256,
so altering any stored row makes verification fail.
"""
from __future__ import annotations
import hashlib, json, time
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db
from .admin import require_admin

from . import flags
router = APIRouter(dependencies=[Depends(flags.require("decisions"))])
QUORUM_OTHERS = 1                       # the owner plus at least this many other members
PROPOSAL_TTL_S = 72 * 3600
STATUSES = {"confirmed", "in_progress", "done", "cancelled", "superseded"}

def room_hash(room_id: str) -> str: return hashlib.sha256(f"amer-room|{room_id}".encode()).hexdigest()
def entry_hash(prev: str, e: dict) -> str:
    keys = ("decision_id", "version", "kind", "room_hash", "event_id", "owner", "due", "status", "text_hash", "confirmed_by", "supersedes", "at")
    return hashlib.sha256((prev + "|" + json.dumps({k: e.get(k) for k in keys}, sort_keys=True)).encode()).hexdigest()

# ---------------- storage ----------------
class Mem:
    def __init__(self): self.pending: dict[tuple, dict] = {}; self.ledger: list[dict] = []
    async def pend(self, key, rec): self.pending.setdefault(key, rec)
    async def get_pend(self, key): return self.pending.get(key)
    async def confirm(self, key, user): p = self.pending[key]; p["confirmed_by"] = sorted(set(p["confirmed_by"]) | {user}); return p
    async def drop_pend(self, key): self.pending.pop(key, None)
    async def append(self, e):
        prev = self.ledger[-1]["hash"] if self.ledger else "0" * 64
        e = {**e, "prev_hash": prev}; e["hash"] = entry_hash(prev, e); e["seq"] = len(self.ledger) + 1; self.ledger.append(e); return e
    async def entries(self, decision_id=None): return [e for e in self.ledger if decision_id is None or e["decision_id"] == decision_id]

def _norm(r):
    """Database values back to the exact form they were hashed in (dates as YYYY-MM-DD, arrays as lists)."""
    if r is None: return None
    r = dict(r)
    if r.get("due") is not None and not isinstance(r["due"], str): r["due"] = r["due"].isoformat()
    if r.get("confirmed_by") is not None: r["confirmed_by"] = list(r["confirmed_by"])
    return r

class Pg(Mem):
    async def _q(self, sql, *a, one=False):
        async with db.pool.connection() as c:
            cur = await c.execute(sql, a)
            if cur.description is None: return None
            cols = [d.name for d in cur.description]; rows = [_norm(dict(zip(cols, r))) for r in await cur.fetchall()]
            return (rows[0] if rows else None) if one else rows
    async def pend(self, key, rec):
        await self._q("INSERT INTO decision_pending (decision_id, version, room_hash, event_id, owner, due, text_hash, supersedes, proposed_at, confirmed_by) "
                      "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING", *key, rec["room_hash"], rec["event_id"], rec["owner"], rec["due"],
                      rec["text_hash"], rec["supersedes"], rec["proposed_at"], rec["confirmed_by"])
    async def get_pend(self, key): return await self._q("SELECT * FROM decision_pending WHERE decision_id=%s AND version=%s", *key, one=True)
    async def confirm(self, key, user):
        return await self._q("UPDATE decision_pending SET confirmed_by = (SELECT array_agg(DISTINCT x ORDER BY x) FROM unnest(confirmed_by || ARRAY[%s]) x) "
                             "WHERE decision_id=%s AND version=%s RETURNING *", user, *key, one=True)
    async def drop_pend(self, key): await self._q("DELETE FROM decision_pending WHERE decision_id=%s AND version=%s", *key)
    async def append(self, e):
        async with db.pool.connection() as c:
            async with c.transaction():
                await c.execute("LOCK TABLE decision_ledger IN EXCLUSIVE MODE")
                row = await (await c.execute("SELECT hash FROM decision_ledger ORDER BY seq DESC LIMIT 1")).fetchone()
                prev = row[0] if row else "0" * 64
                e = {**e, "prev_hash": prev}; e["hash"] = entry_hash(prev, e)
                r = await (await c.execute(
                    "INSERT INTO decision_ledger (decision_id, version, kind, room_hash, event_id, owner, due, status, text_hash, confirmed_by, supersedes, at, prev_hash, hash) "
                    "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) RETURNING seq",
                    (e["decision_id"], e["version"], e["kind"], e["room_hash"], e["event_id"], e["owner"], e["due"], e["status"], e["text_hash"],
                     e["confirmed_by"], e["supersedes"], e["at"], prev, e["hash"]))).fetchone()
        e["seq"] = r[0]; return e
    async def entries(self, decision_id=None):
        rows = await (self._q("SELECT * FROM decision_ledger WHERE decision_id=%s ORDER BY seq", decision_id) if decision_id
                      else self._q("SELECT * FROM decision_ledger ORDER BY seq"))
        return rows

_mem = Mem()
def store(): return Pg() if db.pool is not None else _mem

def current(entries: list[dict]) -> list[dict]:
    """Latest state of each (decision, version)."""
    out: dict[tuple, dict] = {}
    for e in entries: out[(e["decision_id"], e["version"])] = {**out.get((e["decision_id"], e["version"]), {}), **e}
    return sorted(out.values(), key=lambda x: -x["seq"])

# ---------------- API ----------------
class Confirm(BaseModel):
    room_id: str
    decision_id: str = Field(pattern=r"^[A-Za-z0-9_-]{6,64}$")
    version: int = Field(ge=1, le=1000)
    event_id: str                               # the encrypted proposal event in the chat
    owner: str
    due: str | None = Field(default=None, pattern=r"^\d{4}-\d{2}-\d{2}$")
    text_hash: str = Field(pattern=r"^[0-9a-f]{64}$")
    supersedes: int | None = None               # previous version this one replaces
    proposed_at: int                            # ms, the proposal event's server time

@router.post("/v1/decisions/confirm")
async def confirm(req: Confirm, user=Depends(auth.matrix_user)):
    me = user["user_id"]
    await auth.assert_room_member(user, req.room_id)
    if time.time() * 1000 - req.proposed_at > PROPOSAL_TTL_S * 1000: raise HTTPException(410, "This proposal is older than 72 hours and was dropped")
    s = store(); key = (req.decision_id, req.version)
    if any(e["kind"] == "confirmed" and e["version"] == req.version for e in await s.entries(req.decision_id)):
        return {"status": "confirmed", "already": True}
    rh = room_hash(req.room_id)
    await s.pend(key, {"room_hash": rh, "event_id": req.event_id, "owner": req.owner, "due": req.due, "text_hash": req.text_hash,
                       "supersedes": req.supersedes, "proposed_at": req.proposed_at, "confirmed_by": []})
    p = await s.get_pend(key)
    if p["text_hash"] != req.text_hash or p["owner"] != req.owner or p["room_hash"] != rh or p["due"] != req.due:
        raise HTTPException(409, "You are confirming a different text or owner than the others; reload the proposal")
    p = await s.confirm(key, me)
    await db.audit(me, "decision.confirm", f"{req.decision_id} v{req.version}")
    others = [u for u in p["confirmed_by"] if u != p["owner"]]
    if p["owner"] not in p["confirmed_by"] or len(others) < QUORUM_OTHERS:
        return {"status": "proposed", "confirmed_by": p["confirmed_by"], "needs": ("the owner and " if p["owner"] not in p["confirmed_by"] else "") + f"{QUORUM_OTHERS} other member"}
    now = int(time.time())
    if req.supersedes:
        old = [e for e in await s.entries(req.decision_id) if e["version"] == req.supersedes]
        if old: await s.append({**{k: old[-1][k] for k in ("decision_id", "version", "room_hash", "event_id", "owner", "due", "text_hash", "confirmed_by", "supersedes")}, "kind": "status", "status": "superseded", "at": now})
    e = await s.append({"decision_id": req.decision_id, "version": req.version, "kind": "confirmed", "room_hash": rh, "event_id": req.event_id, "owner": p["owner"],
                        "due": p["due"], "status": "confirmed", "text_hash": p["text_hash"], "confirmed_by": p["confirmed_by"], "supersedes": req.supersedes, "at": now})
    await s.drop_pend(key)
    await db.audit(me, "decision.ledger", f"{req.decision_id} v{req.version} seq={e['seq']}")
    return {"status": "confirmed", "seq": e["seq"], "confirmed_by": p["confirmed_by"]}

class Status(BaseModel):
    room_id: str
    version: int
    status: str = Field(pattern="^(in_progress|done|cancelled)$")

@router.post("/v1/decisions/{did}/status")
async def set_status(did: str, req: Status, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, req.room_id)
    rows = [e for e in await store().entries(did) if e["version"] == req.version]
    if not rows or rows[0]["room_hash"] != room_hash(req.room_id): raise HTTPException(404, "No such decision in this chat")
    last = current(rows)[0]
    if user["user_id"] != last["owner"]: raise HTTPException(403, "Only the owner changes the status")
    if last["status"] in ("superseded", "cancelled"): raise HTTPException(409, f"This version is {last['status']}")
    e = await store().append({**{k: last[k] for k in ("decision_id", "version", "room_hash", "event_id", "owner", "due", "text_hash", "confirmed_by", "supersedes")},
                              "kind": "status", "status": req.status, "at": int(time.time())})
    await db.audit(user["user_id"], "decision.status", f"{did} v{req.version} {req.status}")
    return {"seq": e["seq"], "status": req.status}

@router.get("/v1/decisions")
async def list_decisions(room_id: str | None = None, owner: str | None = None, user=Depends(auth.matrix_user)):
    """Ledger metadata for one chat you are in, or decisions you own (owner=me)."""
    if not room_id and owner != user["user_id"]: raise HTTPException(400, "Give room_id, or owner set to yourself")
    if room_id: await auth.assert_room_member(user, room_id)
    cur = current(await store().entries())
    if room_id: cur = [d for d in cur if d["room_hash"] == room_hash(room_id)]
    if owner: cur = [d for d in cur if d["owner"] == owner]
    return [{k: d[k] for k in ("decision_id", "version", "room_hash", "event_id", "owner", "due", "status", "text_hash", "confirmed_by", "supersedes", "at", "seq")} for d in cur]

@router.get("/v1/decisions/verify")
async def verify(user=Depends(require_admin)):
    prev, n = "0" * 64, 0
    for e in await store().entries():
        n += 1
        if e["prev_hash"] != prev or entry_hash(prev, e) != e["hash"]: return {"ok": False, "broken_at_seq": e["seq"], "checked": n}
        prev = e["hash"]
    return {"ok": True, "checked": n}
