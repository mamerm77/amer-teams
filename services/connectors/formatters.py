"""Turn each tool's webhook JSON into one readable chat message (docs/TOOL_CONNECTORS.md)."""
from __future__ import annotations

def _g(d, *path, default=""):
    for p in path:
        if not isinstance(d, dict): return default
        d = d.get(p)
    return d if d not in (None, "") else default

def github(b: dict, h: dict) -> str:
    ev = h.get("x-github-event", "")
    repo = _g(b, "repository", "full_name")
    if ev == "push":
        commits = b.get("commits") or []
        lines = [f"• {c.get('message', '').splitlines()[0][:100]} ({_g(c, 'author', 'name')})" for c in commits[:5]]
        return f"⬆️ {_g(b, 'pusher', 'name')} pushed {len(commits)} commit(s) to {repo} {_g(b, 'ref').replace('refs/heads/', '')}\n" + "\n".join(lines)
    if ev == "pull_request":
        pr = b.get("pullRequest") or b.get("pull_request") or {}
        return f"🔀 PR #{pr.get('number')} {b.get('action')} in {repo}: {pr.get('title')}\n{pr.get('html_url', '')}"
    if ev == "issues":
        i = b.get("issue") or {}
        return f"🐞 Issue #{i.get('number')} {b.get('action')} in {repo}: {i.get('title')}\n{i.get('html_url', '')}"
    if ev == "workflow_run":
        w = b.get("workflow_run") or {}
        return f"{'✅' if w.get('conclusion') == 'success' else '❌' if w.get('conclusion') == 'failure' else '⏳'} {w.get('name')} on {repo}: {w.get('conclusion') or w.get('status')}\n{w.get('html_url', '')}"
    return f"GitHub {ev} in {repo}"

def gitlab(b: dict, h: dict) -> str:
    k = b.get("object_kind", ""); p = _g(b, "project", "path_with_namespace")
    if k == "push": return f"⬆️ {b.get('user_name')} pushed {b.get('total_commits_count', 0)} commit(s) to {p} {str(b.get('ref', '')).replace('refs/heads/', '')}"
    if k == "merge_request": a = b.get("object_attributes") or {}; return f"🔀 MR !{a.get('iid')} {a.get('action') or a.get('state')} in {p}: {a.get('title')}\n{a.get('url', '')}"
    if k == "pipeline": a = b.get("object_attributes") or {}; return f"{'✅' if a.get('status') == 'success' else '❌' if a.get('status') == 'failed' else '⏳'} Pipeline {a.get('id')} in {p}: {a.get('status')}"
    return f"GitLab {k} in {p}"

def jira(b: dict, h: dict) -> str:
    i = b.get("issue") or {}; f = i.get("fields") or {}
    ev = str(b.get("webhookEvent", "")).replace("jira:", "").replace("_", " ")
    who = _g(b, "user", "displayName")
    return f"🎫 {i.get('key')} {ev}{f' by {who}' if who else ''}: {f.get('summary', '')}\nStatus {_g(f, 'status', 'name', default='?')} · priority {_g(f, 'priority', 'name', default='?')} · assignee {_g(f, 'assignee', 'displayName', default='unassigned')}"

def alertmanager(b: dict, h: dict) -> str:
    out = []
    for a in (b.get("alerts") or [])[:10]:
        lab, ann = a.get("labels") or {}, a.get("annotations") or {}
        icon = "✅ RESOLVED" if a.get("status") == "resolved" else "🚨 " + str(lab.get("severity", "alert")).upper()
        out.append(f"{icon} {lab.get('alertname', '')}{' · ' + lab['instance'] if lab.get('instance') else ''}\n{ann.get('summary') or ann.get('description') or ''}".strip())
    return "\n\n".join(out) or "Alertmanager: no alerts in this notification"

grafana = alertmanager                                  # Grafana unified alerting sends the Alertmanager format

def servicenow(b: dict, h: dict) -> str:
    return f"🧾 {b.get('number', 'Incident')} {b.get('state', '')}: {b.get('short_description', '')}\nPriority {b.get('priority', '?')} · assigned to {b.get('assigned_to', 'nobody')}"

def jenkins(b: dict, h: dict) -> str:
    bd = b.get("build") or {}
    return f"{'✅' if bd.get('status') == 'SUCCESS' else '❌' if bd.get('status') == 'FAILURE' else '⏳'} {b.get('name')} #{bd.get('number')} {bd.get('phase', '')} {bd.get('status', '')}\n{bd.get('full_url', '')}".strip()

def generic(b: dict, h: dict) -> str:
    return str(b.get("text") or b.get("message") or b.get("body") or b)[:4000]

FORMAT = {"github": github, "gitlab": gitlab, "jira": jira, "alertmanager": alertmanager, "grafana": grafana, "servicenow": servicenow, "jenkins": jenkins, "generic": generic}

def render(kind: str, name: str, body: dict, headers: dict) -> str:
    try: text = FORMAT.get(kind, generic)(body, {k.lower(): v for k, v in headers.items()})
    except Exception: text = generic(body, headers)
    return f"[{name}] {text}"[:6000]
