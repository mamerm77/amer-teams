# Compliance archiving (business tenants)

Public users: **never archived**. All content stays end-to-end encrypted and only the participants can read it.

Business tenants can switch archiving on (Teams Purview equivalent). Archiving keeps end-to-end encryption
intact. The organisation, not the server operator, holds the content, through an **archiving account** that is
an ordinary participant.

## How it works
1. An administrator creates the archiving account (Users → Create user, e.g. `archive`). They then configure the tenant:
   `POST /v1/admin/tenants {tenant, name, compliance_enabled: true, compliance_user: "@archive:<server>", retention_days}`
   and assign members with `POST /v1/admin/tenants/members`.
2. The **archiver service** runs as that account:
   `docker compose --profile compliance up -d archiver`, with `ARCHIVER_USER` and `ARCHIVER_PASSWORD` in `.env`.
   Its device and keys persist in the `archiver` volume.
3. The **app** of every tenant member adds the archiving account to each conversation the member can invite into.
   It does this at sign-in and every 5 minutes. Each archived chat shows a notice: *"This chat is archived by
   <organisation> for compliance"*.
4. Being a member, the archiver receives the room keys through standard Megolm key sharing. It decrypts every
   event and stores it in `compliance_archive`.

## Rules
| Rule | Enforced by |
|---|---|
| Joins only when invited by a member of a tenant whose archiving account it is. Every other invite is rejected, so public users cannot be archived. | archiver |
| Cannot be enabled for the `public` tenant | orchestrator API |
| Every event is kept, including edits, reactions, polls and call signalling. A deleted message stays, and the deletion is archived as its own event (as in Purview). | archiver |
| An event it cannot decrypt is stored as `undecryptable` with its session ID, and the key is requested. Gaps are visible, never silent. | archiver |
| One hash chain per tenant. Rows can never be updated. They can be deleted only by the retention purge, and only once past the tenant's retention. | **PostgreSQL trigger** |
| Search, export and verification are administrator-only, and each is written to the audit log | orchestrator |

Conversations from before the archiving account joined are not archived. Matrix does not share room keys
retroactively with new members, by design.

## Administrator API
| Endpoint | Purpose |
|---|---|
| `GET /v1/admin/compliance/search?tenant=&sender=&room=&q=&since=&until=` | Full-text and filtered search |
| `GET /v1/admin/compliance/export?tenant=…` | NDJSON export with each record's `hash` and `prev_hash` (e-discovery) |
| `GET /v1/admin/compliance/verify?tenant=` | Recomputes the tenant's hash chain, and reports where it breaks |

## Verified (tests/compliance_test.py, live, 20 checks)
- **Archiving behaviour:**
  - the archiver joins only on a compliance-tenant invite
  - messages, edits, reactions and deletions are archived decrypted
  - nothing in the test was undecryptable
- **Encryption:** Synapse's own database holds only ciphertext for the same messages.
- **Public users:** a public user's invite is rejected and nothing of theirs is archived.
- **Administrator access:**
  - search is administrator-only, and works by text and by person
  - export works with hashes
  - the hash chain verifies
  - searches and exports are audited
- **Integrity:**
  - an UPDATE is refused
  - a DELETE outside the purge is refused
  - even the purge cannot remove rows still within retention
- **Tampering:** a database administrator who disables the trigger and edits a row is **detected** by the hash chain.
