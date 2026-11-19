# Agent Ops

A team of AI agents that delivers a software project, and an **Agent Ops** tab in the app that shows
what every agent is doing while it works.

## The team
| Agent | Role | Model |
|---|---|---|
| Amer (orchestrator) | Publishes the plan, delegates each phase, sends defects back, reports honestly | server default |
| analyst | `docs/REQUIREMENTS.md` with testable acceptance criteria | sonnet |
| architect | `docs/ARCHITECTURE.md`: stack, modules, interfaces, build order | opus |
| developer | Implements and runs the code; fixes reported defects | sonnet |
| tester | Tests per acceptance criterion, `docs/TEST_REPORT.md` | sonnet |
| reviewer | `docs/REVIEW.md`, BLOCKER / MAJOR / MINOR | opus |
| documenter | `README.md` for what actually exists | haiku |

Change the team in `services/orchestrator/app/agentops/team.py`. The app adds new roles automatically.

## Why the screen shows the truth
The screen draws only events the orchestrator records from the Claude Agent SDK:

| On screen | Source |
|---|---|
| Agent working / done | `SubagentStart` / `SubagentStop` hooks |
| Handoff pulses | `PreToolUse` on the `Agent` tool (the orchestrator delegating) |
| Live tool log, files | `PreToolUse` / `PostToolUse` hooks, with duration |
| Failures (red) | `PostToolUseFailure` hook, with the real error text |
| Plan and progress | The orchestrator's own `TodoWrite` calls |
| Tokens per agent | `TaskProgressMessage.usage`, orchestrator `AssistantMessage.usage` |
| Cost, turns | Final `ResultMessage` (exact; "—" until the project finishes) |

The replay button plays `app/agentops/samples/demo_run.jsonl`, an illustrative recording, as a new project
marked **REPLAY · SAMPLE**. Only a project actually running shows **LIVE**. A replay never reports a cost.

## API (`/api` prefix through Caddy)
| Method | Path | Who |
|---|---|---|
| GET | `/v1/agentops/team` | any user |
| GET | `/v1/agentops/projects` | any user |
| POST | `/v1/agentops/projects` `{prompt, name?}` | administrators |
| POST | `/v1/agentops/projects/{id}/stop` | administrators |
| POST | `/v1/agentops/replay` `{speed}` | administrators |
| GET | `/v1/agentops/events?after=&project_id=` | any user |
| GET | `/v1/agentops/stream?after=` | any user, Server-Sent Events |

Events are stored in PostgreSQL (`agentops_events`, migration 004), so every replica serves the same stream
and the history survives restarts. Clients resume with `after=<last seq>`. Start and stop are written to the
tamper-evident audit log.

## Running
- Set `ANTHROPIC_API_KEY` in `deploy/.env` (already used by the AI engine). Starting a project returns 503 without it.
- Project files are written to the `agentops` volume (`/data/agentops/<name>-<id>`).
- `AGENTOPS_MAX_TURNS` (default 200) caps one project.
- The developer and tester agents run shell commands inside the orchestrator container. Keep this
  feature on a server where that is acceptable; a container per project is the next hardening step.

## Limits in this release
- A project runs inside the replica that started it. Stop works only on that replica; after a full
  restart an unfinished project is marked `interrupted` (after 6 hours).
- Kubernetes: add a volume for `/data/agentops` to `deploy/k8s/50-orchestrator.yaml` before enabling it there.
