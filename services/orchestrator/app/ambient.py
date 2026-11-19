"""Ambient presence rooms (docs/AMBIENT.md): an always-open drop-in space for each team chat. People join with
the microphone and camera off and are seen as "in the team room"; anyone in the chat can see who is there before
joining. The media is an ordinary end-to-end encrypted meeting (call id "meet-ambient-<room>"); this endpoint
only asks the media server who is connected (names, no media), for members of the chat.
"""
from __future__ import annotations
import time, jwt, httpx
from fastapi import APIRouter, Depends
from . import auth, config, livekit_token

router = APIRouter()

def admin_token(room: str) -> str:
    now = int(time.time())
    return jwt.encode({"iss": config.LIVEKIT_API_KEY, "sub": "amer-orchestrator", "nbf": now - 10, "exp": now + 60,
                       "video": {"roomAdmin": True, "room": room}}, config.LIVEKIT_API_SECRET, algorithm="HS256")

async def participants(room_id: str, call_id: str) -> list[dict]:
    lk = livekit_token.room_name(room_id, call_id)
    try:
        async with httpx.AsyncClient(timeout=5) as c:
            r = await c.post(f"{config.LIVEKIT_HTTP_URL}/twirp/livekit.RoomService/ListParticipants", json={"room": lk},
                             headers={"Authorization": f"Bearer {admin_token(lk)}"})
        if r.status_code != 200: return []
        return [{"identity": p.get("identity"), "name": p.get("name") or p.get("identity"), "since": int(p.get("joinedAt", 0) or 0),
                 "speaking_allowed": bool(p.get("permission", {}).get("canPublish", True))} for p in r.json().get("participants", [])]
    except httpx.HTTPError:
        return []

@router.get("/v1/ambient/{room_id}")
async def who_is_here(room_id: str, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, room_id)
    return {"call_id": f"meet-ambient-{room_id}", "here": await participants(room_id, f"meet-ambient-{room_id}")}
