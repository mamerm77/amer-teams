"""Reusable AI skills, custom agents and the agent marketplace (docs/SKILLS.md).

- A *skill* is a reusable instruction with named inputs ("Draft an RFP clause for {{topic}} with {{constraints}}").
- A *custom agent* is a standing persona: instructions used as the system prompt for every request to it.
Both start private to their author. The author can submit one to the organisation's marketplace; an
administrator reviews it (approve with a note, or reject with a reason). Approved items are listed for everyone in
the same tenant, who install them. Editing an approved item sends it back for review as a new version.
Running one goes through the same Guardian policy check, redaction and labels as every AI request.
"""
from __future__ import annotations
import json, re, secrets
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db, flags
from .admin import require_admin

router = APIRouter()
INPUT_RX = re.compile(r"\{\{\s*([a-z][a-z0-9_]{0,30})\s*\}\}")
FORBIDDEN = re.compile(r"ignore (all|any|previous) (instructions|rules)|disregard (the )?(system|guardian)|reveal (the )?system prompt", re.I)
_mem: dict = {"skills": {}, "installs": set()}

class SkillIn(BaseModel):
    kind: str = Field(pattern=r"^(skill|agent)$")
    name: str = Field(min_length=2, max_length=60)
    description: str = Field(default="", max_length=300)
    instructions: str = Field(min_length=10, max_length=6000)

def _check(s: SkillIn):
    if FORBIDDEN.search(s.instructions): raise HTTPException(422, "Instructions may not ask the AI to ignore its rules or the policy check")
    return sorted(set(INPUT_RX.findall(s.instructions)))

async def _get(sid):
    if db.pool is None: return _mem["skills"].get(sid)
    async with db.pool.connection() as c:
        r = await (await c.execute("SELECT id, tenant, owner, kind, name, description, instructions, inputs, status, review_note, version, installs FROM skills WHERE id=%s", (sid,))).fetchone()
    if not r: return None
    d = dict(zip(("id", "tenant", "owner", "kind", "name", "description", "instructions", "inputs", "status", "review_note", "version", "installs"), r))
    if isinstance(d["inputs"], str): d["inputs"] = json.loads(d["inputs"])
    return d

async def _put(d):
    if db.pool is None: _mem["skills"][d["id"]] = d; return
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO skills (id, tenant, owner, kind, name, description, instructions, inputs, status, review_note, version, installs) VALUES (%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s,%s) "
                        "ON CONFLICT (id) DO UPDATE SET name=EXCLUDED.name, description=EXCLUDED.description, instructions=EXCLUDED.instructions, inputs=EXCLUDED.inputs, status=EXCLUDED.status, "
                        "review_note=EXCLUDED.review_note, version=EXCLUDED.version, installs=EXCLUDED.installs, updated_at=now()",
                        (d["id"], d["tenant"], d["owner"], d["kind"], d["name"], d["description"], d["instructions"], json.dumps(d["inputs"]), d["status"], d["review_note"], d["version"], d["installs"]))

async def _all(where: str, args: tuple):
    if db.pool is None: return list(_mem["skills"].values())
    async with db.pool.connection() as c:
        ids = [r[0] for r in await (await c.execute(f"SELECT id FROM skills WHERE {where} ORDER BY installs DESC, name", args)).fetchall()]
    return [await _get(i) for i in ids]

async def _installed(user):
    if db.pool is None: return {s for u, s in _mem["installs"] if u == user}
    async with db.pool.connection() as c:
        return {r[0] for r in await (await c.execute("SELECT skill_id FROM skill_installs WHERE user_id=%s", (user,))).fetchall()}

@router.post("/v1/skills")
async def create(req: SkillIn, user=Depends(auth.matrix_user)):
    inputs = _check(req)
    d = {"id": f"sk_{secrets.token_hex(6)}", "tenant": await flags.tenant_of(user["user_id"]), "owner": user["user_id"], **req.model_dump(), "inputs": inputs,
         "status": "private", "review_note": "", "version": 1, "installs": 0}
    await _put(d); await db.audit(user["user_id"], "skill.create", d["id"]); return d

@router.put("/v1/skills/{sid}")
async def update(sid: str, req: SkillIn, user=Depends(auth.matrix_user)):
    d = await _get(sid)
    if not d or d["owner"] != user["user_id"]: raise HTTPException(404, "Not your skill")
    inputs = _check(req)
    d.update({**req.model_dump(), "inputs": inputs, "version": d["version"] + 1, "kind": d["kind"],
              "status": "submitted" if d["status"] in ("approved", "submitted") else "private", "review_note": ""})   # a published one goes back for review
    await _put(d); return d

@router.post("/v1/skills/{sid}/submit")
async def submit(sid: str, user=Depends(auth.matrix_user)):
    d = await _get(sid)
    if not d or d["owner"] != user["user_id"]: raise HTTPException(404, "Not your skill")
    d["status"] = "submitted"; await _put(d); await db.audit(user["user_id"], "skill.submit", sid); return d

class Review(BaseModel):
    approve: bool
    note: str = Field(default="", max_length=300)

