"""Live expertise map (docs/EXPERTISE.md). Opt-in: each person publishes their own topics (typed, or suggested on
their device from what they wrote and then approved by them). The server never reads messages to build this.
Search ranks people in the same organisation by how well their topics match, then by how recently they updated.
"""
from __future__ import annotations
import json, re
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db, flags

router = APIRouter()
norm = lambda t: re.sub(r"\s+", " ", t.strip().lower())

class Mine(BaseModel):
    topics: list[str] = Field(max_length=30)
    about: str = Field(default="", max_length=200)

@router.put("/v1/expertise/me")
async def publish(req: Mine, user=Depends(auth.matrix_user)):
    if db.pool is None: raise HTTPException(503, "Needs the database")
    topics = sorted({norm(t)[:40] for t in req.topics if norm(t)})
    async with db.pool.connection() as c:
        if not topics: await c.execute("DELETE FROM expertise WHERE user_id=%s", (user["user_id"],)); return {"topics": []}
        await c.execute("INSERT INTO expertise (user_id, tenant, topics, about, updated_at) VALUES (%s,%s,%s,%s,now()) ON CONFLICT (user_id) DO UPDATE SET tenant=EXCLUDED.tenant, topics=EXCLUDED.topics, about=EXCLUDED.about, updated_at=now()",
                        (user["user_id"], await flags.tenant_of(user["user_id"]), json.dumps(topics), req.about))
    return {"topics": topics}

@router.get("/v1/expertise/me")
async def mine(user=Depends(auth.matrix_user)):
    if db.pool is None: return {"topics": [], "about": ""}
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT topics, about FROM expertise WHERE user_id=%s", (user["user_id"],))).fetchone()
    return {"topics": r[0] if r else [], "about": r[1] if r else ""}

def score(query: str, topics: list[str]) -> float:
    q = norm(query); words = [w for w in re.split(r"[^\w+#.-]+", q) if len(w) > 1]
    s = 0.0
    for t in topics:
        if t == q: s += 3
        elif q in t or t in q: s += 2
        s += sum(1 for w in words if w in t.split() or w == t) * 0.8
    return s

@router.get("/v1/expertise")
async def search(q: str, user=Depends(auth.matrix_user)):
    if db.pool is None or len(q.strip()) < 2: return []
    t = await flags.tenant_of(user["user_id"])
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, topics, about, extract(epoch from updated_at)::bigint FROM expertise WHERE tenant=%s", (t,))).fetchall()
    out = [{"user_id": u, "topics": tp, "about": ab, "updated_at": up, "score": score(q, tp)} for u, tp, ab, up in rows]
    out = [o for o in out if o["score"] > 0]
    return sorted(out, key=lambda o: (-o["score"], -o["updated_at"]))[:25]
