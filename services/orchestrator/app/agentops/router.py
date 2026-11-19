"""Agent Ops API: start agent-team projects and stream what every agent is doing.

  GET  /v1/agentops/team                     team roster
  GET  /v1/agentops/projects                 recent projects and their status
  POST /v1/agentops/projects                 start a project              (administrators)
  POST /v1/agentops/projects/{id}/stop       stop a running project       (administrators)
  POST /v1/agentops/replay                   replay the sample recording  (administrators)
  GET  /v1/agentops/events?after=&project_id=   event history
  GET  /v1/agentops/stream?after=&project_id=   live Server-Sent Events
"""
from __future__ import annotations

import asyncio
import json
import os
import re
import time
import uuid
from pathlib import Path

from fastapi import APIRouter, Depends, HTTPException, Request
from fastapi.responses import StreamingResponse
from pydantic import BaseModel, Field

from .. import auth, config, db
from ..admin import require_admin
from . import store as S
from .runner import ProjectRun
from .store import Event
from .team import TEAM

router = APIRouter(prefix="/v1/agentops")
WORKDIR = Path(os.getenv("AGENTOPS_DIR", "/data/agentops"))
SAMPLE = Path(__file__).resolve().parent / "samples" / "demo_run.jsonl"
RUNS: dict[str, asyncio.Task] = {}          # projects running in this replica


class NewProject(BaseModel):
    prompt: str = Field(min_length=10, max_length=8000)
    name: str | None = Field(default=None, max_length=80)


class ReplayReq(BaseModel):
    speed: float = Field(3.0, ge=0.5, le=50)


@router.get("/team")
async def team(user=Depends(auth.matrix_user)):
    return [{"id": "orchestrator", "name": "Amer", "description": "Plans, delegates and verifies", "model": "default"}] + \
           [{"id": k, "name": k.capitalize(), "description": a.description, "model": a.model} for k, a in TEAM.items()]


@router.get("/projects")
async def projects(user=Depends(auth.matrix_user)):
    out = await S.store().list_projects()
    for p in out:
        p["running_here"] = p["project_id"] in RUNS and not RUNS[p["project_id"]].done()
    return out


@router.post("/projects")
async def start(req: NewProject, user=Depends(require_admin)):
    if not config.ANTHROPIC_API_KEY:
        raise HTTPException(503, "ANTHROPIC_API_KEY is not configured on the server")
    name = (req.name or req.prompt).strip()[:80]
    slug = re.sub(r"[^a-z0-9]+", "-", name.lower()).strip("-")[:40] or "project"
    pid = f"p-{uuid.uuid4().hex[:8]}"
    run = ProjectRun(req.prompt, WORKDIR / f"{slug}-{pid[2:]}", name, user["user_id"], pid)
    await run.start()
    RUNS[pid] = asyncio.create_task(run.run())
    if db.pool is not None:
        await db.audit(user["user_id"], "agentops.start", f"{pid}:{name}")
    return {"project_id": pid, "workdir": str(run.workdir)}


@router.post("/projects/{pid}/stop")
async def stop(pid: str, user=Depends(require_admin)):
    task = RUNS.get(pid)
    if not task or task.done():
        raise HTTPException(404, "Project is not running on this server")
    task.cancel()
    if db.pool is not None:
        await db.audit(user["user_id"], "agentops.stop", pid)
    return {"ok": True}


@router.post("/replay")
async def replay(req: ReplayReq, user=Depends(require_admin)):
    """Plays the sample recording as a new project marked replay, so the screen can be previewed
    without running agents. It is labelled REPLAY in the app, never LIVE."""
    lines = [json.loads(l) for l in SAMPLE.read_text(encoding="utf-8").splitlines() if l.strip()]
    first = lines[0]["data"]
    pid = f"replay-{uuid.uuid4().hex[:6]}"
    await S.store().create_project({"project_id": pid, "name": first.get("name", "Sample replay"),
                                    "prompt": first.get("prompt", ""), "replay": True,
                                    "created_by": user["user_id"]})

    async def play():
        t0, start_at = lines[0]["ts"], time.monotonic()
        for d in lines:
            wait = (d["ts"] - t0) / req.speed - (time.monotonic() - start_at)
            if wait > 0:
                await asyncio.sleep(wait)
            data = dict(d.get("data") or {})
            if d["type"] == S.PROJECT_STARTED:
                data["replay"] = True
            await S.store().append(Event(d["type"], pid, d.get("agent"), d.get("agent_id"), data))
            if d["type"] == S.PROJECT_FINISHED:
                await S.store().finish_project(pid, "done" if data.get("ok") else "failed", None)

    RUNS[pid] = asyncio.create_task(play())
    return {"project_id": pid, "replay": True}


@router.get("/events")
async def events(after: int = 0, project_id: str | None = None, user=Depends(auth.matrix_user)):
    return await S.store().since(after, project_id)


@router.get("/stream")
async def stream(request: Request, after: int = 0, project_id: str | None = None,
                 user=Depends(auth.matrix_user)):
    """Server-Sent Events. Reads the shared event table, so it works behind any replica."""
    async def gen():
        last, idle = after, 0.0
        yield "retry: 2000\n\n"
        while not await request.is_disconnected():
            batch = await S.store().since(last, project_id, limit=500)
            for e in batch:
                last = e["seq"]
                yield f"id: {last}\nevent: agentops\ndata: {json.dumps(e, ensure_ascii=False, default=str)}\n\n"
            if batch:
                idle = 0.0
                continue
            await asyncio.sleep(0.5)
            idle += 0.5
            if idle >= 15:                       # keep proxies from closing an idle stream
                idle = 0.0
                yield ": keep-alive\n\n"

    return StreamingResponse(gen(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-cache", "X-Accel-Buffering": "no"})
