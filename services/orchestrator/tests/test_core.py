import jwt, asyncio
from app import livekit_token, agents, guardian, config

def test_token_claims():
    t = livekit_token.sign("@moh:x", "Moh", "r1", now=1_000_000)
    c = jwt.decode(t, config.LIVEKIT_API_SECRET, algorithms=["HS256"], options={"verify_exp": False, "verify_nbf": False})
    assert c["video"]["room"] == "r1" and c["sub"] == "@moh:x" and "e2ee" in c["metadata"]

def test_room_name_opaque():
    n = livekit_token.room_name("!abc:example.com", "c1")
    assert "abc" not in n and len(n) == 32

def test_router():
    assert agents.route("Summarise this thread") == "summ"
    assert agents.route("translate to Arabic") == "trans"
    assert agents.route("book a meeting with Sara") == "sched"
    assert agents.route("what is OSNR") == "assist"

def test_guardian_blocks_label():
    r = asyncio.run(agents.run("summarise", labels=["Confidential"]))
    assert r["blocked"]

def test_redact():
    assert "[redacted]" in guardian.redact("card 4111 1111 1111 1111")
