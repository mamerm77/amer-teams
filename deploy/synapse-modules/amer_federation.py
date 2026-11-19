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

    async def check_event_allowed(self, event, state_events):
        sender = getattr(event, "sender", "") or ""
        origin = sender.split(":", 1)[1] if ":" in sender else ""
        if not origin or origin == self.server: return True, None
        return (origin in await self.partners()), None

    async def on_create_room(self, requester, request_content: dict, is_requester_admin: bool):
        shared = any(isinstance(e, dict) and e.get("type") == "com.amerteams.shared" for e in request_content.get("initial_state", []))
        request_content.setdefault("creation_content", {})["m.federate"] = bool(shared)
