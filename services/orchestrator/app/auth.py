"""Identity: every request carries the user's Matrix access token; Synapse is the source of truth."""
import httpx
from fastapi import Header, HTTPException
from . import config

async def matrix_user(authorization: str = Header(...)) -> dict:
    if not authorization.lower().startswith("bearer "):
        raise HTTPException(401, "Missing bearer token")
    tok = authorization.split(" ", 1)[1]
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/account/whoami",
                        headers={"Authorization": f"Bearer {tok}"})
    if r.status_code != 200:
        raise HTTPException(401, "Matrix token rejected")
    return {"user_id": r.json()["user_id"], "token": tok}

async def assert_room_member(user: dict, room_id: str) -> None:
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/rooms/{room_id}/joined_members",
                        headers={"Authorization": f"Bearer {user['token']}"})
    if r.status_code != 200 or user["user_id"] not in r.json().get("joined", {}):
        raise HTTPException(403, "Not a member of this room")
    # Encryption is mandatory: refuse calls in rooms without m.room.encryption
    async with httpx.AsyncClient(timeout=5) as c:
        e = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/rooms/{room_id}/state/m.room.encryption",
                        headers={"Authorization": f"Bearer {user['token']}"})
    if e.status_code != 200:
        raise HTTPException(412, "Room is not end-to-end encrypted; calls are refused")
