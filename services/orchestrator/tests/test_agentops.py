"""Agent Ops: hook-to-event translation, replay labelling and the API, without a database or LLM."""
import asyncio
import time
from pathlib import Path

from fastapi.testclient import TestClient

from app import auth
from app.admin import require_admin
from app.agentops import store as S
from app.agentops.runner import ProjectRun


def fresh_store():
    s = S.MemoryStore()
    S.use(s)
    return s


def test_hooks_become_events():
    s = fresh_store()
    run = ProjectRun("Build a calculator with tests", Path("/tmp/x"), "calc", "@admin:t", "p-test")

    async def go():
        await run.start()
        await run.on_pre_tool({"tool_name": "TodoWrite", "tool_use_id": "t0",
                               "tool_input": {"todos": [{"content": "Requirements", "status": "in_progress"}]}})
        await run.on_pre_tool({"tool_name": "Agent", "tool_use_id": "t1",
                               "tool_input": {"subagent_type": "developer", "description": "Implement"}})
        await run.on_sub_start({"agent_type": "developer", "agent_id": "a1"})
        await run.on_pre_tool({"tool_name": "Write", "tool_use_id": "t2", "agent_type": "developer",
                               "agent_id": "a1", "tool_input": {"file_path": "calc.py"}})
        await run.on_post_tool({"tool_name": "Write", "tool_use_id": "t2", "agent_type": "developer",
                                "agent_id": "a1", "duration_ms": 12})
        await run.on_tool_fail({"tool_name": "Bash", "tool_use_id": "t3", "agent_type": "developer",
                                "agent_id": "a1", "error": "1 failed"})
        await run.on_sub_stop({"agent_type": "developer", "agent_id": "a1"})
        await run.finish(False, error="test")
        await run.finish(True)                      # second finish is ignored
    asyncio.run(go())

    types = [(e.type, e.agent) for e in s.events]
    assert ("handoff", "orchestrator") in types
    assert ("tasks.updated", "orchestrator") in types
    assert ("agent.started", "developer") in types
    assert ("tool.started", "developer") in types
    assert ("tool.failed", "developer") in types
    assert [e.type for e in s.events].count("project.finished") == 1
    started = next(e for e in s.events if e.type == "tool.started" and e.agent == "developer")
    assert started.data["summary"] == "Write calc.py"
    assert run.tooluse_to_role["t1"] == "developer"
    assert s.projects["p-test"]["status"] == "failed"
    assert [e.seq for e in s.events] == list(range(1, len(s.events) + 1))


def _client():
    from app.main import app
    user = {"user_id": "@admin:t", "token": "x"}
    app.dependency_overrides[auth.matrix_user] = lambda: user
    app.dependency_overrides[require_admin] = lambda: user
    app.router.on_startup.clear()          # no PostgreSQL / LiveKit in unit tests
    return app


def test_replay_is_labelled_and_streams_in_order():
    s = fresh_store()
    app = _client()
    with TestClient(app) as c:
        r = c.post("/v1/agentops/replay", json={"speed": 50})
        assert r.status_code == 200
        pid = r.json()["project_id"]
        deadline = time.time() + 20
        while time.time() < deadline and s.projects[pid]["status"] == "running":
            time.sleep(0.2)
        ev = c.get("/v1/agentops/events", params={"project_id": pid}).json()
        assert ev[0]["type"] == "project.started" and ev[0]["data"]["replay"] is True
        assert ev[-1]["type"] == "project.finished"
        assert ev[-1]["data"].get("cost_usd") is None        # a replay never reports a cost
        seqs = [e["seq"] for e in ev]
        assert seqs == sorted(seqs)
        later = c.get("/v1/agentops/events", params={"project_id": pid, "after": seqs[-5]}).json()
        assert len(later) == 4
        assert c.get("/v1/agentops/projects").json()[0]["project_id"] == pid
    app.dependency_overrides.clear()


def test_start_requires_api_key(monkeypatch):
    fresh_store()
    from app import config
    monkeypatch.setattr(config, "ANTHROPIC_API_KEY", "")
    app = _client()
    with TestClient(app) as c:
        r = c.post("/v1/agentops/projects", json={"prompt": "Build something useful please"})
        assert r.status_code == 503
    app.dependency_overrides.clear()
