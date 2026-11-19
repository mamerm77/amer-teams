"""Find-a-time (docs/FIND_A_TIME.md): free/busy, working hours, time zones, prayer times and Ramadan hours.

Each user's app publishes only free/busy blocks (start and end, never titles or rooms) plus their working hours,
time zone and optional prayer-time and Ramadan settings. Find-a-time intersects everyone's free time and returns
the 3 best slots. Users who have not shared free/busy are listed, never guessed.

Prayer times: the standard astronomical method (sun declination and equation of time; Fajr/Isha by sun angle,
Asr by shadow ratio), as used by common timetables. Ramadan: Hijri month 9 by the arithmetical (tabular)
Islamic calendar, which can differ by a day from the local moon sighting; the user can switch it off.
"""
from __future__ import annotations
import math, time
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from fastapi import APIRouter, Depends, HTTPException
from pydantic import BaseModel, Field
from . import auth, db

from . import flags
router = APIRouter(dependencies=[Depends(flags.require("find_time"))])
METHODS = {"mwl": (18.0, 17.0), "uae": (18.2, 18.2), "umm_al_qura": (18.5, None), "egypt": (19.5, 17.5), "isna": (15.0, 15.0)}
PRAYER_BLOCK_MIN = 20                                   # time kept free around each prayer that falls in working hours

# ---------------- astronomy ----------------
def _sun(jd: float) -> tuple[float, float]:
    """Declination (deg) and equation of time (hours) for a Julian day."""
    d = jd - 2451545.0
    g = math.radians((357.529 + 0.98560028 * d) % 360); q = (280.459 + 0.98564736 * d) % 360
    L = math.radians((q + 1.915 * math.sin(g) + 0.020 * math.sin(2 * g)) % 360); e = math.radians(23.439 - 0.00000036 * d)
    ra = math.degrees(math.atan2(math.cos(e) * math.sin(L), math.cos(L))) / 15
    return math.degrees(math.asin(math.sin(e) * math.sin(L))), q / 15 - (ra % 24 if ra >= 0 else ra % 24)

def _jd(d: date) -> float:
    y, m = (d.year, d.month) if d.month > 2 else (d.year - 1, d.month + 12)
    a = y // 100; b = 2 - a + a // 4
    return math.floor(365.25 * (y + 4716)) + math.floor(30.6001 * (m + 1)) + d.day + b - 1524.5

def prayer_times(d: date, lat: float, lon: float, tz: str, method: str = "mwl") -> dict[str, datetime]:
    fajr_a, isha_a = METHODS.get(method, METHODS["mwl"])
    off = datetime(d.year, d.month, d.day, 12, tzinfo=ZoneInfo(tz)).utcoffset().total_seconds() / 3600
    jd = _jd(d) - lon / 360
    def at(t):                                          # iterate once at the event's own time for accuracy
        decl, eqt = _sun(jd + t / 24); return decl, 12 - ((eqt + 12) % 24 - 12)
    def angle_time(a, t, ccw):
        decl, noon = at(t)
        x = (-math.sin(math.radians(a)) - math.sin(math.radians(decl)) * math.sin(math.radians(lat))) / (math.cos(math.radians(decl)) * math.cos(math.radians(lat)))
        h = math.degrees(math.acos(max(-1.0, min(1.0, x)))) / 15
        return noon + (-h if ccw else h)
    def asr_time(t):
        decl, noon = at(t)
        a = -math.degrees(math.atan(1 / (1 + math.tan(math.radians(abs(lat - decl))))))
        return angle_time(a, t, False)
    times = {"fajr": angle_time(fajr_a, 5, True), "sunrise": angle_time(0.833, 6, True), "dhuhr": at(12)[1],
             "asr": asr_time(13), "maghrib": angle_time(0.833, 18, False)}
    times["isha"] = angle_time(isha_a, 18, False) if isha_a else times["maghrib"] + 1.5   # Umm al-Qura: 90 min after Maghrib
    times = {k: v + off - lon / 15 for k, v in times.items()}
    base = datetime(d.year, d.month, d.day, tzinfo=ZoneInfo(tz))
    return {k: base + timedelta(minutes=round(v * 60)) for k, v in times.items()}

