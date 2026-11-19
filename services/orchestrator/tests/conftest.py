import pytest

@pytest.fixture(autouse=True)
def _fresh_flags():
    """Feature flags are process-wide in memory during tests: start every test from the defaults."""
    from app import flags
    flags._mem.clear(); yield; flags._mem.clear()
