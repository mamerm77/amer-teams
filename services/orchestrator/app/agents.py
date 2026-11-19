"""AI engine: Router dispatches to specialist agents; every step is traced and audited."""
import time, re
from dataclasses import dataclass, field
from . import llm, guardian

@dataclass
class Agent:
    id: str; name: str; system: str
    calls: int = 0; errors: int = 0; latency_ms: float = 0.0; enabled: bool = True

AGENTS = {a.id: a for a in [
  Agent("summ", "Summariser", "You summarise workplace conversations and meeting transcripts. Output: 3-6 bullet key points, then 'Decisions:' and 'Actions:' with owners. British English. Be concise."),
  Agent("trans", "Translator", "You translate faithfully between Arabic, English and Chinese. Keep technical terms (e.g. OSNR, ROADM) untranslated. Output only the translation."),
  Agent("sched", "Scheduler", "You extract meeting intents. Reply ONLY as JSON: {\"title\":str,\"duration_min\":int,\"participants\":[str],\"window\":str}."),
  Agent("minutes", "Minutes", "You write formal meeting minutes from a transcript: Attendees, Agenda, Discussion, Decisions, Actions (owner, due). British English."),
  Agent("digest", "Digest", "You write catch-up digests of workplace chats. Follow the output format in the request exactly. British English. Never invent content."),
  Agent("assist", "Amer", "You are Amer, the assistant inside Amer Teams. Be direct and technically precise. If a request needs an action you cannot take, say exactly what the user should do."),
]}

INTENTS = [("summ", r"summar|digest|catch me up|tl;?dr"), ("trans", r"translat|arabic|english|chinese|عرب"),
           ("sched", r"book|schedul|meeting with|find a slot"), ("minutes", r"minutes")]

def route(prompt: str) -> str:
    p = prompt.lower()
    for aid, rx in INTENTS:
        if re.search(rx, p): return aid
    return "assist"

@dataclass
class Trace:
    steps: list = field(default_factory=list)
    def add(self, agent, note, ms=0): self.steps.append({"agent": agent, "note": note, "ms": round(ms)})

async def run(prompt: str, context: str = "", labels: list[str] | None = None, agent: str | None = None) -> dict:
    tr = Trace()
    ok, why = guardian.check(prompt + context, labels)
    tr.add("Guardian", "policy check passed" if ok else why)
    if not ok:
        return {"answer": why, "agent": "Guardian", "trace": tr.steps, "blocked": True}
    aid = agent or route(prompt); tr.add("Router", f"dispatched to {AGENTS[aid].name}")
    a = AGENTS[aid]
    if not a.enabled:
        return {"answer": f"{a.name} is paused by an operator.", "agent": a.name, "trace": tr.steps, "blocked": True}
    user = guardian.redact((f"Context:\n{context}\n\n" if context else "") + f"Request:\n{prompt}")
    t0 = time.perf_counter()
    try:
        out = await llm.complete(a.system, user)
    except llm.LLMError as e:
        a.errors += 1; tr.add(a.name, str(e)); return {"answer": str(e), "agent": a.name, "trace": tr.steps, "error": True}
    ms = (time.perf_counter() - t0) * 1000
    a.calls += 1; a.latency_ms = a.latency_ms * 0.8 + ms * 0.2 if a.latency_ms else ms
    tr.add(a.name, "completed", ms)
    return {"answer": out, "agent": a.name, "trace": tr.steps}
