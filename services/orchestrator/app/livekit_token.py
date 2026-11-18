"""Signs LiveKit join tokens. The orchestrator never receives or stores the media key (K)."""
import time, hashlib, jwt
from . import config

def room_name(matrix_room_id: str, call_id: str) -> str:
    # opaque name so the SFU learns nothing about the Matrix room
    return hashlib.sha256(f"{matrix_room_id}|{call_id}".encode()).hexdigest()[:32]

def sign(identity: str, display: str, room: str, now: int | None = None) -> str:
    now = now or int(time.time())
    claims = {
        "iss": config.LIVEKIT_API_KEY, "sub": identity, "name": display,
        "nbf": now - 10, "exp": now + config.TOKEN_TTL_SECONDS,
        "video": {"room": room, "roomJoin": True, "canPublish": True,
                  "canSubscribe": True, "canPublishData": True},
        "metadata": '{"e2ee":"required"}',
    }
    return jwt.encode(claims, config.LIVEKIT_API_SECRET, algorithm="HS256")
