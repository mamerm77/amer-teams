"""Plain-language workflows (docs/WORKFLOWS.md).

A workflow is a versioned JSON definition: trigger, then steps. The workflow agent drafts it from a sentence; the
user reviews it as a flow, dry-runs it and saves it. Running is split by the encryption rule:
- steps that read or post encrypted messages (message trigger, post, ask_form, approval, create_task, run_agent)
  run in the owner's app, which holds the keys and acts with the owner's own rights;
- this server stores definitions, versions and run records (status and metadata only, never message content),
  checks every room against the owner's membership, executes admin-approved http steps, counts runs and writes
  every step to the audit log and Agent Ops.
"""
from __future__ import annotations
import hashlib, json, re, secrets, time, urllib.parse
from typing import Any
import httpx
from fastapi import APIRouter, Depends, Header, HTTPException
from pydantic import BaseModel, Field
from . import agents, auth, db
from .admin import require_admin

router = APIRouter()
TRIGGERS = {"message", "schedule", "webhook", "form", "alarm", "calendar", "manual"}
STEPS = {"post", "ask_form", "approval", "condition", "wait", "call_connector", "run_agent", "create_task", "http"}
DEVICE_STEPS = {"post", "ask_form", "approval", "run_agent", "create_task"}
NOT_YET = {"call_connector": "they arrive with calendar and tool connectors"}
MAX_STEPS, MAX_RUNS_DAY, MAX_RUN_DAYS = 50, 1000, 30
OPS = (">=", "<=", "!=", "==", ">", "<", " contains ")

# ---------------- validation (pure) ----------------
def _edges(steps: list[dict]) -> dict[str, list[str]]:
    ids = [s["id"] for s in steps]; out = {}
    for i, s in enumerate(steps):
        nxt = ids[i + 1] if i + 1 < len(ids) else None
        if s.get("type") == "condition": out[s["id"]] = [x for x in (s.get("then"), s.get("else")) if x]
        elif s.get("next") == "end": out[s["id"]] = []
        elif s.get("next"): out[s["id"]] = [s["next"]]
        else: out[s["id"]] = [nxt] if nxt else []
    return out

def rooms_of(d: dict) -> set[str]:
    r = {d.get("trigger", {}).get("room")} | {s.get("room") for s in d.get("steps", [])}
    return {x for x in r if isinstance(x, str) and x.startswith("!")}

def validate(d: Any) -> list[str]:
    """Structural checks. Room membership is checked separately against Synapse."""
    if not isinstance(d, dict): return ["The definition must be a JSON object"]
    err = []
    if not str(d.get("name", "")).strip(): err.append("Give the workflow a name")
    t = d.get("trigger") or {}
    if t.get("type") not in TRIGGERS: err.append(f"Unknown trigger type {t.get('type')!r}; use one of {sorted(TRIGGERS)}")
    if t.get("type") in ("message", "form") and not str(t.get("room", "")).startswith("!"): err.append("A message trigger needs a chat")
    if t.get("type") == "schedule" and not re.fullmatch(r"(\S+\s+){4}\S+", str(t.get("cron", ""))): err.append("A schedule needs a 5-field cron, e.g. '0 9 * * 1'")
    steps = d.get("steps")
    if not isinstance(steps, list) or not steps: return err + ["Add at least one step"]
    if len(steps) > MAX_STEPS: err.append(f"At most {MAX_STEPS} steps")
    ids = [s.get("id") for s in steps if isinstance(s, dict)]
    if len(ids) != len(steps) or len(set(ids)) != len(ids) or not all(isinstance(i, str) and i for i in ids):
        return err + ["Every step needs a unique id"]
    for s in steps:
        k, sid = s.get("type"), s["id"]
        if k not in STEPS: err.append(f"{sid}: unknown step type {k!r}"); continue
        if k in NOT_YET: err.append(f"{sid}: {k} steps are not available yet ({NOT_YET[k]})"); continue
        if k == "post" and not (str(s.get("room", "")).startswith("!") and s.get("text")): err.append(f"{sid}: a post needs a chat and text")
        if k == "ask_form" and not (s.get("to") and isinstance(s.get("fields"), list) and s["fields"]): err.append(f"{sid}: a form needs a person and fields")
        if k == "approval":
            ap = s.get("approvers")
            if not (isinstance(ap, list) and ap): err.append(f"{sid}: an approval needs approvers")
            elif any(str(a).startswith("role:") for a in ap): err.append(f"{sid}: roles are not supported yet; name the approvers")
        if k == "condition":
            if not parse_cond(str(s.get("if", ""))): err.append(f"{sid}: condition must look like '$s1.amount > 500000'")
            for br in ("then", "else"):
                if s.get(br) and s[br] not in ids and s[br] != "end": err.append(f"{sid}: {br} goes to unknown step {s[br]!r}")
        if s.get("next") and s["next"] not in ids and s["next"] != "end": err.append(f"{sid}: next goes to unknown step {s['next']!r}")
        if k == "wait" and not (isinstance(s.get("minutes"), (int, float)) and 0 < s["minutes"] <= MAX_RUN_DAYS * 1440): err.append(f"{sid}: wait needs minutes (1 to {MAX_RUN_DAYS * 1440})")
        if k == "http" and not str(s.get("url", "")).startswith("https://"): err.append(f"{sid}: http needs an https:// url")
        if k == "create_task" and not str(s.get("title", "")).strip(): err.append(f"{sid}: a task needs a title")
    if err: return err
    g = {k: [x for x in v if x != "end"] for k, v in _edges(steps).items()}
    seen, todo = set(), [ids[0]]
    while todo:
        n = todo.pop()
        if n not in seen: seen.add(n); todo += g.get(n, [])
    for sid in ids:
        if sid not in seen: err.append(f"{sid}: can never be reached")
    kind = {s["id"]: s["type"] for s in steps}
    def cyc(n, path):                                     # any cycle with no wait step in it is rejected
        for m in g.get(n, []):
            if m in path:
                loop = path[path.index(m):]
                if not any(kind[x] == "wait" for x in loop): return loop
            else:
                r = cyc(m, path + [m])
                if r: return r
        return None
    loop = cyc(ids[0], [ids[0]])
    if loop: err.append(f"Steps {' → '.join(loop + [loop[0]])} loop without a wait")
    return err