def hijri(d: date) -> tuple[int, int, int]:
    """Arithmetical (tabular, Kuwaiti) Islamic calendar."""
    jd = int(_jd(d) + 0.5); l = jd - 1948440 + 10632; n = (l - 1) // 10631; l = l - 10631 * n + 354
    j = ((10985 - l) // 5316) * ((50 * l) // 17719) + (l // 5670) * ((43 * l) // 15238)
    l = l - ((30 - j) // 15) * ((17719 * j) // 50) - (j // 16) * ((15238 * j) // 43) + 29
    m = (24 * l) // 709; day = l - (709 * m) // 24; y = 30 * n + j - 30
    return y, m, day

def in_ramadan(d: date) -> bool: return hijri(d)[1] == 9

# ---------------- free time ----------------
class Work(BaseModel):
    days: list[int] = [0, 1, 2, 3, 4]                  # Monday = 0
    start: str = "08:00"
    end: str = "17:00"

class Prayer(BaseModel):
    lat: float = Field(ge=-90, le=90); lon: float = Field(ge=-180, le=180)
    method: str = "mwl"

class FreeBusy(BaseModel):
    busy: list[dict] = Field(default=[], max_length=2000)   # [{start, end}] ISO 8601 with offset; no titles
    tz: str = "Asia/Dubai"
    work: Work = Work()
    prayer: Prayer | None = None
    ramadan_hours: bool = False                         # UAE: two hours shorter working day in Ramadan

def _parse(s: str) -> datetime:
    t = datetime.fromisoformat(s.replace("Z", "+00:00"))
    return t if t.tzinfo else t.replace(tzinfo=timezone.utc)

def free_ok(fb: FreeBusy, s: datetime, e: datetime) -> bool:
    z = ZoneInfo(fb.tz); ls, le = s.astimezone(z), e.astimezone(z)
    if ls.date() != le.date() or ls.weekday() not in fb.work.days: return False
    hs, ms = map(int, fb.work.start.split(":")); he, me = map(int, fb.work.end.split(":"))
    ws = ls.replace(hour=hs, minute=ms, second=0, microsecond=0); we = ls.replace(hour=he, minute=me, second=0, microsecond=0)
    if fb.ramadan_hours and in_ramadan(ls.date()): we -= timedelta(hours=2)
    if ls < ws or le > we: return False
    for b in fb.busy:
        if _parse(b["start"]) < e and _parse(b["end"]) > s: return False
    if fb.prayer:
        for k, t in prayer_times(ls.date(), fb.prayer.lat, fb.prayer.lon, fb.tz, fb.prayer.method).items():
            if k == "sunrise": continue
            if t < le and t + timedelta(minutes=PRAYER_BLOCK_MIN) > ls: return False
    return True

def find_slots(fbs: dict[str, FreeBusy], duration_min: int, start: datetime, end: datetime, step_min: int = 15, n: int = 3) -> list[dict]:
    t = start.replace(second=0, microsecond=0); t += timedelta(minutes=(-t.minute) % step_min)
    out, d = [], timedelta(minutes=duration_min)
    while t + d <= end and len(out) < 500:
        if all(free_ok(fb, t, t + d) for fb in fbs.values()):
            out.append(t)
        t += timedelta(minutes=step_min)
    def score(s):                                       # earlier is better; prefer 09:00–12:00 for the organiser; avoid back-to-back
        org = next(iter(fbs.values())); h = s.astimezone(ZoneInfo(org.tz)).hour
        adj = sum(abs((_parse(b["end"]) - s).total_seconds()) < 60 or abs((_parse(b["start"]) - (s + d)).total_seconds()) < 60 for fb in fbs.values() for b in fb.busy)
        return ((s - start).total_seconds() / 3600) + (0 if 9 <= h < 12 else 4) + 3 * adj
    best, picked = sorted(out, key=score), []
    for s in best:                                      # three distinct options, not three adjacent quarter-hours
        if all(abs((s - p).total_seconds()) >= 3600 for p in picked): picked.append(s)
        if len(picked) == n: break
    return [{"start": s.isoformat(), "end": (s + d).isoformat()} for s in sorted(picked)]

# ---------------- storage and API ----------------
_mem: dict[str, dict] = {}
async def _put(user: str, fb: FreeBusy):
    if db.pool is None: _mem[user] = {"fb": fb.model_dump(), "at": time.time()}; return
    async with db.pool.connection() as c:
        await c.execute("INSERT INTO calendar_freebusy (user_id, data, updated_at) VALUES (%s,%s,now()) ON CONFLICT (user_id) DO UPDATE SET data=EXCLUDED.data, updated_at=now()",
                        (user, fb.model_dump_json()))
async def _get(users: list[str]) -> dict[str, FreeBusy]:
    if db.pool is None: return {u: FreeBusy(**_mem[u]["fb"]) for u in users if u in _mem}
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, data FROM calendar_freebusy WHERE user_id = ANY(%s)", (users,))).fetchall()
    return {u: FreeBusy(**(d if isinstance(d, dict) else __import__("json").loads(d))) for u, d in rows}

@router.put("/v1/calendar/freebusy")
async def put_freebusy(req: FreeBusy, user=Depends(auth.matrix_user)):
    try: ZoneInfo(req.tz)
    except Exception: raise HTTPException(422, f"Unknown time zone {req.tz}")
    await _put(user["user_id"], req); return {"ok": True, "busy_blocks": len(req.busy)}

class FindReq(BaseModel):
    invitees: list[str] = Field(min_length=1, max_length=50)
    duration_min: int = Field(ge=5, le=480)
    window_start: str | None = None
    window_end: str | None = None

@router.post("/v1/calendar/find-time")
async def find_time(req: FindReq, user=Depends(auth.matrix_user)):
    people = [user["user_id"]] + [u for u in req.invitees if u != user["user_id"]]
    fbs = await _get(people)
    if user["user_id"] not in fbs: raise HTTPException(409, "Share your own free/busy first (open the Calendar once)")
    ordered = {u: fbs[u] for u in people if u in fbs}
    s = _parse(req.window_start) if req.window_start else datetime.now(timezone.utc) + timedelta(minutes=30)
    e = _parse(req.window_end) if req.window_end else s + timedelta(days=7)
    if e - s > timedelta(days=31): raise HTTPException(422, "Search at most 31 days ahead")
    slots = find_slots(ordered, req.duration_min, s, e)
    await db.audit(user["user_id"], "calendar.find_time", f"invitees={len(people) - 1} missing={len(people) - len(ordered)} slots={len(slots)}")
    return {"slots": slots, "considered": list(ordered), "no_calendar": [u for u in people if u not in fbs]}
