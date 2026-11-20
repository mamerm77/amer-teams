"""Amer Teams partner policy for Synapse (docs/PARTNERS.md).

1. Only partner servers: every event arriving from another server is accepted only if that server is an
   *active* partner in the orchestrator (requested -> approved -> active; suspended or disconnected = refused).
   A server that was never approved cannot join, invite or post.
2. Local by default: rooms are created with m.federate = false unless they are marked as shared with partners
   (initial state com.amerteams.shared), so ordinary chats can never be reached from outside, even by a partner.

The partner list is read from the orchestrator (cached for 10 seconds) with a shared secret. If the orchestrator
cannot be reached, the last known list is used; with no list at all, nothing from outside is accepted.
"""
import time

class AmerFederation:
    def __init__(self, config: dict, api):
        self.api = api
        self.url = config.get("orchestrator", "http://orchestrator:8080").rstrip("/")
        self.secret = config.get("secret", "")
        self.ttl = float(config.get("cache_seconds", 10))
        self.server = api.server_name
        self._partners: set[str] = set(); self._at = 0.0
        api.register_third_party_rules_callbacks(check_event_allowed=self.check_event_allowed, on_create_room=self.on_create_room)
        # check_event_allowed covers joins and invites; the spam checker also runs on every event arriving over
        # federation, so messages from a server that is no longer a partner are refused (their content removed).
        if hasattr(api, "register_spam_checker_callbacks"):
            api.register_spam_checker_callbacks(check_event_for_spam=self.check_event_for_spam,
                user_may_create_room=self.user_may_create_room, user_may_invite=self.user_may_invite, user_may_join_room=self.user_may_join_room)
        self._guests: set[str] = set(); self._gat = 0.0
        self._holds: dict = {"rooms": set(), "users": set()}; self._hat = 0.0

    @staticmethod
    def parse_config(config): return config

    async def partners(self) -> set[str]:
        if time.time() - self._at < self.ttl: return self._partners
        try:
            j = await self.api.http_client.get_json(f"{self.url}/v1/federation/allowed", headers={"X-Amer-Federation": [self.secret]})
            self._partners = set(j.get("servers", [])); self._at = time.time()
        except Exception:
            self._at = time.time() - self.ttl + 2              # retry soon; keep the last known list meanwhile
        return self._partners

    # ---- guest accounts (docs/GUEST_ACCOUNTS.md): no new rooms, no invites, only rooms they were invited to ----
    async def guests(self) -> set[str]:
        if time.time() - self._gat < self.ttl: return self._guests
        try:
            j = await self.api.http_client.get_json(f"{self.url}/v1/federation/guests", headers={"X-Amer-Federation": [self.secret]})
            self._guests = set(j.get("guests", [])); self._gat = time.time()
        except Exception:
            self._gat = time.time() - self.ttl + 2
        return self._guests

    @staticmethod
    def _ok():
        try:
            from synapse.module_api import NOT_SPAM
            return NOT_SPAM
        except ImportError: return "NOT_SPAM"
    @staticmethod
    def _no():
        try:
            from synapse.api.errors import Codes
            return Codes.FORBIDDEN
        except ImportError: return "M_FORBIDDEN"

    async def user_may_create_room(self, user_id: str):
        return self._no() if user_id in await self.guests() else self._ok()
    async def user_may_invite(self, inviter: str, invitee: str, room_id: str):
        return self._no() if inviter in await self.guests() else self._ok()
    async def user_may_join_room(self, user_id: str, room_id: str, is_invited: bool):
        return self._no() if (user_id in await self.guests() and not is_invited) else self._ok()

    # ---- legal hold (docs/LEGAL_HOLD.md): no redactions and no retention changes in held rooms or by held people ----
    async def holds(self) -> dict:
        if time.time() - self._hat < self.ttl: return self._holds
        try:
            j = await self.api.http_client.get_json(f"{self.url}/v1/federation/holds", headers={"X-Amer-Federation": [self.secret]})
            self._holds = {"rooms": set(j.get("rooms", [])), "users": set(j.get("users", []))}; self._hat = time.time()
        except Exception:
            self._hat = time.time() - self.ttl + 2
        return self._holds

    async def _held(self, event) -> bool:
        t = getattr(event, "type", "")
        if t not in ("m.room.redaction", "m.room.retention"): return False
        h = await self.holds()
        return getattr(event, "room_id", "") in h["rooms"] or (getattr(event, "sender", "") in h["users"] and t == "m.room.redaction")

    @staticmethod
    def _moderated_refusal(event, state_events) -> bool:
        """Channel moderation (Teams parity, docs/TEAM_SETTINGS.md): in a channel whose com.amerteams.channel state has
        moderated=true, only moderators (power 50+ or listed) start new posts. Replies, reactions and edits carry
        m.relates_to (unencrypted even in encrypted rooms), so they still go through. Nothing is decrypted."""
        if getattr(event, "type", "") not in ("m.room.message", "m.room.encrypted"): return False
        st = state_events or {}
        ch = st.get(("com.amerteams.channel", ""))
        conf = getattr(ch, "content", {}) if ch is not None else {}
        if not conf.get("moderated"): return False
        if (getattr(event, "content", {}) or {}).get("m.relates_to"): return False
        sender = getattr(event, "sender", "")
        if sender in (conf.get("moderators") or []): return False
        pl_ev = st.get(("m.room.power_levels", ""))
        pl = getattr(pl_ev, "content", {}) if pl_ev is not None else {}
        level = (pl.get("users") or {}).get(sender, pl.get("users_default", 0))
        create = st.get(("m.room.create", ""))
        if create is not None and getattr(create, "sender", "") == sender: return False   # the creator (room v12 owner)
        return level < 50

    async def check_event_allowed(self, event, state_events):
        if await self._held(event): return False, None
        if self._moderated_refusal(event, state_events): return False, None
        sender = getattr(event, "sender", "") or ""
        origin = sender.split(":", 1)[1] if ":" in sender else ""
        if not origin or origin == self.server: return True, None
        return (origin in await self.partners()), None

    async def check_event_for_spam(self, event):
        ok, _ = await self.check_event_allowed(event, {})
        if ok:
            try:
                from synapse.module_api import NOT_SPAM
                return NOT_SPAM
            except ImportError: return "NOT_SPAM"
        try:
            from synapse.api.errors import Codes
            return Codes.FORBIDDEN
        except ImportError: return "M_FORBIDDEN"

    async def on_create_room(self, requester, request_content: dict, is_requester_admin: bool):
        shared = any(isinstance(e, dict) and e.get("type") == "com.amerteams.shared" for e in request_content.get("initial_state", []))
        request_content.setdefault("creation_content", {})["m.federate"] = bool(shared)
