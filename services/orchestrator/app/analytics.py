"""Usage analytics for administrators (docs/ANALYTICS.md).

Aggregates only, from metadata this server already keeps: no message content (it is end-to-end encrypted), no
titles, no per-person league tables. Any breakdown row covering fewer than K people is folded into "other" so it
cannot single anyone out. Figures:
  - active people per day (anyone who used a server feature, joined a call or ran AI),
  - calls and meetings per day, minutes, average participants, media quality (MOS, share of poor samples),
  - AI requests per day by agent, with error rate and median latency,
  - feature adoption: distinct people per feature over the window,
  - workflows run and decisions recorded.
"""
from __future__ import annotations
from fastapi import APIRouter, Depends, Query
from . import db
from .admin import require_admin

router = APIRouter()
K = 5                                                    # smallest group shown on its own
FEATURE_OF = {"guest.": "Guests", "webinar.": "Webinars", "recording.": "Recordings", "partner.": "Partners", "phone.": "Phone",
              "compliance.": "Compliance", "flag.": "Feature flags", "meeting.": "Meeting controls", "call.": "Calls", "agent.": "Agents",
              "workflow.": "Workflows", "decision.": "Decisions"}

def fold(rows: list[tuple[str, int, int]]) -> list[dict]:
    """rows: (name, people, count). Groups with fewer than K people go into 'Other (small groups)'."""
    out, op, oc = [], 0, 0
    for name, people, count in rows:
        if people >= K: out.append({"name": name, "people": people, "count": count})
        else: op += people; oc += count
    if oc: out.append({"name": "Other (small groups)", "people": None, "count": oc})
    return sorted(out, key=lambda r: -r["count"])

@router.get("/v1/admin/analytics")
async def analytics(days: int = Query(30, ge=1, le=365), user=Depends(require_admin)):
    if db.pool is None: return {"days": days, "note": "No database"}
    async with db.pool.connection() as c:
        q = lambda sql, *a: c.execute(sql, a)
        active = await (await q("""
            WITH u AS (SELECT date_trunc('day', ts) d, user_id FROM audit_log WHERE ts > now() - make_interval(days => %s) AND user_id LIKE '@%%'
                       UNION SELECT date_trunc('day', joined_at), user_id FROM call_sessions WHERE joined_at > now() - make_interval(days => %s)
                       UNION SELECT date_trunc('day', ts), user_id FROM ai_requests WHERE ts > now() - make_interval(days => %s))
            SELECT d::date, count(DISTINCT user_id) FROM u GROUP BY 1 ORDER BY 1""", days, days, days)).fetchall()
        total_active = (await (await q("""SELECT count(DISTINCT user_id) FROM (SELECT user_id FROM audit_log WHERE ts > now() - make_interval(days => %s) AND user_id LIKE '@%%'
            UNION SELECT user_id FROM call_sessions WHERE joined_at > now() - make_interval(days => %s) UNION SELECT user_id FROM ai_requests WHERE ts > now() - make_interval(days => %s)) x""", days, days, days)).fetchone())[0]
        calls = await (await q("""
            WITH r AS (SELECT call_id room, min(ts) s, max(ts) e FROM call_events WHERE source='media' AND event IN ('room_started','room_finished')
                       AND ts > now() - make_interval(days => %s) GROUP BY 1),
                 p AS (SELECT call_id room, count(DISTINCT user_id) n FROM call_events WHERE source='media' AND event='participant_joined'
                       AND ts > now() - make_interval(days => %s) GROUP BY 1)
            SELECT r.s::date, count(*), coalesce(sum(extract(epoch from (r.e - r.s)) / 60), 0)::int, coalesce(avg(p.n), 0)
            FROM r LEFT JOIN p USING (room) GROUP BY 1 ORDER BY 1""", days, days)).fetchall()
        quality = await (await q("""SELECT avg(mos), avg(CASE WHEN mos < 3.1 OR loss_pct > 5 THEN 1.0 ELSE 0 END), count(*) FROM call_quality WHERE ts > now() - make_interval(days => %s)""", days)).fetchone()
        ai = await (await q("""SELECT ts::date, agent, count(*), count(DISTINCT user_id), avg(CASE WHEN status <> 'ok' THEN 1.0 ELSE 0 END),
            percentile_cont(0.5) WITHIN GROUP (ORDER BY latency_ms) FROM ai_requests WHERE ts > now() - make_interval(days => %s) GROUP BY 1, 2 ORDER BY 1""", days)).fetchall()
        ai_agents = await (await q("""SELECT agent, count(DISTINCT user_id), count(*) FROM ai_requests WHERE ts > now() - make_interval(days => %s) GROUP BY 1""", days)).fetchall()
        feats = await (await q("""SELECT split_part(action, '.', 1) || '.', count(DISTINCT user_id), count(*) FROM audit_log WHERE ts > now() - make_interval(days => %s) GROUP BY 1""", days)).fetchall()
        wf = (await (await q("SELECT count(*), avg(CASE WHEN status='done' THEN 1.0 ELSE 0 END) FROM workflow_runs WHERE started_at > now() - make_interval(days => %s)", days)).fetchone())
        dec = (await (await q("SELECT count(DISTINCT decision_id) FROM decision_ledger WHERE to_timestamp(at) > now() - make_interval(days => %s)", days)).fetchone())[0]
    feat_rows = {}
    for prefix, people, count in feats:
        name = FEATURE_OF.get(prefix)
        if name: feat_rows[name] = (people, count)
    return {
        "days": days, "k_anonymity": K,
        "active": {"people": total_active, "per_day": [{"day": str(d), "people": n} for d, n in active]},
        "calls": {"per_day": [{"day": str(d), "calls": n, "minutes": m, "avg_participants": round(float(a), 1)} for d, n, m, a in calls],
                  "quality": {"avg_mos": round(float(quality[0]), 2) if quality[0] is not None else None,
                              "poor_share": round(float(quality[1]), 3) if quality[1] is not None else None, "samples": quality[2]}},
        "ai": {"per_day": [{"day": str(d), "agent": a, "requests": n, "error_rate": round(float(e), 3), "median_ms": int(m or 0)} for d, a, n, _, e, m in ai],
               "by_agent": fold([(a or "assist", p, n) for a, p, n in ai_agents])},
        "features": fold([(k, p, n) for k, (p, n) in feat_rows.items()]),
        "workflows": {"runs": wf[0], "success_rate": round(float(wf[1]), 3) if wf[1] is not None else None},
        "decisions": dec,
    }