def parse_cond(c: str):
    for op in OPS:
        if op in c:
            a, b = c.split(op, 1); a, b = a.strip(), b.strip()
            if a.startswith("$") and b: return a, op.strip(), b
    return None

def ref(path: str, ctx: dict):
    cur: Any = ctx
    for p in path.lstrip("$").split("."):
        cur = cur.get(p) if isinstance(cur, dict) else None
    return cur

def lit(v: str):
    v = v.strip()
    if v.startswith(("'", '"')) and v.endswith(v[0]): return v[1:-1]
    try: return float(v)
    except ValueError: return v

def evaluate(c: str, ctx: dict) -> bool:
    p = parse_cond(c)
    if not p: return False
    a, op, b = ref(p[0], ctx), p[1], (ref(p[2], ctx) if p[2].startswith("$") else lit(p[2]))
    try:
        if op == "contains": return str(b).lower() in str(a).lower()
        if op in ("==", "!="): r = str(a) == str(b) if not isinstance(b, float) else float(a) == b; return r if op == "==" else not r
        a, b = float(a), float(b)
        return {">": a > b, "<": a < b, ">=": a >= b, "<=": a <= b}[op]
    except (TypeError, ValueError): return False

def render(text: str, ctx: dict) -> str:
    return re.sub(r"\{\{\s*([\w.]+)\s*\}\}", lambda m: str(ref(m.group(1), ctx) if ref(m.group(1), ctx) is not None else ""), str(text))

def dry_run(d: dict, sample: dict) -> list[dict]:
    """Walk the flow with sample data. Nothing is sent: each step only says what it would do."""
    steps = {s["id"]: s for s in d["steps"]}; order = [s["id"] for s in d["steps"]]; g = _edges(d["steps"])
    ctx = {"trigger": sample.get("trigger", {}), **{k: v for k, v in sample.items() if k != "trigger"}}
    out, cur, n = [], order[0], 0
    while cur and cur != "end" and n < 200:
        s = steps[cur]; n += 1; k = s["type"]
        if k == "condition":
            ok = evaluate(s["if"], ctx); nxt = s.get("then") if ok else s.get("else")
            out.append({"step": cur, "type": k, "would": f"{s['if']} is {'true' if ok else 'false'}"}); cur = nxt or None; continue
        would = {"post": lambda: f"post to {s['room']}: {render(s['text'], ctx)}",
                 "ask_form": lambda: f"ask {render(s['to'], ctx)} for {', '.join(s['fields'])}",
                 "approval": lambda: f"ask {', '.join(render(a, ctx) for a in s['approvers'])} to approve" + (f" (timeout {s['timeout_h']} h)" if s.get('timeout_h') else ""),
                 "wait": lambda: f"wait {s['minutes']} minutes",
                 "http": lambda: f"call {s['url']}",
                 "run_agent": lambda: f"ask Amer: {render(s.get('prompt', ''), ctx)}",
                 "create_task": lambda: f"create task: {render(s.get('title', ''), ctx)}",
                 "call_connector": lambda: f"call connector {s.get('connector', '?')}"}[k]()
        out.append({"step": cur, "type": k, "would": would})
        nx = g.get(cur, []); cur = nx[0] if nx else None
    return out

