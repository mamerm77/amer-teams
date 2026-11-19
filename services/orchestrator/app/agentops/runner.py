"""Runs one project with the agent team and turns Claude Agent SDK signals into events.

Truth sources (nothing is simulated):
  * SDK hooks        -> agent start/stop, every tool call, its duration and its error text
  * SDK message flow -> what each agent says, per-agent token and tool counters
  * ResultMessage    -> exact cost, duration, turns, success or failure
"""
from __future__ import annotations

import asyncio
import os
import time
import uuid
from pathlib import Path
from typing import Any

from . import store as S
from .store import Event
from .team import ORCHESTRATOR_PROMPT, TEAM

ORCH = "orchestrator"
DELEGATION_TOOLS = {"Agent", "Task"}
MAX_TURNS = int(os.getenv("AGENTOPS_MAX_TURNS", "200"))


def brief(tool: str, inp: dict[str, Any]) -> str:
    """One-line human summary of a tool call for the live log."""
    for k in ("file_path", "path", "pattern", "command", "description", "subagent_type"):
        if inp.get(k):
            return f"{tool} {str(inp[k])[:140]}"
    return tool


class ProjectRun:
    def __init__(self, prompt: str, workdir: Path, name: str, created_by: str,
                 project_id: str | None = None):
        self.prompt, self.workdir, self.name, self.created_by = prompt, workdir, name, created_by
        self.id = project_id or f"p-{uuid.uuid4().hex[:8]}"
        self.tooluse_to_role: dict[str, str] = {}
        self.tool_started: dict[str, float] = {}
        self.finished = False

    async def emit(self, type_: str, agent: str | None = None, agent_id: str | None = None, **data):
        await S.store().append(Event(type_, self.id, agent, agent_id, data))

    async def finish(self, ok: bool, cost: float | None = None, **data):
        if self.finished:
            return
        self.finished = True
        await self.emit(S.PROJECT_FINISHED, ORCH, ok=ok, cost_usd=cost, **data)
        await S.store().finish_project(self.id, "done" if ok else "failed", cost)

    # ---------- hooks: fire on real SDK lifecycle events ----------
    @staticmethod
    def role(inp: dict[str, Any]) -> str:
        return inp.get("agent_type") or ORCH

    async def on_pre_tool(self, inp, tool_use_id=None, ctx=None):
        role, tool, tin, tid = self.role(inp), inp["tool_name"], inp.get("tool_input") or {}, inp["tool_use_id"]
        self.tool_started[tid] = time.time()
        if tool in DELEGATION_TOOLS:
            target = tin.get("subagent_type", "general-purpose")
            self.tooluse_to_role[tid] = target
            await self.emit(S.HANDOFF, role, inp.get("agent_id"), to=target,
                            brief=str(tin.get("description") or tin.get("prompt", ""))[:300])
        if tool == "TodoWrite":
            await self.emit(S.TASKS_UPDATED, role, todos=tin.get("todos", []))
        await self.emit(S.TOOL_STARTED, role, inp.get("agent_id"), tool=tool, tool_use_id=tid,
                        summary=brief(tool, tin))
        return {}

    async def on_post_tool(self, inp, tool_use_id=None, ctx=None):
        tid = inp["tool_use_id"]
        dur = inp.get("duration_ms")
        if dur is None and tid in self.tool_started:
            dur = int((time.time() - self.tool_started[tid]) * 1000)
        await self.emit(S.TOOL_FINISHED, self.role(inp), inp.get("agent_id"),
                        tool=inp["tool_name"], tool_use_id=tid, duration_ms=dur)
        return {}

    async def on_tool_fail(self, inp, tool_use_id=None, ctx=None):
        await self.emit(S.TOOL_FAILED, self.role(inp), inp.get("agent_id"), tool=inp["tool_name"],
                        tool_use_id=inp["tool_use_id"], error=str(inp.get("error", ""))[:400],
                        duration_ms=inp.get("duration_ms"))
        return {}

    async def on_sub_start(self, inp, tool_use_id=None, ctx=None):
        await self.emit(S.AGENT_STARTED, inp["agent_type"], inp["agent_id"])
        return {}

    async def on_sub_stop(self, inp, tool_use_id=None, ctx=None):
        await self.emit(S.AGENT_STOPPED, inp["agent_type"], inp["agent_id"],
                        last_message=str(inp.get("last_assistant_message", ""))[:400])
        return {}

    # ---------- SDK message stream ----------
    async def on_message(self, msg) -> None:
        from claude_agent_sdk import AssistantMessage, ResultMessage, TextBlock
        try:
            from claude_agent_sdk import TaskProgressMessage
        except ImportError:  # older SDK
            TaskProgressMessage = None  # type: ignore[assignment]

        if isinstance(msg, AssistantMessage):
            role = self.tooluse_to_role.get(msg.parent_tool_use_id or "", ORCH) if msg.parent_tool_use_id else ORCH
            text = " ".join(b.text for b in msg.content if isinstance(b, TextBlock)).strip()
            if text:
                await self.emit(S.AGENT_MESSAGE, role, text=text[:600])
            if role == ORCH and msg.usage:
                u = msg.usage
                await self.emit(S.AGENT_USAGE, ORCH, delta=True, tokens=sum(int(u.get(k) or 0) for k in (
                    "input_tokens", "output_tokens", "cache_creation_input_tokens", "cache_read_input_tokens")))
        elif TaskProgressMessage is not None and isinstance(msg, TaskProgressMessage):
            role = self.tooluse_to_role.get(msg.tool_use_id or "", "general-purpose")
            await self.emit(S.AGENT_USAGE, role, delta=False, **dict(msg.usage))
        elif isinstance(msg, ResultMessage):
            await self.emit(S.AGENT_STOPPED, ORCH)
            await self.finish(not msg.is_error, msg.total_cost_usd, subtype=msg.subtype,
                              duration_ms=msg.duration_ms, turns=msg.num_turns,
                              summary=(msg.result or "")[:1500], errors=msg.errors)

    @staticmethod
    def sdk_env() -> dict[str, str]:
        from .. import config
        env = {}
        if config.ANTHROPIC_API_KEY:
            env["ANTHROPIC_API_KEY"] = config.ANTHROPIC_API_KEY
        if config.LLM_BASE_URL and config.LLM_BASE_URL != "https://api.anthropic.com":
            env["ANTHROPIC_BASE_URL"] = config.LLM_BASE_URL
        return env

    def options(self):
        from claude_agent_sdk import ClaudeAgentOptions, HookMatcher
        return ClaudeAgentOptions(
            system_prompt=ORCHESTRATOR_PROMPT,
            agents=TEAM,
            cwd=str(self.workdir),
            allowed_tools=["Agent", "Task", "TodoWrite", "Read", "Glob", "Grep", "Write", "Edit", "Bash"],
            permission_mode="acceptEdits",
            max_turns=MAX_TURNS,
            env=self.sdk_env(),
            hooks={
                "PreToolUse": [HookMatcher(hooks=[self.on_pre_tool])],
                "PostToolUse": [HookMatcher(hooks=[self.on_post_tool])],
                "PostToolUseFailure": [HookMatcher(hooks=[self.on_tool_fail])],
                "SubagentStart": [HookMatcher(hooks=[self.on_sub_start])],
                "SubagentStop": [HookMatcher(hooks=[self.on_sub_stop])],
            },
        )

    async def start(self, replay: bool = False) -> None:
        await S.store().create_project({"project_id": self.id, "name": self.name, "prompt": self.prompt,
                                        "workdir": str(self.workdir), "replay": replay,
                                        "created_by": self.created_by})
        await self.emit(S.PROJECT_STARTED, ORCH, name=self.name, prompt=self.prompt,
                        team=list(TEAM), replay=replay, created_by=self.created_by)

    async def run(self) -> None:
        from claude_agent_sdk import query
        self.workdir.mkdir(parents=True, exist_ok=True)
        await self.emit(S.AGENT_STARTED, ORCH)
        try:
            async for msg in query(prompt=self.prompt, options=self.options()):
                await self.on_message(msg)
            if not self.finished:
                await self.finish(False, error="Agent session ended without a result")
        except asyncio.CancelledError:
            await self.finish(False, error="Stopped by an administrator")
            raise
        except Exception as exc:  # real failures are shown on the dashboard
            await self.finish(False, error=repr(exc)[:500])
