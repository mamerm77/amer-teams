"""Virtual office: your own team of AI agents that manage work together (docs/VIRTUAL_OFFICE.md).

Every person gets a staff: a Chief of Staff who receives your requests, plans them and hands parts to specialists
(inbox, calendar, research, writing, vendors and RFPs, optical strategy, finance, health and so on), who work in
parallel and hand their results back; the Chief of Staff then writes you one answer. Every hand-over is a message
in the team room, so you can watch them work together, see who is busy, and read each one's output.

Nothing leaves the team on its own: any result that would message someone or book something is marked "needs your
approval" and goes through the glass box (docs/PERSONAL_AGENTS.md). Requests pass Guardian like every AI call.
"""
from __future__ import annotations
import asyncio, json, re, secrets
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db, guardian, llm

router = APIRouter(prefix="/v1/office")
STAFF = [  # id, name, role, department, room, instructions
    ("chief", "Amer", "Chief of Staff", "Leadership", "Command centre", "You coordinate the team. Plan the request, delegate to the right specialists, then merge their work into one clear answer for your principal."),
    ("inbox", "Layla", "Inbox and messages", "Comms", "Comms room", "You triage messages: what needs a reply, drafts of replies, what can wait. Never send anything; draft only."),
    ("calendar", "Omar", "Calendar and meetings", "Operations", "Operations room", "You plan schedules, meeting agendas and preparation notes. Propose times; never book without approval."),
    ("research", "Noor", "Research analyst", "Strategy", "Strategy room", "You research and summarise facts, options and trade-offs, saying what is known and what is uncertain."),
    ("writer", "Sara", "Writer and editor", "Creative", "Creative studio", "You write and edit documents, briefs and slides text in clear British English."),
    ("vendor", "Khalid", "Vendors and RFPs", "Finance", "Finance room", "You handle vendor matters: RFP clauses, evaluation criteria, negotiation points, SLA terms."),
    ("optical", "Rashid", "Optical network strategist", "Strategy", "Strategy room", "You advise on optical transport: DWDM/OTN, coherent optics, ROADMs, capacity planning, vendor architectures."),
    ("finance", "Mariam", "Finance and budget", "Finance", "Finance room", "You estimate costs, budgets and business cases, showing assumptions."),
    ("growth", "Yousef", "Career and learning", "Growth", "Growth corner", "You suggest learning, career moves and personal development steps."),
    ("health", "Hana", "Health and routine", "Wellbeing", "Wellbeing room", "You suggest routines for rest, exercise and focus. General advice only, not medical advice."),
]
SPECIALISTS = [s[0] for s in STAFF if s[0] != "chief"]
OUTWARD = re.compile(r"\b(send|email|reply to|book|schedule|invite|post|message)\b", re.I)
_running: set[str] = set()

def _need():
    if db.pool is None: raise HTTPException(503, "The virtual office needs the database")

async def ensure_staff(owner: str):
    async with db.pool.connection() as c:
        n = (await (await c.execute("SELECT count(*) FROM office_agents WHERE owner=%s", (owner,))).fetchone())[0]
        if n: return
        for a in STAFF:
            await c.execute("INSERT INTO office_agents (owner, id, name, role, dept, room, instructions) VALUES (%s,%s,%s,%s,%s,%s,%s) ON CONFLICT DO NOTHING", (owner, *a))

async def _say(owner, task, sender, recipient, body):
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO office_messages (owner, task, sender, recipient, body) VALUES (%s,%s,%s,%s,%s)", (owner, task, sender, recipient, body[:8000]))

async def _status(owner, agent, status):
    async with db.pool.connection() as c: await c.execute("UPDATE office_agents SET status=%s WHERE owner=%s AND id=%s", (status, owner, agent))

async def _task(owner, parent, agent, title, brief, status="assigned"):
    tid = f"ot_{secrets.token_hex(5)}"
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO office_tasks (id, owner, parent, agent, title, brief, status) VALUES (%s,%s,%s,%s,%s,%s,%s)", (tid, owner, parent, agent, title[:200], brief[:6000], status))
    return tid

async def _finish(tid, status, result=None, needs_approval=False):
    async with db.pool.connection() as c:
        await c.execute("UPDATE office_tasks SET status=%s, result=coalesce(%s, result), needs_approval=%s, updated_at=now() WHERE id=%s", (status, result, needs_approval, tid))

async def _agents(owner) -> dict[str, dict]:
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT id, name, role, dept, room, instructions, status, enabled FROM office_agents WHERE owner=%s", (owner,))).fetchall()
    return {r[0]: dict(zip(("id", "name", "role", "dept", "room", "instructions", "status", "enabled"), r)) for r in rows}

def _json(text: str):
    m = re.search(r"\{.*\}", text, re.S)
    return json.loads(m.group(0)) if m else None