# ---------------- storage (PostgreSQL; in memory for tests) ----------------
class Mem:
    def __init__(self): self.wf: dict[str, list[dict]] = {}; self.runs: dict[str, dict] = {}; self.hosts: set[str] = set(); self.idem: dict[str, str] = {}
    async def save(self, w): self.wf.setdefault(w["id"], []).append(w)
    async def versions(self, wid): return self.wf.get(wid, [])
    async def latest_all(self, owner): return [v[-1] for v in self.wf.values() if v[-1]["owner"] == owner]
    async def set_enabled(self, wid, on): self.wf[wid][-1]["enabled"] = on
    async def add_run(self, r): self.runs[r["id"]] = r
    async def run(self, rid): return self.runs.get(rid)
    async def update_run(self, rid, **k): self.runs[rid].update(k)
    async def runs_of(self, wid, n=50): return sorted([r for r in self.runs.values() if r["workflow_id"] == wid], key=lambda r: -r["started_at"])[:n]
    async def runs_today(self, wid): return sum(r["workflow_id"] == wid and r["started_at"] > time.time() - 86400 for r in self.runs.values())
    async def host_ok(self, h): return h in self.hosts
    async def set_host(self, h, on): (self.hosts.add if on else self.hosts.discard)(h)
    async def list_hosts(self): return sorted(self.hosts)

class Pg(Mem):
    async def _q(self, sql, *a, one=False):
        async with db.pool.connection() as c:
            cur = await c.execute(sql, a)
            if cur.description is None: return None
            rows = await cur.fetchall()
            cols = [d.name for d in cur.description]
            rows = [dict(zip(cols, r)) for r in rows]
            return rows[0] if one and rows else (None if one else rows)
    @staticmethod
    def _w(r):
        if r is None: return None
        return {**r, "definition": r["definition"] if isinstance(r["definition"], dict) else json.loads(r["definition"]),
                "created_at": r["created_at"].timestamp() if hasattr(r["created_at"], "timestamp") else r["created_at"]}
    @staticmethod
    def _r(r):
        if r is None: return None
        f = lambda v: v.timestamp() if hasattr(v, "timestamp") else v
        return {**r, "started_at": f(r["started_at"]), "ended_at": f(r["ended_at"]),
                "step_results": r["step_results"] if isinstance(r["step_results"], (dict, list)) else json.loads(r["step_results"] or "{}"),
                "trigger": r["trigger"] if isinstance(r["trigger"], dict) else json.loads(r["trigger"] or "{}")}
    async def save(self, w):
        await self._q("INSERT INTO workflows (id, version, owner, name, definition, enabled, created_at) VALUES (%s,%s,%s,%s,%s,%s,to_timestamp(%s))",
                      w["id"], w["version"], w["owner"], w["name"], json.dumps(w["definition"]), w["enabled"], w["created_at"])
    async def versions(self, wid): return [self._w(r) for r in await self._q("SELECT * FROM workflows WHERE id=%s ORDER BY version", wid)]
    async def latest_all(self, owner):
        return [self._w(r) for r in await self._q("SELECT DISTINCT ON (id) * FROM workflows WHERE owner=%s ORDER BY id, version DESC", owner)]
    async def set_enabled(self, wid, on): await self._q("UPDATE workflows SET enabled=%s WHERE id=%s AND version=(SELECT max(version) FROM workflows WHERE id=%s)", on, wid, wid)
    async def add_run(self, r):
        await self._q("INSERT INTO workflow_runs (id, workflow_id, version, owner, status, trigger, step_results, started_at, idem) VALUES (%s,%s,%s,%s,%s,%s,%s,to_timestamp(%s),%s)",
                      r["id"], r["workflow_id"], r["version"], r["owner"], r["status"], json.dumps(r["trigger"]), json.dumps(r["step_results"]), r["started_at"], r.get("idem"))
    async def run(self, rid): return self._r(await self._q("SELECT * FROM workflow_runs WHERE id=%s", rid, one=True))
    async def run_by_idem(self, wid, key): return self._r(await self._q("SELECT * FROM workflow_runs WHERE workflow_id=%s AND idem=%s AND started_at > now() - interval '24 hours'", wid, key, one=True))
    async def update_run(self, rid, **k):
        for col, v in k.items():
            if col == "ended_at": await self._q("UPDATE workflow_runs SET ended_at=to_timestamp(%s) WHERE id=%s", v, rid)
            elif col == "step_results": await self._q("UPDATE workflow_runs SET step_results=%s WHERE id=%s", json.dumps(v), rid)
            elif col == "status": await self._q("UPDATE workflow_runs SET status=%s WHERE id=%s", v, rid)
    async def runs_of(self, wid, n=50): return [self._r(r) for r in await self._q("SELECT * FROM workflow_runs WHERE workflow_id=%s ORDER BY started_at DESC LIMIT %s", wid, n)]
    async def runs_today(self, wid): return (await self._q("SELECT count(*) AS n FROM workflow_runs WHERE workflow_id=%s AND started_at > now() - interval '1 day'", wid, one=True))["n"]
    async def host_ok(self, h): return bool(await self._q("SELECT 1 AS x FROM workflow_hosts WHERE host=%s", h, one=True))
    async def set_host(self, h, on):
        await self._q("INSERT INTO workflow_hosts (host) VALUES (%s) ON CONFLICT DO NOTHING" if on else "DELETE FROM workflow_hosts WHERE host=%s", h)
    async def list_hosts(self): return [r["host"] for r in await self._q("SELECT host FROM workflow_hosts ORDER BY host")]

