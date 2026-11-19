"""Amer Teams compliance archiver (docs/COMPLIANCE.md).

Runs as a business tenant's archiving account. It is a normal end-to-end encrypted Matrix member: users in a
compliance tenant add it to their conversations (the app does this automatically and shows a notice), Megolm
shares the room keys with it like with any participant, and it stores the decrypted events in the
hash-chained, append-only `compliance_archive` table.

Rules
- It joins only when invited by a member of a tenant whose compliance account is this account. Every other
  invite is rejected, so public users can never be archived.
- Every event is kept, including edits, reactions and deletions. A deletion is archived as its own event and
  the original stays, as in Microsoft Purview.
- Events it cannot decrypt are archived as `undecryptable`, with their session ID, so gaps are visible rather
  than silent. It also requests the missing keys.
- The device and its keys persist in STORE_DIR, so restarts keep the same identity.
"""
import asyncio, hashlib, json, logging, os, time
import psycopg
from nio import (AsyncClient, AsyncClientConfig, InviteMemberEvent, LoginResponse, MegolmEvent, RoomMemberEvent,
                 RoomMessage, UnknownEvent, ReactionEvent, RedactionEvent, Event)

HS = os.getenv("HS", "http://synapse:8008")
USER = os.getenv("ARCHIVER_USER", "archive")
PASSWORD = os.environ.get("ARCHIVER_PASSWORD", "")
DSN = os.getenv("DATABASE_URL", "postgresql://amer:amer@postgres/amer")
STORE = os.getenv("STORE_DIR", "/data/archiver")
logging.basicConfig(level=logging.INFO, format="%(asctime)s archiver %(levelname)s %(message)s")
log = logging.getLogger("archiver")

def db(): return psycopg.connect(DSN, autocommit=True)

def tenant_for_inviter(conn, inviter: str, me: str) -> str | None:
    """The inviter's tenant, if that tenant has compliance on with this account as its archiver."""
    r = conn.execute("""SELECT t.tenant FROM tenant_members m JOIN tenants t ON t.tenant = m.tenant
                        WHERE m.user_id = %s AND t.compliance_enabled AND t.compliance_user = %s""", (inviter, me)).fetchone()
    return r[0] if r else None

def body_of(content: dict) -> str | None:
    if not isinstance(content, dict): return None
    nc = content.get("m.new_content")
    if isinstance(nc, dict) and nc.get("body"): return nc["body"]
    if content.get("body"): return str(content["body"])
    if "org.matrix.msc3381.poll.start" in content:
        p = content["org.matrix.msc3381.poll.start"]
        return f"[poll] {p.get('question', {}).get('body', '')}: " + ", ".join(a.get("org.matrix.msc1767.text", "") for a in p.get("answers", []))
    rel = content.get("m.relates_to") or {}
    if rel.get("rel_type") == "m.annotation": return f"[reaction] {rel.get('key')}"
    return None

def archive(conn, tenant: str, room_id: str, room_name: str | None, event_id: str, sender: str, ts_ms: int, typ: str, content: dict):
    canon = json.dumps(content, sort_keys=True, separators=(",", ":"), ensure_ascii=False)
    with conn.transaction():
        conn.execute("SELECT pg_advisory_xact_lock(hashtext('compliance:' || %s))", (tenant,))     # one writer per tenant chain
        if conn.execute("SELECT 1 FROM compliance_archive WHERE event_id = %s", (event_id,)).fetchone(): return False
        r = conn.execute("SELECT hash FROM compliance_archive WHERE tenant = %s ORDER BY id DESC LIMIT 1", (tenant,)).fetchone()
        prev = r[0] if r else "0" * 64
        h = hashlib.sha256(f"{prev}|{tenant}|{event_id}|{sender}|{ts_ms}|{typ}|{canon}".encode()).hexdigest()
        conn.execute("""INSERT INTO compliance_archive (tenant, room_id, room_name, event_id, sender, ts, type, body, content, prev_hash, hash)
                        VALUES (%s,%s,%s,%s,%s, to_timestamp(%s / 1000.0), %s,%s,%s,%s,%s)""",
                     (tenant, room_id, room_name, event_id, sender, ts_ms, typ, body_of(content), canon, prev, h))
    return True