async def run_request(owner: str, root: str, request: str, labels: list[str]):
    """Chief of Staff plans -> specialists work in parallel -> Chief of Staff merges. Every step is a message."""
    team = await _agents(owner); chief = team["chief"]
    try:
        await _status(owner, "chief", "working")
        roster = "\n".join(f"- {a['id']}: {a['name']}, {a['role']}" for a in team.values() if a["id"] != "chief" and a["enabled"])
        plan_raw = await llm.complete(chief["instructions"] + "\nReply ONLY as JSON: {\"plan\": str, \"assignments\": [{\"agent\": id, \"title\": str, \"brief\": str}]}. Use 1 to 4 specialists; only those needed.",
                                      f"Team:\n{roster}\n\nRequest from your principal:\n{guardian.redact(request)}", max_tokens=900)
        plan = _json(plan_raw) or {"plan": "Handle it myself.", "assignments": []}
        jobs = [a for a in plan.get("assignments", []) if a.get("agent") in team and a["agent"] != "chief" and team[a["agent"]]["enabled"]][:4]
        await _say(owner, root, "chief", "you", f"Plan: {plan.get('plan', '')}" + ("".join(f"\n→ {team[j['agent']]['name']}: {j.get('title', '')}" for j in jobs)))

        async def work(j):
            a = team[j["agent"]]
            tid = await _task(owner, root, a["id"], j.get("title", "Task"), j.get("brief", ""), "in_progress")
            await _say(owner, tid, "chief", a["id"], f"{j.get('title', '')}: {j.get('brief', '')}")
            await _status(owner, a["id"], "working")
            try:
                out = await llm.complete(a["instructions"] + " Keep it focused and practical. British English.",
                                         f"From the Chief of Staff:\n{j.get('brief', '')}\n\nOriginal request:\n{guardian.redact(request)}", max_tokens=900)
                outward = bool(OUTWARD.search(j.get("title", "") + " " + j.get("brief", "")))
                await _finish(tid, "needs_approval" if outward else "done", out, outward)
                await _say(owner, tid, a["id"], "chief", out)
                return a, out
            except llm.LLMError as e:
                await _finish(tid, "failed", str(e)); await _say(owner, tid, a["id"], "chief", f"I could not do this: {e}"); return a, f"(failed: {e})"
            finally:
                await _status(owner, a["id"], "available")

        results = await asyncio.gather(*(work(j) for j in jobs))
        merged = await llm.complete(chief["instructions"], "Write the final answer for your principal from your team's work. Credit who did what in one line at the end.\n\n"
                                    f"Request:\n{guardian.redact(request)}\n\n" + "\n\n".join(f"== {a['name']} ({a['role']}) ==\n{out}" for a, out in results), max_tokens=1200) if results \
                 else await llm.complete(chief["instructions"], guardian.redact(request), max_tokens=1200)
        needs = any(OUTWARD.search(j.get("title", "") + j.get("brief", "")) for j in jobs)
        await _finish(root, "needs_approval" if needs else "done", merged, needs)
        await _say(owner, root, "chief", "you", merged)
    except llm.LLMError as e:
        await _finish(root, "failed", str(e)); await _say(owner, root, "chief", "you", f"The team could not start: {e}")
    except Exception as e:
        await _finish(root, "failed", type(e).__name__); await _say(owner, root, "chief", "you", f"Something went wrong ({type(e).__name__}).")
    finally:
        await _status(owner, "chief", "available"); _running.discard(root)

class Ask(BaseModel):
    request: str = Field(min_length=3, max_length=8000)
    agent: str | None = None              # ask one agent directly instead of the Chief of Staff
    labels: list[str] = []

@router.post("/requests")
async def ask(req: Ask, user=Depends(auth.matrix_user)):
    _need(); owner = user["user_id"]; await ensure_staff(owner)
    ok, why = guardian.check(req.request, req.labels)
    if not ok: raise HTTPException(403, why)
    team = await _agents(owner)
    if req.agent and req.agent not in team: raise HTTPException(404, "No such agent")
    if sum(1 for t in _running if t.startswith(owner)) >= 3: raise HTTPException(429, "Your team is already working on three requests")
    if req.agent and req.agent != "chief":
        tid = await _task(owner, None, req.agent, req.request[:80], req.request, "in_progress")
        await _say(owner, tid, "you", req.agent, req.request)
        async def one():
            a = team[req.agent]; await _status(owner, a["id"], "working")
            try:
                out = await llm.complete(a["instructions"] + " British English.", guardian.redact(req.request), max_tokens=1000)
                await _finish(tid, "done", out); await _say(owner, tid, a["id"], "you", out)
            except llm.LLMError as e:
                await _finish(tid, "failed", str(e)); await _say(owner, tid, a["id"], "you", f"I could not do this: {e}")
            finally:
                await _status(owner, a["id"], "available")
        asyncio.create_task(one()); return {"task": tid}
    tid = await _task(owner, None, "chief", req.request[:80], req.request, "in_progress")
    await _say(owner, tid, "you", "chief", req.request)
    _running.add(f"{owner}|{tid}")
    asyncio.create_task(run_request(owner, tid, req.request, req.labels))
    return {"task": tid}