_mem = Mem()
def store(): return Pg() if db.pool is not None else _mem

async def _ops(run_id: str, typ: str, **data):
    """Each step also appears live in Agent Ops (project = the run)."""
    try:
        from .agentops import store as S
        await S.store().append(S.Event(typ, f"wf-{run_id}", "workflow", None, data))
    except Exception: pass

async def _owned(wid: str, user: dict) -> list[dict]:
    v = await store().versions(wid)
    if not v: raise HTTPException(404, "No such workflow")
    if v[-1]["owner"] != user["user_id"]: raise HTTPException(403, "Only the owner can do this")
    return v

async def _check_rooms(user: dict, d: dict):
    for r in rooms_of(d):
        try: await auth.assert_room_member(user, r)
        except HTTPException: raise HTTPException(403, f"You are not a member of {r}, so the workflow cannot use it")

# ---------------- API ----------------
class Draft(BaseModel):
    text: str = Field(min_length=5, max_length=2000)
    rooms: list[dict] = []                    # [{room_id, name}] the user's chats, so the agent can name real ones

DRAFT_PROMPT = """Turn the user's description into an Amer Teams workflow. Reply ONLY with JSON:
{"definition": {...}, "assumptions": [str]}
definition = {"name": str, "trigger": {...}, "steps": [...]}.
Trigger types: message {"type":"message","room":ROOM_ID,"match":{"keywords":[str],"has_file":bool}}, schedule {"type":"schedule","cron":"m h dom mon dow"}, manual {"type":"manual"}.
Step types (each has a unique "id" like "s1"):
 post {"type":"post","room":ROOM_ID,"text":"... {{s1.field}} ..."}
 ask_form {"type":"ask_form","to":"$trigger.sender" or USER_ID,"fields":[str],"room":ROOM_ID (optional; default the trigger chat)}
 approval {"type":"approval","approvers":[USER_ID or "$trigger.sender"],"timeout_h":int,"room":ROOM_ID (optional)}
 condition {"type":"condition","if":"$s1.field > 500000","then":STEP_ID,"else":STEP_ID}
 wait {"type":"wait","minutes":int}
 run_agent {"type":"run_agent","prompt":str}
 create_task {"type":"create_task","title":str,"assignee":USER_ID or "$trigger.sender","due_days":int,"room":ROOM_ID (optional)}
Results: a form gives $sN.<field>; an approval gives $sN.decision ("approved"/"rejected") and $sN.by; run_agent gives $sN.answer.
Steps run in order unless a condition branches; use "next":"end" to stop. Use ROOM_IDs only from the list given.
List every guess you made in assumptions (e.g. who approves). British English."""

