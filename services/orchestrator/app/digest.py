"""Catch-up digest: "what did I miss" across chats, channels and meetings (docs/CATCH_UP.md).

The app collects the unread messages per room since the user's read marker and decrypts them on the device. It
sends them here only when the user asks to be caught up. This module:
1. checks the user is a member of every room sent (no reading someone else's rooms through the digest);
2. ranks rooms: mentions of the user first, then direct chats, then priority senders, then unread count;
3. lists rooms labelled Confidential or Restricted by name and count only: their text is never sent to the AI;
4. summarises the top 30 rooms through Guardian (policy check and redaction) and the Router;
5. caches the result per user for 30 minutes (same input gives the same digest, no second AI charge);
6. writes one audit entry per digest, with counts only.
Nothing is stored except the in-memory cache, which holds the summaries, not the messages.
"""
import asyncio, hashlib, json, re, time
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import agents, auth, db, guardian

from . import flags
router = APIRouter(dependencies=[Depends(flags.require("catch_up"))])
MAX_ROOMS, MAX_MSGS, CACHE_S = 30, 60, 30 * 60
BLOCKED = {"confidential", "restricted"}
_cache: dict[str, tuple[float, str, dict]] = {}

class Msg(BaseModel):
    sender: str
    body: str = Field(max_length=4000)
    ts: int = 0
    mentions_me: bool = False
    event_id: str = ""

class Room(BaseModel):
    room_id: str
    name: str = ""
    kind: str = "group"                # direct | group | channel | meeting
    labels: list[str] = []
    unread: int = 0
    messages: list[Msg] = []

class DigestReq(BaseModel):
    rooms: list[Room] = Field(default=[], max_length=200)
    window_h: float = 24
    priority_senders: list[str] = []
    refresh: bool = False

SYSTEM = ("You write a catch-up digest of one workplace chat the reader missed. Reply ONLY with JSON: "
          '{"summary": "at most 2 sentences", "decisions": [str], "needs_reply": [str]}. '
          "needs_reply lists questions or requests addressed to the reader (named in the request) that are still "
          "unanswered. Use names as given. British English. Never invent content.")

def rank(r: Room, me: str, prio: set[str]) -> tuple:
    mentions = sum(m.mentions_me for m in r.messages)
    return (-mentions, r.kind != "direct", -sum(m.sender in prio for m in r.messages), -(r.unread or len(r.messages)))

def _parse(text: str) -> dict | None:
    m = re.search(r"\{.*\}", text, re.S)
    try:
        j = json.loads(m.group(0)) if m else None
    except ValueError:
        return None
    if not isinstance(j, dict) or not isinstance(j.get("summary"), str): return None
    lst = lambda v: [str(x) for x in v][:5] if isinstance(v, list) else []
    return {"summary": j["summary"][:400], "decisions": lst(j.get("decisions")), "needs_reply": lst(j.get("needs_reply"))}

async def _summarise(r: Room, me_name: str, sem: asyncio.Semaphore) -> dict:
    base = {"room_id": r.room_id, "name": r.name, "kind": r.kind, "unread": r.unread or len(r.messages),
            "mentions": sum(m.mentions_me for m in r.messages),
            "first_unread": r.messages[0].event_id if r.messages else ""}
    if {l.lower() for l in r.labels} & BLOCKED:
        return {**base, "status": "label", "summary": f"Labelled {r.labels[0]}: not sent to the AI. Open the chat to read it."}
    if not r.messages:
        return {**base, "status": "empty", "summary": ""}
    lines = "\n".join(f"{m.sender}{' (mentions you)' if m.mentions_me else ''}: {m.body}" for m in r.messages[-MAX_MSGS:])
    async with sem:
        res = await agents.run(f"{SYSTEM}\nCatch me up on this chat. The reader is {me_name}.", f"Chat: {r.name}\n{lines}",
                               r.labels, "digest")
    if res.get("blocked"):
        return {**base, "status": "blocked", "summary": res["answer"]}
    if res.get("error"):
        nokey = "ANTHROPIC_API_KEY is not set" in res["answer"]
        return {**base, "status": "no_ai" if nokey else "error",
                "summary": "AI is not set up on this server." if nokey else "The AI service could not be reached."}
    p = _parse(res["answer"])
    return {**base, "status": "ok", **(p or {"summary": res["answer"][:400], "decisions": [], "needs_reply": []})}

@router.post("/v1/ai/digest")
async def digest(req: DigestReq, user=Depends(auth.matrix_user)):
    me = user["user_id"]
    await asyncio.gather(*(auth.assert_room_member(user, r.room_id) for r in req.rooms))
    key = hashlib.sha256(req.model_dump_json(exclude={"refresh"}).encode()).hexdigest()
    hit = _cache.get(me)
    if hit and not req.refresh and hit[1] == key and time.time() - hit[0] < CACHE_S:
        return {**hit[2], "cached": True}
    prio = set(req.priority_senders)
    rooms = sorted((r for r in req.rooms if r.messages or r.unread), key=lambda r: rank(r, me, prio))
    top, rest = rooms[:MAX_ROOMS], rooms[MAX_ROOMS:]
    t0 = time.perf_counter(); sem = asyncio.Semaphore(4)
    cards = await asyncio.gather(*(_summarise(r, me.split(":")[0].lstrip("@"), sem) for r in top))
    out = {"generated_at": int(time.time()), "window_h": req.window_h, "cards": list(cards),
           "more": [{"room_id": r.room_id, "name": r.name, "unread": r.unread or len(r.messages)} for r in rest],
           "totals": {"rooms": len(rooms), "messages": sum(r.unread or len(r.messages) for r in rooms),
                      "mentions": sum(c["mentions"] for c in cards)}, "cached": False}
    status = "ok" if any(c["status"] == "ok" for c in cards) else (cards[0]["status"] if cards else "empty")
    await db.ai_request(me, "Digest", status, int((time.perf_counter() - t0) * 1000))
    await db.audit(me, "ai.digest", f"rooms={len(top)} label_withheld={sum(c['status'] == 'label' for c in cards)} status={status}")
    _cache[me] = (time.time(), key, out)
    return out
