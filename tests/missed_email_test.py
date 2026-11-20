"""Missed activity emails (Teams parity): who is due an email, from unread counts only. Runs against the real database
through the orchestrator's own code (the counts arrive from Synapse pushes in production)."""
import asyncio, json, os, secrets, sys
sys.path.insert(0, os.path.join(os.path.dirname(__file__), "..", "services", "orchestrator"))
from app import db, notify
R = []
def check(name, ok, detail=""):
    R.append({"check": name, "pass": bool(ok), "detail": str(detail)[:300]}); print(f"[{'PASS' if ok else 'FAIL'}] {name}  {str(detail)[:200]}", flush=True)
async def main():
    await db.connect(); s = secrets.token_hex(3); a, b, c = f"@ma{s}:amer.test", f"@mb{s}:amer.test", f"@mc{s}:amer.test"
    async with db.pool.connection() as x:
        for u in (a, b, c): await x.execute("INSERT INTO people_profile (user_id, email) VALUES (%s,%s)", (u, f"{u[1:4]}{s}@example.ae"))
        await x.execute("INSERT INTO missed_activity VALUES (%s,'!r1:x',3, now() - interval '2 hours'), (%s,'!r2:x',2, now() - interval '3 hours')", (a, a))
        await x.execute("INSERT INTO missed_activity VALUES (%s,'!r1:x',4, now() - interval '10 minutes')", (b,))
        await x.execute("INSERT INTO missed_activity VALUES (%s,'!r1:x',5, now() - interval '2 hours')", (c,))
        await x.execute("INSERT INTO missed_email (user_id, frequency) VALUES (%s,'off')", (c,))
    due = {u: (n, m) for u, _, n, m in await notify.missed_due()}
    check("1. Unread for over an hour → due an email, with the counts (2 chats, 5 messages); no message content involved", due.get(a) == (2, 5), due.get(a))
    check("2. Unread for only 10 minutes → not yet", b not in due)
    check("3. Missed activity emails turned off → never", c not in due)
    async with db.pool.connection() as x: await x.execute("INSERT INTO missed_email (user_id, last_sent) VALUES (%s, now())", (a,))
    due2 = {u for u, *_ in await notify.missed_due()}
    check("4. After an email, not again within the hour", a not in due2)
    async with db.pool.connection() as x: await x.execute("UPDATE missed_activity SET unread=0 WHERE user_id=%s", (a,)); await x.execute("UPDATE missed_email SET last_sent=now()-interval '2 hours' WHERE user_id=%s", (a,))
    due3 = {u for u, *_ in await notify.missed_due()}
    check("5. Once read (count back to 0), no email", a not in due3)
    json.dump(R, open(os.getenv("OUT", "/opt/amer/missed_email_test.json"), "w"), indent=1)
    print(f"{sum(r['pass'] for r in R)}/{len(R)} passed"); sys.exit(0 if all(r["pass"] for r in R) else 1)
asyncio.run(main())