@router.post("/v1/workflows/draft")
async def draft(req: Draft, user=Depends(auth.matrix_user)):
    rooms = "\n".join(f"{r.get('room_id')} = {r.get('name')}" for r in req.rooms[:100])
    res = await agents.run(f"{DRAFT_PROMPT}\nDescription: {req.text}", f"The user's chats:\n{rooms}", [], "assist")
    await db.audit(user["user_id"], "workflow.draft", f"status={'error' if res.get('error') else 'ok'}")
    if res.get("error") or res.get("blocked"):
        nokey = "ANTHROPIC_API_KEY is not set" in res["answer"]
        raise HTTPException(503, "AI drafting is not set up on this server: build the workflow step by step instead" if nokey else res["answer"])
    m = re.search(r"\{.*\}", res["answer"], re.S)
    try: j = json.loads(m.group(0)) if m else {}
    except ValueError: j = {}
    d = j.get("definition") if isinstance(j.get("definition"), dict) else None
    if not d: raise HTTPException(502, "The workflow agent did not return a usable definition. Try rephrasing.")
    return {"definition": d, "assumptions": [str(a) for a in j.get("assumptions", [])][:10], "errors": validate(d)}

class Save(BaseModel):
    definition: dict
    id: str | None = None                     # set to save a new version of an existing workflow
    enabled: bool = False

@router.post("/v1/workflows")
async def save(req: Save, user=Depends(auth.matrix_user)):
    errs = validate(req.definition)
    if errs: raise HTTPException(422, {"errors": errs})
    await _check_rooms(user, req.definition)
    if req.id:
        v = await _owned(req.id, user); wid, ver = req.id, v[-1]["version"] + 1
    else:
        wid, ver = "wf_" + secrets.token_hex(6), 1
    w = {"id": wid, "version": ver, "owner": user["user_id"], "name": req.definition["name"], "definition": req.definition,
         "enabled": req.enabled, "created_at": time.time()}
    await store().save(w)
    await db.audit(user["user_id"], "workflow.save", f"{wid} v{ver} steps={len(req.definition['steps'])}")
    return w

@router.get("/v1/workflows")
async def mine(user=Depends(auth.matrix_user)): return await store().latest_all(user["user_id"])

@router.get("/v1/workflows/{wid}")
async def one(wid: str, user=Depends(auth.matrix_user)):
    v = await _owned(wid, user); return {**v[-1], "versions": [x["version"] for x in v]}

class Enable(BaseModel): enabled: bool
@router.post("/v1/workflows/{wid}/enable")
async def enable(wid: str, req: Enable, user=Depends(auth.matrix_user)):
    v = await _owned(wid, user)
    if req.enabled: await _check_rooms(user, v[-1]["definition"])           # still a member of every room?
    await store().set_enabled(wid, req.enabled)
    await db.audit(user["user_id"], "workflow.enable" if req.enabled else "workflow.disable", wid)
    return {"id": wid, "enabled": req.enabled}

class DryRun(BaseModel):
    definition: dict | None = None
    sample: dict = {}
@router.post("/v1/workflows/dry-run")
async def dry(req: DryRun, user=Depends(auth.matrix_user)):
    errs = validate(req.definition)
    if errs: raise HTTPException(422, {"errors": errs})
    return {"steps": dry_run(req.definition, req.sample), "sent": 0}

class StartRun(BaseModel):
    trigger: dict = {}                       # metadata only: type, room, event id, sender
@router.post("/v1/workflows/{wid}/runs")
async def start_run(wid: str, req: StartRun, user=Depends(auth.matrix_user), idempotency_key: str = Header("")):
    v = await _owned(wid, user); w = v[-1]
    if not w["enabled"] and req.trigger.get("type") != "manual": raise HTTPException(409, "The workflow is switched off")
    s = store()
    if idempotency_key and isinstance(s, Pg):
        prev = await s.run_by_idem(wid, idempotency_key)
        if prev: return prev
    elif idempotency_key and (wid, idempotency_key) in {(r["workflow_id"], r.get("idem")) for r in _mem.runs.values()}:
        return next(r for r in _mem.runs.values() if r["workflow_id"] == wid and r.get("idem") == idempotency_key)
    if await s.runs_today(wid) >= MAX_RUNS_DAY: raise HTTPException(429, f"This workflow has reached {MAX_RUNS_DAY} runs today")
    await _check_rooms(user, w["definition"])
    r = {"id": "run_" + secrets.token_hex(6), "workflow_id": wid, "version": w["version"], "owner": user["user_id"], "status": "running",
         "trigger": {k: req.trigger.get(k) for k in ("type", "room", "event_id", "sender", "device")}, "step_results": {}, "started_at": time.time(),
         "ended_at": None, "idem": idempotency_key or None}
    await s.add_run(r)
    await db.audit(user["user_id"], "workflow.run", f"{wid} v{w['version']} {r['id']}")
    await _ops(r["id"], "project.started", name=w["name"], workflow=wid, version=w["version"])
    return {**r, "definition": w["definition"]}                          # the version is pinned for this run