class Archiver:
    def __init__(self):
        os.makedirs(STORE, exist_ok=True)
        self.sess = os.path.join(STORE, "session.json")
        self.conn = db()
        self.c: AsyncClient | None = None

    async def login(self):
        cfg = AsyncClientConfig(store_sync_tokens=True, encryption_enabled=True)
        if os.path.exists(self.sess):
            s = json.load(open(self.sess))
            self.c = AsyncClient(HS, s["user_id"], device_id=s["device_id"], store_path=STORE, config=cfg)
            self.c.restore_login(s["user_id"], s["device_id"], s["access_token"])
        else:
            server = os.getenv("SERVER_NAME")
            uid = f"@{USER}:{server}" if server else USER
            self.c = AsyncClient(HS, uid, store_path=STORE, config=cfg)
            r = await self.c.login(PASSWORD, device_name="Amer Teams compliance archiver")
            if not isinstance(r, LoginResponse): raise SystemExit(f"archiver login failed: {r}")
            json.dump({"user_id": r.user_id, "device_id": r.device_id, "access_token": r.access_token}, open(self.sess, "w"))
            os.chmod(self.sess, 0o600)
        log.info("signed in as %s (device %s)", self.c.user_id, self.c.device_id)

    def room_tenant(self, room_id):
        r = self.conn.execute("SELECT tenant FROM compliance_rooms WHERE room_id = %s", (room_id,)).fetchone()
        return r[0] if r else None

    async def on_invite(self, room, ev: InviteMemberEvent):
        if ev.state_key != self.c.user_id or ev.membership != "invite": return
        tenant = tenant_for_inviter(self.conn, ev.sender, self.c.user_id)
        if not tenant:
            log.info("rejecting invite to %s from %s: not a member of a compliance tenant archived by this account", room.room_id, ev.sender)
            await self.c.room_leave(room.room_id); return
        await self.c.join(room.room_id)
        self.conn.execute("INSERT INTO compliance_rooms (room_id, tenant, invited_by) VALUES (%s,%s,%s) ON CONFLICT (room_id) DO NOTHING",
                          (room.room_id, tenant, ev.sender))
        log.info("joined %s for tenant %s (invited by %s)", room.room_id, tenant, ev.sender)

    async def on_event(self, room, ev: Event):
        tenant = self.room_tenant(room.room_id)
        if not tenant or ev.sender == self.c.user_id: return
        src = ev.source
        if isinstance(ev, MegolmEvent):           # could not decrypt: keep a visible gap marker and ask for the key
            content = {"session_id": ev.session_id, "sender_key": ev.sender_key, "algorithm": "m.megolm.v1.aes-sha2"}
            typ = "undecryptable"
            try: await self.c.request_room_key(ev)
            except Exception: pass
        else:
            content = src.get("content", {}); typ = src.get("type", type(ev).__name__)
            if typ == "m.room.redaction" and "redacts" in src: content = {**content, "redacts": src["redacts"]}
        if archive(self.conn, tenant, room.room_id, room.display_name, ev.event_id, ev.sender, ev.server_timestamp, typ, content):
            log.info("archived %s %s in %s for %s", typ, ev.event_id, room.room_id, tenant)

    async def keys(self):
        if self.c.should_upload_keys: await self.c.keys_upload()
        if self.c.should_query_keys: await self.c.keys_query()
        if self.c.should_claim_keys: await self.c.keys_claim(self.c.get_users_for_key_claiming())

    async def run(self):
        await self.login()
        self.c.add_event_callback(self.on_invite, InviteMemberEvent)
        for t in (RoomMessage, UnknownEvent, ReactionEvent, RedactionEvent, MegolmEvent, RoomMemberEvent):
            self.c.add_event_callback(self.on_event, t)
        open(os.path.join(STORE, "ready"), "w").write(str(int(time.time())))
        while True:
            try:
                await self.c.sync(timeout=10000, full_state=True)
                await self.keys()
            except Exception as e:
                log.warning("sync failed, retrying: %s", e); await asyncio.sleep(5)

if __name__ == "__main__":
    asyncio.run(Archiver().run())
