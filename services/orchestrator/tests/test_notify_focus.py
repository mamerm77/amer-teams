"""Focus sessions hold every push except priority senders, then stop on their own."""
from datetime import datetime, timezone
from app.notify import Settings, hold

def test_focus_holds_mentions_but_not_priority():
    now = datetime(2026, 11, 19, 10, 0, tzinfo=timezone.utc)
    st = Settings(priority_senders=["@boss:x"], focus_until=now.timestamp() + 600)
    assert hold(st, "@colleague:x", "high", now)            # a mention waits during focus
    assert not hold(st, "@boss:x", "low", now)              # a priority sender comes through
    st.focus_until = now.timestamp() - 1
    assert not hold(st, "@colleague:x", "high", now)        # after the session ends, nothing is held (no quiet hours)
