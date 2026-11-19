"""Amer, the AI assistant, as a chat participant (docs/AMER_CHAT.md).

A normal end-to-end encrypted Matrix account (`@amer`). Users chat with it directly, or @mention it in a group.
It reads only the conversations it is invited into, and decrypts them on its own device like any member. It then
sends the question with the recent conversation to the orchestrator's AI engine. There, Guardian checks the
policy, the Router picks the agent, and the request is audited for the user who asked. The answer goes back
encrypted.

Rules
- Direct chat with Amer: answers every message.
- Group chat: answers only when mentioned (@Amer, or m.mentions), as Teams Copilot does.
- First message in each chat: says once that questions go to the AI provider.
- Never answers itself or other bots, and ignores messages older than when it joined.
"""
import asyncio, json, logging, os, time
import httpx
from nio import (AsyncClient, AsyncClientConfig, InviteMemberEvent, LoginResponse, MegolmEvent, RoomMessageText)

HS = os.getenv("HS", "http://synapse:8008")
ORCH = os.getenv("ORCH", "http://orchestrator:8080")
USER = os.getenv("AMER_BOT_USER", "amer")
PASSWORD = os.environ.get("AMER_BOT_PASSWORD", "")
SECRET = os.environ.get("AMER_BOT_SECRET", "")
STORE = os.getenv("STORE_DIR", "/data/amer-bot")
NOTICE = ("Hi, I'm Amer, your AI assistant. Your questions to me and the recent messages in this chat are sent to "
          "the AI service to answer them. Confidential-labelled content is blocked by policy. In groups, @mention me.")
logging.basicConfig(level=logging.INFO, format="%(asctime)s amer-bot %(levelname)s %(message)s")
log = logging.getLogger("amer-bot")

class Bot:
    def __init__(self):
        os.makedirs(STORE, exist_ok=True)
        self.sess = os.path.join(STORE, "session.json"); self.c: AsyncClient | None = None
        self.started_ms = int(time.time() * 1000); self.history: dict[str, list[dict]] = {}
        self.noticed: set[str] = set()

    async def login(self):
        cfg = AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True)
        if os.path.exists(self.sess):
            s = json.load(open(self.sess))
            self.c = AsyncClient(HS, s["user_id"], device_id=s["device_id"], store_path=STORE, config=cfg)
            self.c.restore_login(s["user_id"], s["device_id"], s["access_token"])
        else:
            server = os.getenv("SERVER_NAME"); uid = f"@{USER}:{server}" if server else USER
            self.c = AsyncClient(HS, uid, store_path=STORE, config=cfg)
            r = await self.c.login(PASSWORD, device_name="Amer AI assistant")
            if not isinstance(r, LoginResponse): raise SystemExit(f"Amer bot login failed: {r}")
            json.dump({"user_id": r.user_id, "device_id": r.device_id, "access_token": r.access_token}, open(self.sess, "w"))
            os.chmod(self.sess, 0o600)
        await self.c.set_displayname("Amer")
        log.info("signed in as %s (device %s)", self.c.user_id, self.c.device_id)

    def trust(self):
        for devs in self.c.device_store.values():
            for d in devs.values():
                if d.device_id != self.c.device_id and not d.verified: self.c.verify_device(d)

    async def say(self, room_id: str, text: str, reply_to: str | None = None):
        self.trust()
        content = {"msgtype": "m.text", "body": text}
        if reply_to: content["m.relates_to"] = {"m.in_reply_to": {"event_id": reply_to}}
        await self.c.room_send(room_id, "m.room.message", content, ignore_unverified_devices=True)

    async def on_invite(self, room, ev: InviteMemberEvent):
        if ev.state_key != self.c.user_id or ev.membership != "invite": return
        if ev.sender.split(":", 1)[-1] != self.c.user_id.split(":", 1)[-1]:      # only users of this server
            await self.c.room_leave(room.room_id); return
        await self.c.join(room.room_id); log.info("joined %s (invited by %s)", room.room_id, ev.sender)

    def mentioned(self, room, ev: RoomMessageText) -> bool:
        ids = ((ev.source.get("content") or {}).get("m.mentions") or {}).get("user_ids") or []
        return self.c.user_id in ids or "@amer" in ev.body.lower() or self.c.user_id in ev.body or (ev.formatted_body or "").find(self.c.user_id) >= 0

    async def on_message(self, room, ev: RoomMessageText):
        if ev.sender == self.c.user_id or ev.server_timestamp < self.started_ms - 60_000: return
        h = self.history.setdefault(room.room_id, [])
        h.append({"sender": room.user_name(ev.sender) or ev.sender, "body": ev.body}); del h[:-20]
        direct = room.member_count <= 2
        if not (direct or self.mentioned(room, ev)): return
        if room.room_id not in self.noticed:
            self.noticed.add(room.room_id); await self.say(room.room_id, NOTICE)
        await self.c.room_typing(room.room_id, True, timeout=30000)
        labels = []
        try:                                       # the chat's sensitivity label (set in Chat info); Guardian blocks Confidential/Restricted
            st = await self.c.room_get_state_event(room.room_id, "com.amerteams.sensitivity")
            lab = getattr(st, "content", {}).get("label") if hasattr(st, "content") else None
            if lab: labels.append(lab)
        except Exception: pass
        try:
            async with httpx.AsyncClient(timeout=90) as x:
                r = await x.post(f"{ORCH}/v1/ai/bot", headers={"X-Bot-Secret": SECRET}, json={
                    "user_id": ev.sender, "room_id": room.room_id, "prompt": ev.body.replace(self.c.user_id, "").strip(),
                    "history": h[:-1], "labels": labels})
            ans = r.json().get("answer") if r.status_code == 200 else f"Sorry, I could not answer ({r.status_code})."
        except Exception as e:
            log.warning("AI engine unreachable: %s", e); ans = "I couldn't reach the AI engine just now. Please try again in a minute."
        finally:
            await self.c.room_typing(room.room_id, False)
        await self.say(room.room_id, ans, reply_to=None if direct else ev.event_id)
        h.append({"sender": "Amer", "body": ans}); del h[:-20]

    async def on_undecryptable(self, room, ev: MegolmEvent):
        try: await self.c.request_room_key(ev)
        except Exception: pass

    async def run(self):
        await self.login()
        self.c.add_event_callback(self.on_invite, InviteMemberEvent)
        self.c.add_event_callback(self.on_message, RoomMessageText)
        self.c.add_event_callback(self.on_undecryptable, MegolmEvent)
        open(os.path.join(STORE, "ready"), "w").write(str(self.started_ms))
        while True:
            try:
                await self.c.sync(timeout=10000, full_state=True)
                if self.c.should_upload_keys: await self.c.keys_upload()
                if self.c.should_query_keys: await self.c.keys_query()
                if self.c.should_claim_keys: await self.c.keys_claim(self.c.get_users_for_key_claiming())
            except Exception as e:
                log.warning("sync failed, retrying: %s", e); await asyncio.sleep(5)

if __name__ == "__main__":
    asyncio.run(Bot().run())
