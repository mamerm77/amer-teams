"""Personal agent teams and the agent glass box (docs/PERSONAL_AGENTS.md).

Any user can give their own small team (researcher, writer, scheduler) a goal and watch it work live in Agent Ops.

Glass box. Every action that leaves the team (send a message, book a meeting) goes
  proposed → awaiting_approval → approved | edited → executing → done
with the exits rejected, expired (24 h) and failed. The agent's tool waits inside the session (nothing is
lost). The owner sees a card with the plan, the target, a preview of exactly what will be sent and the data
touched, then approves, edits or rejects. Approved actions are carried out by the owner's own app, which holds
the encryption keys and sends as the owner; it must present the approved payload's hash, or execution is refused.

Scope. The team runs with the owner's Matrix token, so every room check is the owner's own membership (a room
they are not in fails with Synapse's 403 as a tool error). The server cannot read end-to-end encrypted rooms:
the agents see only what the owner attached to the goal from their own device.

Budget. Tokens are counted from the SDK's usage reports; the project stops as soon as the monthly cap is reached,
so no further model calls are made. Deliverables are saved in the project, never posted without approval.
"""
from __future__ import annotations

import asyncio, hashlib, json, os, re, time, uuid
from pathlib import Path
from typing import Any

import httpx
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field

from .. import auth, config, db
from . import store as S
from .runner import ProjectRun

from .. import flags
router = APIRouter(prefix="/v1/agentops", dependencies=[Depends(flags.require("personal_agents"))])
TTL_S = 24 * 3600
MONTHLY_TOKENS = int(os.getenv("AGENTOPS_PERSONAL_TOKENS", "300000"))
MAX_CONCURRENT = 3
APPROVAL_REQUESTED, APPROVAL_DECIDED, DELIVERABLE = "approval.requested", "approval.decided", "deliverable.saved"

def phash(payload: dict) -> str:
    return hashlib.sha256(json.dumps(payload, sort_keys=True, ensure_ascii=False).encode()).hexdigest()

# ---------------- approvals and budgets (PostgreSQL; memory in tests) ----------------
class Mem:
    def __init__(self): self.a: dict[str, dict] = {}; self.budget: dict[str, dict] = {}
    async def add(self, a): self.a[a["id"]] = a
    async def get(self, aid): return self.a.get(aid)
    async def update(self, aid, **k): self.a[aid].update(k)
    async def list(self, owner, status=None):
        return sorted([x for x in self.a.values() if x["owner"] == owner and (status is None or x["status"] == status)], key=lambda x: -x["created_at"])
    async def cancel_waiting(self):
        for x in self.a.values():
            if x["status"] in ("awaiting", "approved", "edited", "executing"): x["status"] = "cancelled"
    async def tokens(self, user):
        b = self.budget.get(user); m = time.strftime("%Y-%m")
        return 0 if not b or b["month"] != m else b["used"]
    async def add_tokens(self, user, n):
        m = time.strftime("%Y-%m"); b = self.budget.get(user)
        if not b or b["month"] != m: b = self.budget[user] = {"month": m, "used": 0}
        b["used"] += n; return b["used"]

