"""Event model and storage for Agent Ops.

Events are written to PostgreSQL (agentops_events) so every orchestrator replica
serves the same stream and history survives restarts. Without a database pool
(unit tests, local scripts) an in-memory store with the same interface is used.
"""
from __future__ import annotations

import json
import time
import uuid
from dataclasses import asdict, dataclass, field
from typing import Any

# Event types: the contract the app's Agent Ops screen consumes
PROJECT_STARTED = "project.started"
PROJECT_FINISHED = "project.finished"
AGENT_STARTED = "agent.started"
AGENT_STOPPED = "agent.stopped"
AGENT_MESSAGE = "agent.message"
AGENT_USAGE = "agent.usage"
HANDOFF = "handoff"
TOOL_STARTED = "tool.started"
TOOL_FINISHED = "tool.finished"
TOOL_FAILED = "tool.failed"
TASKS_UPDATED = "tasks.updated"


@dataclass
class Event:
    type: str
    project_id: str
    agent: str | None = None
    agent_id: str | None = None
    data: dict[str, Any] = field(default_factory=dict)
    ts: float = field(default_factory=time.time)
    id: str = field(default_factory=lambda: uuid.uuid4().hex[:12])
    seq: int | None = None

    def as_dict(self) -> dict[str, Any]:
        return asdict(self)


class MemoryStore:
    def __init__(self):
        self.events: list[Event] = []
        self.projects: dict[str, dict] = {}

    async def create_project(self, p: dict) -> None:
        self.projects[p["project_id"]] = {**p, "status": "running", "started_at": time.time(),
                                          "finished_at": None, "cost_usd": None}

    async def finish_project(self, pid: str, status: str, cost: float | None) -> None:
        if pid in self.projects:
            self.projects[pid].update(status=status, cost_usd=cost, finished_at=time.time())

    async def append(self, ev: Event) -> Event:
        ev.seq = len(self.events) + 1
        self.events.append(ev)
        return ev

    async def since(self, after: int, project_id: str | None = None, limit: int = 1000) -> list[dict]:
        return [e.as_dict() for e in self.events
                if e.seq > after and (project_id is None or e.project_id == project_id)][:limit]

    async def list_projects(self, limit: int = 50) -> list[dict]:
        return sorted(self.projects.values(), key=lambda p: p["started_at"], reverse=True)[:limit]


class PgStore:
    def __init__(self, pool):
        self.pool = pool

    async def create_project(self, p: dict) -> None:
        async with self.pool.connection() as c:
            await c.execute(
                "INSERT INTO agentops_projects (project_id, name, prompt, workdir, replay, created_by) "
                "VALUES (%s,%s,%s,%s,%s,%s)",
                (p["project_id"], p["name"], p["prompt"], p.get("workdir"), p.get("replay", False), p["created_by"]))

    async def finish_project(self, pid: str, status: str, cost: float | None) -> None:
        async with self.pool.connection() as c:
            await c.execute("UPDATE agentops_projects SET status=%s, cost_usd=%s, finished_at=now() "
                            "WHERE project_id=%s", (status, cost, pid))

    async def append(self, ev: Event) -> Event:
        async with self.pool.connection() as c:
            row = await (await c.execute(
                "INSERT INTO agentops_events (id, ts, project_id, type, agent, agent_id, data) "
                "VALUES (%s,%s,%s,%s,%s,%s,%s) RETURNING seq",
                (ev.id, ev.ts, ev.project_id, ev.type, ev.agent, ev.agent_id,
                 json.dumps(ev.data, ensure_ascii=False, default=str)))).fetchone()
        ev.seq = row[0]
        return ev

    async def since(self, after: int, project_id: str | None = None, limit: int = 1000) -> list[dict]:
        q = "SELECT seq, id, ts, project_id, type, agent, agent_id, data FROM agentops_events WHERE seq > %s"
        args: list[Any] = [after]
        if project_id:
            q += " AND project_id = %s"
            args.append(project_id)
        q += " ORDER BY seq LIMIT %s"
        args.append(limit)
        async with self.pool.connection() as c:
            rows = await (await c.execute(q, args)).fetchall()
        return [{"seq": r[0], "id": r[1], "ts": r[2], "project_id": r[3], "type": r[4],
                 "agent": r[5], "agent_id": r[6], "data": r[7]} for r in rows]

    async def list_projects(self, limit: int = 50) -> list[dict]:
        async with self.pool.connection() as c:
            rows = await (await c.execute(
                "SELECT project_id, name, prompt, workdir, status, replay, created_by, cost_usd, "
                "extract(epoch from started_at), extract(epoch from finished_at) "
                "FROM agentops_projects ORDER BY started_at DESC LIMIT %s", (limit,))).fetchall()
        keys = ["project_id", "name", "prompt", "workdir", "status", "replay", "created_by",
                "cost_usd", "started_at", "finished_at"]
        return [dict(zip(keys, r)) for r in rows]

    async def mark_interrupted(self) -> None:
        """Runs live inside one process; after a full restart, unfinished ones cannot resume."""
        async with self.pool.connection() as c:
            await c.execute("UPDATE agentops_projects SET status='interrupted', finished_at=now() "
                            "WHERE status='running' AND started_at < now() - interval '6 hours'")


_store: MemoryStore | PgStore | None = None


def store():
    global _store
    if _store is None:
        from .. import db
        _store = PgStore(db.pool) if db.pool is not None else MemoryStore()
    return _store


def use(s) -> None:
    """Tests inject a store."""
    global _store
    _store = s
