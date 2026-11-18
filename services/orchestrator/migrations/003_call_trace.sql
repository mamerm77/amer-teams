-- Call trace (metadata only; content stays end-to-end encrypted unless a tenant enables compliance).
CREATE TABLE call_events (
  id         bigserial PRIMARY KEY,
  ts         timestamptz NOT NULL DEFAULT now(),
  call_id    text NOT NULL,
  source     text NOT NULL CHECK (source IN ('client','media','server')),
  user_id    text,
  device_id  text,
  event      text NOT NULL,          -- invite, ringing, answer, reject, hangup, end, state, participant_joined, track_published, ...
  detail     jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX call_events_call ON call_events (call_id, ts);
CREATE INDEX call_events_ts ON call_events (ts DESC);

-- Per-participant media quality samples reported by clients from WebRTC getStats (every 10 s).
CREATE TABLE call_quality (
  ts           timestamptz NOT NULL DEFAULT now(),
  call_id      text NOT NULL,
  user_id      text NOT NULL,
  device_id    text,
  kind         text NOT NULL CHECK (kind IN ('audio','video')),
  direction    text NOT NULL CHECK (direction IN ('send','recv')),
  codec        text,
  bitrate_kbps real,
  packets      bigint,
  packets_lost bigint,
  loss_pct     real,
  jitter_ms    real,
  rtt_ms       real,
  mos          real
);
CREATE INDEX call_quality_call ON call_quality (call_id, ts);

-- One row per call: who, when, outcome. Maintained from call_events.
CREATE TABLE call_records (
  call_id      text PRIMARY KEY,
  kind         text NOT NULL DEFAULT 'call',     -- call | meeting | phone
  media        text,
  room_hash    text,
  caller       text,
  callee       text,
  started_at   timestamptz NOT NULL DEFAULT now(),
  answered_at  timestamptz,
  ended_at     timestamptz,
  outcome      text,
  duration_s   int,
  participants int NOT NULL DEFAULT 0,
  tenant       text NOT NULL DEFAULT 'public'
);
CREATE INDEX call_records_started ON call_records (started_at DESC);

-- Tenants: public users are metadata-only; a business tenant may enable compliance archiving.
CREATE TABLE tenants (
  tenant              text PRIMARY KEY,
  name                text NOT NULL,
  compliance_enabled  boolean NOT NULL DEFAULT false,
  compliance_user     text,                      -- Matrix ID of the archiving account (holds the org key)
  retention_days      int NOT NULL DEFAULT 90 CHECK (retention_days BETWEEN 1 AND 3650),
  updated_by          text,
  updated_at          timestamptz NOT NULL DEFAULT now()
);
INSERT INTO tenants (tenant, name) VALUES ('public', 'Public users');
CREATE TABLE tenant_members (user_id text PRIMARY KEY, tenant text NOT NULL REFERENCES tenants ON DELETE CASCADE);

INSERT INTO schema_migrations (version) VALUES (3);