class Pg(Mem):
    async def _q(self, sql, *a, one=False):
        async with db.pool.connection() as c:
            cur = await c.execute(sql, a)
            if cur.description is None: return None
            cols = [d.name for d in cur.description]; rows = [dict(zip(cols, r)) for r in await cur.fetchall()]
            return (rows[0] if rows else None) if one else rows
    @staticmethod
    def _f(r):
        if not r: return r
        f = lambda v: v.timestamp() if hasattr(v, "timestamp") else v
        return {**r, "created_at": f(r["created_at"]), "expires_at": f(r["expires_at"]), "decided_at": f(r.get("decided_at")),
                "preview": r["preview"] if isinstance(r["preview"], dict) else json.loads(r["preview"]),
                "payload": r["payload"] if isinstance(r["payload"], dict) else json.loads(r["payload"])}
    async def add(self, a):
        await self._q("INSERT INTO agent_approvals (id, project_id, owner, agent, tool, category, payload_hash, payload, preview, est_tokens, est_cost_usd, status, created_at, expires_at) "
                      "VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,to_timestamp(%s),to_timestamp(%s))",
                      a["id"], a["project_id"], a["owner"], a["agent"], a["tool"], a["category"], a["payload_hash"], json.dumps(a["payload"]),
                      json.dumps(a["preview"]), a.get("est_tokens"), a.get("est_cost_usd"), a["status"], a["created_at"], a["expires_at"])
    async def get(self, aid): return self._f(await self._q("SELECT * FROM agent_approvals WHERE id=%s", aid, one=True))
    async def update(self, aid, **k):
        for col, v in k.items():
            if col in ("payload", "preview"): v = json.dumps(v)
            if col == "decided_at": await self._q("UPDATE agent_approvals SET decided_at=to_timestamp(%s) WHERE id=%s", v, aid)
            else: await self._q(f"UPDATE agent_approvals SET {col}=%s WHERE id=%s", v, aid)
    async def list(self, owner, status=None):
        rows = await (self._q("SELECT * FROM agent_approvals WHERE owner=%s AND status=%s ORDER BY created_at DESC LIMIT 100", owner, status) if status
                      else self._q("SELECT * FROM agent_approvals WHERE owner=%s ORDER BY created_at DESC LIMIT 100", owner))
        return [self._f(r) for r in rows]
    async def cancel_waiting(self):
        await self._q("UPDATE agent_approvals SET status='cancelled', reason='server restarted' WHERE status IN ('awaiting','approved','edited','executing')")
    async def tokens(self, user):
        r = await self._q("SELECT tokens_used FROM personal_budgets WHERE user_id=%s AND month=date_trunc('month', now())::date", user, one=True)
        return r["tokens_used"] if r else 0
    async def add_tokens(self, user, n):
        r = await self._q("INSERT INTO personal_budgets (user_id, month, tokens_used, tokens_cap) VALUES (%s, date_trunc('month', now())::date, %s, %s) "
                          "ON CONFLICT (user_id) DO UPDATE SET tokens_used = CASE WHEN personal_budgets.month = date_trunc('month', now())::date "
                          "THEN personal_budgets.tokens_used + EXCLUDED.tokens_used ELSE EXCLUDED.tokens_used END, month = EXCLUDED.month RETURNING tokens_used",
                          user, n, MONTHLY_TOKENS, one=True)
        return r["tokens_used"]

_mem = Mem()
def store(): return Pg() if db.pool is not None else _mem
_signals: dict[str, asyncio.Event] = {}            # approval id -> wakes the waiting tool on decision or completion
def _signal(aid): _signals.setdefault(aid, asyncio.Event()).set()

async def _wait(aid: str, until: float, done: set[str]) -> dict:
    while True:
        a = await store().get(aid)
        if a["status"] in done: return a
        if time.time() >= until:
            await store().update(aid, status="expired"); return await store().get(aid)
        ev = _signals.setdefault(aid, asyncio.Event()); ev.clear()
        try: await asyncio.wait_for(ev.wait(), timeout=min(30, max(0.05, until - time.time())))
        except asyncio.TimeoutError: pass

# ---------------- the glass box itself ----------------
async def glass_box(run: "PersonalRun", agent: str, tool: str, payload: dict, preview: dict, category: str = "write_external") -> str:
    """Pause the agent until the owner decides, then until the owner's app has carried it out."""
    a = {"id": "ap_" + uuid.uuid4().hex[:10], "project_id": run.id, "owner": run.created_by, "agent": agent, "tool": tool,
         "category": category, "payload": payload, "payload_hash": phash(payload), "preview": preview,
         "est_tokens": None, "est_cost_usd": None,                 # not estimated: shown as such, never invented
         "status": "awaiting", "created_at": time.time(), "expires_at": time.time() + TTL_S}
    await store().add(a)
    await run.emit(APPROVAL_REQUESTED, agent, approval_id=a["id"], tool=tool, preview=preview)
    await db.audit(run.created_by, "agent.approval.requested", f"{run.id} {a['id']} {tool}")
    a = await _wait(a["id"], a["expires_at"], {"approved", "edited", "rejected", "expired", "cancelled"})
    await run.emit(APPROVAL_DECIDED, agent, approval_id=a["id"], status=a["status"])
    if a["status"] == "rejected": return f"rejected by user: {a.get('reason') or 'no reason given'}. Re-plan without this action."
    if a["status"] in ("expired", "cancelled"): return f"not done: the approval {a['status']} before the owner decided."
    await store().update(a["id"], status="executing")
    a = await _wait(a["id"], time.time() + TTL_S, {"done", "failed", "refused", "cancelled", "expired"})
    if a["status"] == "done": return f"done: {a.get('reason') or 'carried out by the owner'}"
    return f"not done: {a['status']} ({a.get('reason') or ''})"

