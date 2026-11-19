"""Find-a-time: prayer times against a published timetable, Hijri/Ramadan, working hours, time zones, busy blocks."""
from datetime import date, datetime, timedelta, timezone
from zoneinfo import ZoneInfo
from fastapi.testclient import TestClient
from app import auth, db, calendar_time as C
from app.main import app

AD = (24.4539, 54.3773)
def hm(t): return t.strftime("%H:%M")

def test_prayer_times_match_published_abu_dhabi_timetable():
    # TrueCalendar, Abu Dhabi, December 2026, MWL (Fajr 18°, Isha 17°); within 2 minutes (timetables round up)
    ref = {date(2026, 12, 1): ("05:29", "06:49", "12:12", "15:14", "17:34", "18:50"),
           date(2026, 12, 15): ("05:37", "06:59", "12:18", "15:17", "17:37", "18:53")}
    for d, r in ref.items():
        p = C.prayer_times(d, *AD, "Asia/Dubai", "mwl")
        for k, want in zip(("fajr", "sunrise", "dhuhr", "asr", "maghrib", "isha"), r):
            got = p[k]; w = datetime.combine(d, datetime.strptime(want, "%H:%M").time(), ZoneInfo("Asia/Dubai"))
            assert abs((got - w).total_seconds()) <= 120, (d, k, hm(got), want)

def test_hijri_and_ramadan():
    assert C.hijri(date(2026, 2, 18))[1:] == (9, 1)            # 1 Ramadan 1447
    assert C.in_ramadan(date(2026, 3, 1)) and not C.in_ramadan(date(2026, 4, 1))

def fb(**k): return C.FreeBusy(**k)
UTC = timezone.utc

def test_working_hours_time_zones_and_busy():
    dubai = fb(tz="Asia/Dubai", busy=[{"start": "2026-11-23T05:00:00Z", "end": "2026-11-23T06:00:00Z"}])   # 09:00-10:00 Dubai, Monday
    cairo = fb(tz="Africa/Cairo", work=C.Work(start="09:00", end="17:00"))
    s = datetime(2026, 11, 23, 4, 0, tzinfo=UTC); e = datetime(2026, 11, 23, 16, 0, tzinfo=UTC)
    slots = C.find_slots({"@moh": dubai, "@omar": cairo}, 60, s, e)
    assert slots and len(slots) <= 3
    for x in slots:
        st = datetime.fromisoformat(x["start"])
        assert not (datetime(2026, 11, 23, 5, tzinfo=UTC) <= st < datetime(2026, 11, 23, 6, tzinfo=UTC))   # busy hour avoided
        assert 9 <= st.astimezone(ZoneInfo("Africa/Cairo")).hour and st.astimezone(ZoneInfo("Asia/Dubai")).hour + 1 <= 17
        assert st >= datetime(2026, 11, 23, 7, tzinfo=UTC)       # Cairo opens 09:00 = 07:00Z
    starts = [datetime.fromisoformat(x["start"]) for x in slots]
    assert all(abs((a - b).total_seconds()) >= 3600 for i, a in enumerate(starts) for b in starts[i + 1:])

def test_weekend_and_prayer_and_ramadan_rules():
    sat = datetime(2026, 11, 21, 6, tzinfo=UTC)
    assert not C.free_ok(fb(), sat, sat + timedelta(minutes=30))                     # Saturday off
    d = date(2026, 12, 1); dh = C.prayer_times(d, *AD, "Asia/Dubai")["dhuhr"].astimezone(UTC)
    p = fb(prayer=C.Prayer(lat=AD[0], lon=AD[1]))
    assert not C.free_ok(p, dh - timedelta(minutes=10), dh + timedelta(minutes=20)) and C.free_ok(fb(), dh - timedelta(minutes=10), dh + timedelta(minutes=20))
    r = fb(ramadan_hours=True); late = datetime(2026, 3, 2, 11, 30, tzinfo=UTC)       # 15:30 Dubai in Ramadan: after the shorter day
    assert not C.free_ok(r, late, late + timedelta(minutes=30)) and C.free_ok(fb(), late, late + timedelta(minutes=30))

def test_api_lists_people_without_calendars(monkeypatch):
    C._mem.clear()
    async def me(): return {"user_id": "@moh:amer.test", "token": "t"}
    async def noop(*a, **k): pass
    app.dependency_overrides[auth.matrix_user] = me; monkeypatch.setattr(db, "audit", noop)
    c = TestClient(app)
    assert c.post("/v1/calendar/find-time", json={"invitees": ["@sara:amer.test"], "duration_min": 30}).status_code == 409
    assert c.put("/v1/calendar/freebusy", json={"tz": "Mars/Base"}).status_code == 422
    assert c.put("/v1/calendar/freebusy", json={"tz": "Asia/Dubai", "busy": []}).json()["ok"]
    r = c.post("/v1/calendar/find-time", json={"invitees": ["@sara:amer.test"], "duration_min": 30,
                                                "window_start": "2026-11-23T04:00:00Z", "window_end": "2026-11-24T16:00:00Z"}).json()
    assert r["no_calendar"] == ["@sara:amer.test"] and len(r["slots"]) == 3