class StepReport(BaseModel):
    step_id: str
    status: str = Field(pattern="^(running|waiting|succeeded|failed|skipped)$")
    attempt: int = 1
    fields: list[str] = []                   # names of values produced; the values stay on the device
    error: str = Field(default="", max_length=300)
@router.post("/v1/workflows/runs/{rid}/steps")
async def report(rid: str, req: StepReport, user=Depends(auth.matrix_user)):
    s = store(); r = await s.run(rid)
    if not r or r["owner"] != user["user_id"]: raise HTTPException(404, "No such run")
    if r["status"] != "running": raise HTTPException(409, f"Run is {r['status']}")
    res = dict(r["step_results"]); res[req.step_id] = {"status": req.status, "attempt": req.attempt, "fields": req.fields, "error": req.error, "at": time.time()}
    await s.update_run(rid, step_results=res)
    await db.audit(user["user_id"], f"workflow.step.{req.status}", f"{rid} {req.step_id}")
    await _ops(rid, "tool.failed" if req.status == "failed" else "tool.finished" if req.status in ("succeeded", "skipped") else "tool.started",
               tool=req.step_id, status=req.status, attempt=req.attempt)
    return {"ok": True}

class Finish(BaseModel): status: str = Field(pattern="^(succeeded|failed|cancelled|timed_out)$"); error: str = ""
@router.post("/v1/workflows/runs/{rid}/finish")
async def finish(rid: str, req: Finish, user=Depends(auth.matrix_user)):
    s = store(); r = await s.run(rid)
    if not r or r["owner"] != user["user_id"]: raise HTTPException(404, "No such run")
    if r["status"] == "running":
        await s.update_run(rid, status=req.status, ended_at=time.time())
        await db.audit(user["user_id"], f"workflow.run.{req.status}", rid)
        await _ops(rid, "project.finished", ok=req.status == "succeeded", error=req.error[:200])
    return {"ok": True}

@router.get("/v1/workflows/{wid}/runs")
async def runs(wid: str, user=Depends(auth.matrix_user)):
    await _owned(wid, user); return await store().runs_of(wid)

class Http(BaseModel): step_id: str; body: dict = {}
@router.post("/v1/workflows/runs/{rid}/http")
async def http_step(rid: str, req: Http, user=Depends(auth.matrix_user)):
    """http steps run here, only to hosts an administrator approved."""
    s = store(); r = await s.run(rid)
    if not r or r["owner"] != user["user_id"] or r["status"] != "running": raise HTTPException(404, "No such running run")
    w = next(x for x in await s.versions(r["workflow_id"]) if x["version"] == r["version"])
    step = next((x for x in w["definition"]["steps"] if x["id"] == req.step_id and x["type"] == "http"), None)
    if not step: raise HTTPException(400, "Not an http step of this workflow")
    host = urllib.parse.urlparse(step["url"]).hostname or ""
    if not await s.host_ok(host): raise HTTPException(403, f"{host} is not approved by an administrator for workflows")
    async with httpx.AsyncClient(timeout=10) as c:
        resp = await c.post(step["url"], json=req.body)
    await db.audit(user["user_id"], "workflow.http", f"{rid} {req.step_id} {host} {resp.status_code}")
    return {"status": resp.status_code}

class Host(BaseModel): host: str = Field(pattern=r"^[a-z0-9.-]+$"); approved: bool = True
@router.post("/v1/admin/workflow-hosts")
async def set_host(req: Host, user=Depends(require_admin)):
    await store().set_host(req.host, req.approved); await db.audit(user["user_id"], "workflow.host", f"{req.host}={req.approved}")
    return {"hosts": await store().list_hosts()}
@router.get("/v1/admin/workflow-hosts")
async def hosts(user=Depends(require_admin)): return await store().list_hosts()