async def member(token: str, room_id: str) -> None:
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/rooms/{room_id}/joined_members", headers={"Authorization": f"Bearer {token}"})
    if r.status_code != 200:
        raise PermissionError(f"{r.status_code} from the server: the owner is not a member of {room_id}")

def _text(s: str) -> dict: return {"content": [{"type": "text", "text": s}]}
def _err(s: str) -> dict: return {"content": [{"type": "text", "text": s}], "is_error": True}

PERSONAL_PROMPT = """You are Amer, leading the user's personal agent team (researcher, writer, scheduler).
Plan the goal with TodoWrite, delegate, check the work, and finish with a short honest report.
Rules:
- You may only read chats the user attached (read_room). Other chats are end-to-end encrypted and unreadable here.
- Save every deliverable with save_deliverable. Never post anything unless the goal asks for it.
- send_message and schedule_meeting wait for the user's approval; give a one-line reason. If rejected, re-plan.
- Say plainly what you could not do."""

class PersonalRun(ProjectRun):
    """A ProjectRun scoped to one user: their token, their attachments, their budget, the glass box."""
    def __init__(self, goal: str, workdir: Path, name: str, owner: str, token: str, attachments: list[dict], pid: str):
        super().__init__(goal, workdir, name, owner, pid)
        self.token = token; self.attach = {a["room_id"]: a for a in attachments}
        self.task: asyncio.Task | None = None; self.budget_hit = False; self._sub_tokens: dict[str, int] = {}

    # tools (each is also usable directly in tests)
    async def t_list_rooms(self, args): return _text(json.dumps([{"room_id": k, "name": v.get("name")} for k, v in self.attach.items()]))
    async def t_read_room(self, args):
        rid = args.get("room_id", "")
        try: await member(self.token, rid)
        except PermissionError as e: return _err(str(e))
        a = self.attach.get(rid)
        if not a: return _err("This chat is end-to-end encrypted and the owner did not attach it to the goal, so it cannot be read here.")
        return _text(f"Chat {a.get('name')} (attached by the owner):\n{a.get('text', '')[:60000]}")
    async def t_save(self, args):
        title = str(args.get("title") or "Deliverable")[:120]
        d = self.workdir / "deliverables"; d.mkdir(parents=True, exist_ok=True)
        f = d / (re.sub(r"[^A-Za-z0-9]+", "-", title).strip("-")[:60] + ".md")
        f.write_text(str(args.get("markdown", "")), encoding="utf-8")
        await self.emit(DELIVERABLE, "writer", title=title, file=f.name, bytes=f.stat().st_size)
        return _text(f"Saved {f.name} to the owner's deliverables.")
    async def t_send(self, args):
        rid, text = args.get("room_id", ""), str(args.get("text", ""))
        try: await member(self.token, rid)
        except PermissionError as e: return _err(str(e))
        name = (self.attach.get(rid) or {}).get("name", rid)
        res = await glass_box(self, "scheduler", "send_message", {"room_id": rid, "text": text},
                              {"kind": "message", "plan": args.get("reason", ""), "target": name, "to_room": rid, "text": text,
                               "data_touched": [n for n in (self.attach.get(r, {}).get("name") for r in self.attach) if n]})
        return _err(res) if not res.startswith("done") else _text(res)
    async def t_meet(self, args):
        rid = args.get("room_id", "")
        try: await member(self.token, rid)
        except PermissionError as e: return _err(str(e))
        p = {"room_id": rid, "title": str(args.get("title", "Meeting")), "start": str(args.get("start", "")), "duration_min": int(args.get("duration_min", 30))}
        res = await glass_box(self, "scheduler", "schedule_meeting", p, {"kind": "meeting", "plan": args.get("reason", ""),
                              "target": (self.attach.get(rid) or {}).get("name", rid), **p})
        return _err(res) if not res.startswith("done") else _text(res)

    def mcp(self):
        from claude_agent_sdk import create_sdk_mcp_server, tool
        T = [tool("list_rooms", "List the chats the owner attached to this goal.", {})(self.t_list_rooms),
             tool("read_room", "Read an attached chat's messages.", {"room_id": str})(self.t_read_room),
             tool("save_deliverable", "Save a deliverable (Markdown) for the owner.", {"title": str, "markdown": str})(self.t_save),
             tool("send_message", "Send a message to a chat. Waits for the owner's approval.", {"room_id": str, "text": str, "reason": str})(self.t_send),
             tool("schedule_meeting", "Book a meeting in a chat. Waits for the owner's approval.",
                  {"room_id": str, "title": str, "start": str, "duration_min": int, "reason": str})(self.t_meet)]
        return create_sdk_mcp_server("amer", tools=T)

    def options(self):
        from claude_agent_sdk import AgentDefinition, ClaudeAgentOptions, HookMatcher
        R, W, X = "mcp__amer__read_room", "mcp__amer__save_deliverable", "mcp__amer__list_rooms"
        team = {"researcher": AgentDefinition(description="Finds facts on the web and in attached chats", prompt="Research precisely; cite sources.", tools=["WebSearch", "WebFetch", R, X]),
                "writer": AgentDefinition(description="Writes the deliverables", prompt="Write clear British English; save with save_deliverable.", tools=[R, X, W]),
                "scheduler": AgentDefinition(description="Sends messages and books meetings, with approval", prompt="Every send or booking waits for approval.",
                                             tools=["mcp__amer__send_message", "mcp__amer__schedule_meeting", X])}
        return ClaudeAgentOptions(system_prompt=PERSONAL_PROMPT, agents=team, cwd=str(self.workdir),
            mcp_servers={"amer": self.mcp()}, max_turns=60, env=self.sdk_env(), permission_mode="default",
            allowed_tools=["Agent", "Task", "TodoWrite", "WebSearch", "WebFetch", R, W, X, "mcp__amer__send_message", "mcp__amer__schedule_meeting"],
            hooks={"PreToolUse": [HookMatcher(hooks=[self.on_pre_tool])], "PostToolUse": [HookMatcher(hooks=[self.on_post_tool])],
                   "PostToolUseFailure": [HookMatcher(hooks=[self.on_tool_fail])],
                   "SubagentStart": [HookMatcher(hooks=[self.on_sub_start])], "SubagentStop": [HookMatcher(hooks=[self.on_sub_stop])]})

    async def emit(self, type_, agent=None, agent_id=None, **data):
        await super().emit(type_, agent, agent_id, **data)
        if type_ == S.AGENT_USAGE:                                   # count every reported token against the budget
            if data.get("delta", True): n = int(data.get("tokens") or 0)
            else:                                                    # sub-agents report running totals: add the increase
                tot = int(data.get("total_tokens") or sum(int(data.get(k) or 0) for k in ("input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")))
                n = max(0, tot - self._sub_tokens.get(agent or "", 0)); self._sub_tokens[agent or ""] = tot
            if n <= 0: return
            used = await store().add_tokens(self.created_by, n)
            if used >= MONTHLY_TOKENS and not self.budget_hit:
                self.budget_hit = True
                await super().emit(S.AGENT_MESSAGE, "orchestrator", text="Budget reached: this month's token allowance is used up. Stopping.")
                if self.task and not self.task.done(): self.task.cancel()

    async def start(self, replay: bool = False):
        await S.store().create_project({"project_id": self.id, "name": self.name, "prompt": self.prompt, "workdir": str(self.workdir),
                                        "replay": False, "created_by": self.created_by, "scope": "personal"})
        await super().emit(S.PROJECT_STARTED, "orchestrator", name=self.name, prompt=self.prompt, team=["researcher", "writer", "scheduler"],
                           replay=False, created_by=self.created_by, scope="personal")