@router.post("/v1/skills/{sid}/review")
async def review(sid: str, req: Review, user=Depends(require_admin)):
    d = await _get(sid)
    if not d or d["status"] != "submitted": raise HTTPException(409, "Nothing to review")
    if not req.approve and not req.note: raise HTTPException(422, "Say why it is rejected")
    d["status"] = "approved" if req.approve else "rejected"; d["review_note"] = req.note
    await _put(d); await db.audit(user["user_id"], f"skill.{'approve' if req.approve else 'reject'}", sid); return d

@router.get("/v1/skills/mine")
async def mine(user=Depends(auth.matrix_user)):
    inst = await _installed(user["user_id"])
    rows = await _all("owner=%s OR id = ANY(%s)", (user["user_id"], list(inst)))
    return [r for r in rows if r["owner"] == user["user_id"] or r["id"] in inst]

@router.get("/v1/skills/marketplace")
async def marketplace(user=Depends(auth.matrix_user)):
    t = await flags.tenant_of(user["user_id"]); inst = await _installed(user["user_id"])
    rows = await _all("tenant=%s AND status='approved'", (t,))
    return [{**{k: r[k] for k in ("id", "kind", "name", "description", "inputs", "owner", "version", "installs")}, "installed": r["id"] in inst}
            for r in rows if r["tenant"] == t and r["status"] == "approved"]

@router.get("/v1/skills/review-queue")
async def queue(user=Depends(require_admin)):
    return [r for r in await _all("status='submitted'", ()) if r["status"] == "submitted"]

@router.post("/v1/skills/{sid}/install")
async def install(sid: str, user=Depends(auth.matrix_user)):
    d = await _get(sid)
    if not d or d["status"] != "approved" or d["tenant"] != await flags.tenant_of(user["user_id"]): raise HTTPException(404, "Not in your marketplace")
    if db.pool is None:
        if (user["user_id"], sid) not in _mem["installs"]: _mem["installs"].add((user["user_id"], sid)); d["installs"] += 1
    else:
        async with db.pool.connection() as c:
            r = await c.execute("INSERT INTO skill_installs (user_id, skill_id) VALUES (%s,%s) ON CONFLICT DO NOTHING", (user["user_id"], sid))
            if r.rowcount: await c.execute("UPDATE skills SET installs = installs + 1 WHERE id=%s", (sid,))
    return {"installed": True}

@router.delete("/v1/skills/{sid}/install")
async def uninstall(sid: str, user=Depends(auth.matrix_user)):
    if db.pool is None: _mem["installs"].discard((user["user_id"], sid))
    else:
        async with db.pool.connection() as c: await c.execute("DELETE FROM skill_installs WHERE user_id=%s AND skill_id=%s", (user["user_id"], sid))
    return {"installed": False}

async def usable(user: str, sid: str) -> dict:
    """The skill if this user may run it: their own (any status), or approved in their tenant and installed."""
    d = await _get(sid)
    if not d: raise HTTPException(404, "No such skill")
    if d["owner"] == user: return d
    if d["status"] == "approved" and d["tenant"] == await flags.tenant_of(user) and sid in await _installed(user): return d
    raise HTTPException(403, "Install this skill from the marketplace first")

def fill(d: dict, values: dict[str, str]) -> tuple[str, str]:
    """(system, prompt) for a run. Skills: inputs substituted into the instruction; agents: instructions are the system."""
    if d["kind"] == "agent": return (d["instructions"] + "\nBritish English. Follow the organisation's policies.", values.get("input", ""))
    missing = [i for i in d["inputs"] if not str(values.get(i, "")).strip()]
    if missing: raise HTTPException(422, f"Fill in: {', '.join(missing)}")
    prompt = INPUT_RX.sub(lambda m: str(values.get(m.group(1), ""))[:4000], d["instructions"])
    return ("You are Amer, running the organisation skill \"" + d["name"] + "\". Do exactly what the skill asks. British English.", prompt)

class RunReq(BaseModel):
    values: dict[str, str] = {}
    context: str = Field(default="", max_length=60000)
    labels: list[str] = []
    encrypted: bool = False

@router.post("/v1/skills/{sid}/run")
async def run(sid: str, req: RunReq, user=Depends(auth.matrix_user)):
    from . import agents
    if req.encrypted and not (await flags.flags_for(user["user_id"]))["ai_plain_server"]:
        raise HTTPException(403, "Your organisation does not allow encrypted chats to go to the AI service; an attested enclave is required")
    d = await usable(user["user_id"], sid); system, prompt = fill(d, req.values)
    res = await agents.run(prompt, req.context, req.labels, system_override=(d["name"], system))
    await db.ai_request(user["user_id"], f"skill:{d['name']}"[:60], "blocked" if res.get("blocked") else "error" if res.get("error") else "ok", 0)
    return res

@router.get("/v1/skills/{sid}/prepare")
async def prepare(sid: str, user=Depends(auth.matrix_user)):
    """For the encrypted-AI enclave path: the app needs the instructions to build the sealed request itself."""
    d = await usable(user["user_id"], sid)
    return {k: d[k] for k in ("id", "kind", "name", "instructions", "inputs")}
