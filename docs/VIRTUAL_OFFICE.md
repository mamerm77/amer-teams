# My agent office

Apps → **My agent office** (also on the Amer page). Your own staff of AI agents, at their desks in a virtual office. You can view it in **3D** (isometric rooms with walls, desks and glowing screens) or **2D** (flat floor plan). Zoom and pan; filter by department.

## The team
| Agent | Role | Room |
|---|---|---|
| Amer | Chief of Staff: receives your requests, plans, delegates, merges | Command centre |
| Layla | Inbox and messages (drafts only, never sends) | Comms room |
| Omar | Calendar and meetings | Operations room |
| Noor | Research analyst | Strategy room |
| Rashid | Optical network strategist (DWDM/OTN, coherent, ROADMs, capacity) | Strategy room |
| Sara | Writer and editor | Creative studio |
| Khalid | Vendors and RFPs | Finance room |
| Mariam | Finance and budget | Finance room |
| Yousef | Career and learning | Growth corner |
| Hana | Health and routine (general advice only) | Wellbeing room |

The names are invented, not real people. You can rename any agent or take a specialist off the team (the Chief of Staff stays).

## How they work together
1. **Ask Amer** at the bottom, for example "Prepare me for Monday's DWDM vendor review: agenda, risks, budget".
2. The Chief of Staff makes a plan and hands parts to one to four specialists. Each hand-over is a message in the **Team room**.
3. The specialists work **in parallel**: their circle glows blue while working, with a purple badge for open tasks and an amber one for items waiting for your approval. When done, they hand their results back.
4. The Chief of Staff writes you **one answer**, crediting who did what.
5. Click any agent to see their work, the full conversation for each task, and to **ask them directly**.

## Safety
- **Guardian:** every request passes it first, so Confidential and Restricted content is refused, and personal data is redacted before any model sees it.
- **Approval:** anything that would message someone or book something is marked **Needs your approval**. Nothing leaves the team on its own.
- **Limits:** at most three requests run at once.

Tested on the real stack: `tests/office_test.py`, 7/7. The local stack has no AI provider key, so that test exercises seeding, routing, Guardian, the recorded hand-overs, statuses, editing and direct requests, and the model step answers plainly that the key is missing. With a key, the same path plans, delegates and merges.

## Open gaps
- **Tools:** the agents work from what you tell them. Reading your inbox or calendar directly, or acting through connectors, isn't wired in yet.
- **Approval:** approving a result records your decision; carrying out the action (sending, booking) still goes through the glass box in My agents.
- **Animation:** the office is drawn from live status; there are no idle animations or "break time" scenes.

## Teams agents (Microsoft Teams parity)
Microsoft's Teams agents are on every staff, doing the same jobs here:

| Microsoft Teams agent | Amer staff member | What it does |
|---|---|---|
| Facilitator | Faris | Live notes from a meeting chat: topics, decisions, and action items with owners and dates. Answers quick questions from what was said |
| Interpreter | Lina | Faithful translation between Arabic, English and other languages, keeping terms, names and numbers exact. Live meeting captions are translated separately (TRANSLATED_CAPTIONS.md) |
| Project Manager | Ziad | Plans, status reports (done, in progress, at risk, blocked) and next tasks, from a chat's tasks and messages |
| Channel agent | Reem | Answers questions about a channel only from its conversation, and tracks its open tasks and decisions |
| Analyst | Tariq | Turns data into insights, showing the calculation, and never invents numbers |
| Researcher | Noor | Research with what is known and what is uncertain |

**Working on real data.** In the office, "Work on a chat" attaches the chat's recent messages, members and open tasks. Your device decrypts and collects them, and Guardian then checks them on the server: Confidential and Restricted chats are refused.

**Acting for real, only with approval.** Agents can propose actions on that chat: post a message, create a task (with an owner and due date), or schedule a meeting. Actions on any other chat are dropped. Nothing runs until you press Approve. Your app then carries the actions out with your own keys, so the server never sends anything and end-to-end encryption is kept.

**AI provider.** Set `ANTHROPIC_API_KEY` (and optionally `LLM_MODEL`, default `claude-sonnet-5-5`) on the server. Without a key, every agent says so plainly. Tests use `tests/fake_llm.py` to run the whole pipeline without a key (`tests/teams_agents_test.py`, 10 checks).
