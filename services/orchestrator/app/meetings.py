"""Meeting host controls and webinar mode.

- Host = room admin or moderator in Matrix (power level >= 50). Checked against Synapse with the caller's own token.
- Controls act on the media server (LiveKit): mute one person, mute everyone, stop someone's video, remove, end for all.
- Webinar mode (room state com.amerteams.meeting.settings {"mode": "webinar"}): only hosts and presenters may
  publish audio/video; attendees watch, chat, react and raise hands. Enforced in the join token, not just the UI.
Media stays end-to-end encrypted: these controls never touch keys or content.
"""
import urllib.parse
import httpx
from fastapi import APIRouter, Depends, HTTPException
from livekit import api as lkapi
from pydantic import BaseModel
from . import auth, config, db, livekit_token

router = APIRouter(prefix="/v1/meetings")
HOST_LEVEL = 50

async def _state(user, room_id, typ):
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/state/{typ}",
                        headers={"Authorization": f"Bearer {user['token']}"})
    return r.json() if r.status_code == 200 else {}

OWNER = 2**53 - 1

async def power_level(user, room_id) -> int:
    # Room version 12+: the creator (and additional_creators) are owners and are not listed in power_levels
    async with httpx.AsyncClient(timeout=5) as c:
        r = await c.get(f"{config.SYNAPSE_URL}/_matrix/client/v3/rooms/{urllib.parse.quote(room_id)}/state",
                        headers={"Authorization": f"Bearer {user['token']}"})
    state = r.json() if r.status_code == 200 else []
    create = next((e for e in state if e.get("type") == "m.room.create"), {})
    pl = next((e.get("content", {}) for e in state if e.get("type") == "m.room.power_levels"), {})
    version = str(create.get("content", {}).get("room_version", "1"))
    if version.isdigit() and int(version) >= 12 and (create.get("sender") == user["user_id"] or
            user["user_id"] in create.get("content", {}).get("additional_creators", [])):
        return OWNER
    return int(pl.get("users", {}).get(user["user_id"], pl.get("users_default", 0)))

async def settings(user, room_id) -> dict:
    return await _state(user, room_id, "com.amerteams.meeting.settings")

async def publish_allowed(user, room_id) -> bool:
    s = await settings(user, room_id)
    if s.get("mode") != "webinar": return True
    if user["user_id"] in s.get("presenters", []): return True
    return await power_level(user, room_id) >= HOST_LEVEL

class Control(BaseModel):
    room_id: str
    call_id: str
    action: str            # mute | mute_all | stop_video | remove | end
    identity: str | None = None

@router.post("/control")
async def control(req: Control, user=Depends(auth.matrix_user)):
    await auth.assert_room_member(user, req.room_id)
    if await power_level(user, req.room_id) < HOST_LEVEL:
        raise HTTPException(403, "Only the meeting host can do this")
    room = livekit_token.room_name(req.room_id, req.call_id)
    done = 0
    async with lkapi.LiveKitAPI(config.LIVEKIT_HTTP_URL, config.LIVEKIT_API_KEY, config.LIVEKIT_API_SECRET) as lk:
        if req.action == "end":
            await lk.room.delete_room(lkapi.DeleteRoomRequest(room=room)); done = 1
        else:
            parts = (await lk.room.list_participants(lkapi.ListParticipantsRequest(room=room))).participants
            targets = [p for p in parts if (p.identity != user["user_id"] if req.action == "mute_all" else p.identity == req.identity)]
            if not targets: raise HTTPException(404, "That person is not in the call")
            for p in targets:
                if req.action == "remove":
                    await lk.room.remove_participant(lkapi.RoomParticipantIdentity(room=room, identity=p.identity)); done += 1
                    continue
                want = lkapi.TrackSource.MICROPHONE if req.action in ("mute", "mute_all") else lkapi.TrackSource.CAMERA
                for t in p.tracks:
                    if t.source == want and not t.muted:
                        await lk.room.mute_published_track(lkapi.MuteRoomTrackRequest(room=room, identity=p.identity, track_sid=t.sid, muted=True)); done += 1
    await db.audit(user["user_id"], f"meeting.{req.action}", f"{req.call_id} {req.identity or ''}".strip())
    return {"ok": True, "affected": done}

@router.get("/presence")
async def presence(room_id: str, call_id: str, user=Depends(auth.matrix_user)):
    """Who is in a meeting right now, from the media server itself (not from chat events)."""
    await auth.assert_room_member(user, room_id)
    async with lkapi.LiveKitAPI(config.LIVEKIT_HTTP_URL, config.LIVEKIT_API_KEY, config.LIVEKIT_API_SECRET) as lk:
        try:
            ps = (await lk.room.list_participants(lkapi.ListParticipantsRequest(room=livekit_token.room_name(room_id, call_id)))).participants
        except Exception:
            ps = []            # room does not exist on the media server: nobody is in the meeting
    return {"count": len(ps), "participants": [p.identity for p in ps]}

# ---------- recordings with consent (docs/RECORDINGS.md) ----------
# The server never records: media is end-to-end encrypted. It keeps the consent trail only, so an organisation can
# show who agreed to which recording and when. The recording itself is made on the host's device and shared in the
# chat as an encrypted file.
class RecordingEvent(BaseModel):
    room_id: str
    call_id: str
    recording_id: str
    event: str            # requested | consent | decline | started | stopped | withdrawn

REC_EVENTS = {"requested", "consent", "decline", "started", "stopped", "withdrawn"}

@router.post("/recording")
async def recording_event(req: RecordingEvent, user=Depends(auth.matrix_user)):
    if req.event not in REC_EVENTS: raise HTTPException(422, "Unknown recording event")
    if db.pool is None: return {"ok": True}
    if req.event in ("requested", "started", "stopped") and await power_level(user, req.room_id) < HOST_LEVEL:
        raise HTTPException(403, "Only a host can start or stop a recording")
    await db.audit(user["user_id"], f"recording.{req.event}", f"{req.room_id}|{req.call_id}|{req.recording_id}")
    return {"ok": True}

@router.get("/recording/{recording_id}")
async def recording_trail(recording_id: str, room_id: str, user=Depends(auth.matrix_user)):
    if await power_level(user, room_id) < HOST_LEVEL: raise HTTPException(403, "Hosts only")
    if db.pool is None: return []
    async with db.pool.connection() as c:
        rows = await (await c.execute("SELECT user_id, action, extract(epoch from ts)::bigint FROM audit_log WHERE action LIKE 'recording.%%' AND detail LIKE %s ORDER BY id",
                                      (f"%|{recording_id}",))).fetchall()
    return [{"user": a, "event": x.split(".", 1)[1], "at": t} for a, x, t in rows]