RUNS: dict[str, PersonalRun] = {}

# ---------------- API ----------------
class Goal(BaseModel):
    goal: str = Field(min_length=10, max_length=4000)
    name: str | None = Field(default=None, max_length=80)
    attachments: list[dict] = Field(default=[], max_length=10)      # [{room_id, name, text}] decrypted on the owner's device

@router.post("/personal")
async def start_personal(req: Goal, user=Depends(auth.matrix_user)):
    if not config.ANTHROPIC_API_KEY: raise HTTPException(503, "Personal agents need an AI provider key on the server (ANTHROPIC_API_KEY)")
    me = user["user_id"]
    if sum(r.created_by == me and r.task and not r.task.done() for r in RUNS.values()) >= MAX_CONCURRENT:
        raise HTTPException(429, f"At most {MAX_CONCURRENT} personal projects can run at once")
    if await store().tokens(me) >= MONTHLY_TOKENS: raise HTTPException(429, "Budget reached: this month's token allowance is used up")
    for a in req.attachments: await auth.assert_room_member(user, a.get("room_id", ""))
    from .router import WORKDIR
    pid = f"pp-{uuid.uuid4().hex[:8]}"; name = (req.name or req.goal).strip()[:80]
    run = PersonalRun(req.goal, WORKDIR / "personal" / pid, name, me, user["token"], req.attachments, pid)
    await run.start(); run.task = asyncio.create_task(run.run()); RUNS[pid] = run
    await db.audit(me, "agentops.personal.start", f"{pid} attachments={len(req.attachments)}")
    return {"project_id": pid}

