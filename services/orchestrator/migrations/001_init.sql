-- Amer Teams orchestrator schema v1. Stores metadata only: no message text, no call keys, no transcripts.
CREATE TABLE IF NOT EXISTS schema_migrations (version int PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now());

-- Append-only, hash-chained audit log (tamper evident)
CREATE TABLE audit_log (
  id         bigserial PRIMARY KEY,
  ts         timestamptz NOT NULL DEFAULT now(),
  user_id    text NOT NULL,
  action     text NOT NULL,
  detail     text NOT NULL DEFAULT '',
  prev_hash  char(64) NOT NULL,
  hash       char(64) NOT NULL UNIQUE
);
CREATE INDEX audit_log_ts ON audit_log (ts DESC);
CREATE INDEX audit_log_user ON audit_log (user_id, ts DESC);
CREATE FUNCTION audit_immutable() RETURNS trigger LANGUAGE plpgsql AS
$$ BEGIN RAISE EXCEPTION 'audit_log is append-only'; END $$;
CREATE TRIGGER audit_no_update BEFORE UPDATE OR DELETE ON audit_log FOR EACH ROW EXECUTE FUNCTION audit_immutable();

-- Operator settings for each AI agent (survive restarts)
CREATE TABLE agent_config (
  agent_id   text PRIMARY KEY,
  enabled    boolean NOT NULL DEFAULT true,
  updated_by text,
  updated_at timestamptz NOT NULL DEFAULT now()
);

-- AI usage metrics (no prompt or answer content)
CREATE TABLE ai_requests (
  id         bigserial PRIMARY KEY,
  ts         timestamptz NOT NULL DEFAULT now(),
  user_id    text NOT NULL,
  agent      text NOT NULL,
  status     text NOT NULL CHECK (status IN ('ok','error','blocked')),
  latency_ms integer
);
CREATE INDEX ai_requests_ts ON ai_requests (ts DESC);

-- Call sessions (who joined which call, when). Matrix room ID is hashed.
CREATE TABLE call_sessions (
  id           bigserial PRIMARY KEY,
  call_id      text NOT NULL,
  livekit_room text NOT NULL,
  room_hash    char(64) NOT NULL,
  user_id      text NOT NULL,
  joined_at    timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX call_sessions_call ON call_sessions (call_id);

-- Monitoring history for Performance / HA screens
CREATE TABLE ops_samples (
  ts         timestamptz NOT NULL,
  service    text NOT NULL,
  up         boolean NOT NULL,
  latency_ms real,
  PRIMARY KEY (ts, service)
);
CREATE TABLE media_samples (
  ts           timestamptz PRIMARY KEY,
  active_calls integer,
  participants integer
);
INSERT INTO schema_migrations (version) VALUES (1);