@router.get("")
async def office(user=Depends(auth.matrix_user)):
    """Everything the office view needs: agents with live status and counts, recent tasks, recent team messages."""
    _need(); owner = user["user_id"]; await ensure_staff(owner)
    async with db.pool.connection() as c:
        tasks = await (await c.execute("SELECT id, parent, agent, title, status, needs_approval, extract(epoch from created_at)::bigint, extract(epoch from updated_at)::bigint FROM office_tasks WHERE owner=%s ORDER BY created_at DESC LIMIT 60", (owner,))).fetchall()
        msgs = await (await c.execute("SELECT id, task, sender, recipient, left(body, 600), extract(epoch from at)::bigint FROM office_messages WHERE owner=%s ORDER BY id DESC LIMIT 80", (owner,))).fetchall()
    team = await _agents(owner)
    T = [dict(zip(("id", "parent", "agent", "title", "status", "needs_approval", "created_at", "updated_at"), t)) for t in tasks]
    for a in team.values():
        mine = [t for t in T if t["agent"] == a["id"]]
        a.update(open=sum(t["status"] in ("assigned", "in_progress") for t in mine), approvals=sum(t["status"] == "needs_approval" for t in mine), done=sum(t["status"] == "done" for t in mine))
        a.pop("instructions", None)
    return {"agents": [team[s[0]] for s in STAFF if s[0] in team] + [a for k, a in team.items() if k not in {s[0] for s in STAFF}],
            "tasks": T, "messages": [dict(zip(("id", "task", "sender", "recipient", "body", "at"), m)) for m in msgs]}

@router.get("/tasks/{tid}")
async def task(tid: str, user=Depends(auth.matrix_user)):
    _need()
    async with db.pool.connection() as c:
        t = await (await c.execute("SELECT id, parent, agent, title, brief, status, result, needs_approval FROM office_tasks WHERE id=%s AND owner=%s", (tid, user["user_id"]))).fetchone()
        if not t: raise HTTPException(404, "No such task")
        subs = await (await c.execute("SELECT id, agent, title, status, result FROM office_tasks WHERE parent=%s AND owner=%s ORDER BY created_at", (tid, user["user_id"]))).fetchall()
        msgs = await (await c.execute("SELECT sender, recipient, body, extract(epoch from at)::bigint FROM office_messages WHERE owner=%s AND (task=%s OR task IN (SELECT id FROM office_tasks WHERE parent=%s)) ORDER BY id", (user["user_id"], tid, tid))).fetchall()
    return {**dict(zip(("id", "parent", "agent", "title", "brief", "status", "result", "needs_approval"), t)),
            "subtasks": [dict(zip(("id", "agent", "title", "status", "result"), s)) for s in subs],
            "conversation": [dict(zip(("sender", "recipient", "body", "at"), m)) for m in msgs]}

class Decide(BaseModel): approve: bool
@router.post("/tasks/{tid}/decide")
async def decide(tid: str, req: Decide, user=Depends(auth.matrix_user)):
    _need()
    async with db.pool.connection() as c:
        r = await c.execute("UPDATE office_tasks SET status=%s, needs_approval=false, updated_at=now() WHERE id=%s AND owner=%s AND status='needs_approval'", ("approved" if req.approve else "rejected", tid, user["user_id"]))
    if not r.rowcount: raise HTTPException(409, "Nothing waiting for approval")
    await _say(user["user_id"], tid, "you", "chief", "Approved." if req.approve else "Not approved.")
    return {"status": "approved" if req.approve else "rejected"}

class AgentEdit(BaseModel):
    name: str | None = Field(default=None, max_length=40)
    instructions: str | None = Field(default=None, max_length=2000)
    enabled: bool | None = None

@router.patch("/agents/{aid}")
async def edit_agent(aid: str, req: AgentEdit, user=Depends(auth.matrix_user)):
    _need(); await ensure_staff(user["user_id"])
    if aid == "chief" and req.enabled is False: raise HTTPException(422, "The Chief of Staff cannot be switched off")
    sets = {k: v for k, v in req.model_dump().items() if v is not None}
    if not sets: return {"ok": True}
    async with db.pool.connection() as c:
        r = await c.execute("UPDATE office_agents SET " + ", ".join(f"{k}=%s" for k in sets) + " WHERE owner=%s AND id=%s", (*sets.values(), user["user_id"], aid))
    if not r.rowcount: raise HTTPException(404, "No such agent")
    return {"ok": True}