@router.post("/personal/{pid}/stop")
async def stop_personal(pid: str, user=Depends(auth.matrix_user)):
    r = RUNS.get(pid)
    if not r or r.created_by != user["user_id"]: raise HTTPException(404, "No such project")
    if r.task and not r.task.done(): r.task.cancel()
    await db.audit(user["user_id"], "agentops.personal.stop", pid); return {"ok": True}

@router.get("/budget")
async def budget(user=Depends(auth.matrix_user)):
    return {"tokens_used": await store().tokens(user["user_id"]), "tokens_cap": MONTHLY_TOKENS}

@router.get("/approvals")
async def approvals(status: str | None = None, user=Depends(auth.matrix_user)):
    out = await store().list(user["user_id"], status)
    for a in out:
        if a["status"] == "awaiting" and time.time() > a["expires_at"]: a["status"] = "expired"
    return out

class Decide(BaseModel):
    decision: str = Field(pattern="^(approve|edit|reject)$")
    edited_payload: dict | None = None
    reason: str = Field(default="", max_length=500)

@router.post("/approvals/{aid}")
async def decide(aid: str, req: Decide, user=Depends(auth.matrix_user)):
    a = await store().get(aid)
    if not a or a["owner"] != user["user_id"]: raise HTTPException(404, "No such approval")
    if a["status"] != "awaiting": raise HTTPException(409, f"Already {a['status']}")
    if time.time() > a["expires_at"]: await store().update(aid, status="expired"); raise HTTPException(409, "Expired")
    upd: dict[str, Any] = {"decided_by": user["user_id"], "decided_at": time.time(), "reason": req.reason}
    if req.decision == "edit":
        if not req.edited_payload or set(req.edited_payload) != set(a["payload"]): raise HTTPException(422, "The edit must keep the same fields")
        upd.update(status="edited", payload=req.edited_payload, payload_hash=phash(req.edited_payload),
                   preview={**a["preview"], **{k: v for k, v in req.edited_payload.items() if k in a["preview"]}})
    else: upd["status"] = "approved" if req.decision == "approve" else "rejected"
    await store().update(aid, **upd)
    await db.audit(user["user_id"], f"agent.approval.{upd['status']}", f"{aid} hash={upd.get('payload_hash', a['payload_hash'])[:16]}")
    _signal(aid)
    return await store().get(aid)

class Done(BaseModel):
    payload_hash: str
    ok: bool = True
    result: str = Field(default="", max_length=300)

@router.post("/approvals/{aid}/done")
async def done(aid: str, req: Done, user=Depends(auth.matrix_user)):
    """The owner's app reports that it carried out the approved action, presenting the hash of what it sent."""
    a = await store().get(aid)
    if not a or a["owner"] != user["user_id"]: raise HTTPException(404, "No such approval")
    if a["status"] != "executing": raise HTTPException(409, f"Not executing ({a['status']})")
    if req.payload_hash != a["payload_hash"]:
        await store().update(aid, status="refused", reason="payload changed after approval")
        await db.audit(user["user_id"], "agent.approval.refused", aid); _signal(aid)
        raise HTTPException(409, "The payload does not match what was approved; ask again")
    await store().update(aid, status="done" if req.ok else "failed", reason=req.result)
    await db.audit(user["user_id"], "agent.action.done" if req.ok else "agent.action.failed", f"{aid} hash={a['payload_hash'][:16]}")
    _signal(aid); return {"ok": True}

@router.get("/personal/{pid}/deliverables")
async def deliverables(pid: str, user=Depends(auth.matrix_user)):
    projects = {p["project_id"]: p for p in await S.store().list_projects(200)}
    p = projects.get(pid)
    if not p or p["created_by"] != user["user_id"]: raise HTTPException(404, "No such project")
    d = Path(p["workdir"] or "") / "deliverables"
    return [{"name": f.name, "markdown": f.read_text(encoding="utf-8")} for f in sorted(d.glob("*.md"))] if d.exists() else []
