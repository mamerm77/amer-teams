-- Decision ledger (docs/DECISIONS.md): metadata and a hash of the text only; the text stays in the encrypted chat.
CREATE TABLE IF NOT EXISTS decision_pending (
  decision_id text NOT NULL, version int NOT NULL, room_hash text NOT NULL, event_id text NOT NULL, owner text NOT NULL,
  due date, text_hash text NOT NULL, supersedes int, proposed_at bigint NOT NULL, confirmed_by text[] NOT NULL DEFAULT '{}',
  PRIMARY KEY (decision_id, version));
CREATE TABLE IF NOT EXISTS decision_ledger (
  seq bigserial PRIMARY KEY, decision_id text NOT NULL, version int NOT NULL, kind text NOT NULL, room_hash text NOT NULL,
  event_id text NOT NULL, owner text NOT NULL, due date, status text NOT NULL, text_hash text NOT NULL,
  confirmed_by text[] NOT NULL, supersedes int, at bigint NOT NULL, prev_hash text NOT NULL, hash text NOT NULL);
CREATE INDEX IF NOT EXISTS decision_ledger_id ON decision_ledger (decision_id, version);
INSERT INTO schema_migrations (version) VALUES (9);
