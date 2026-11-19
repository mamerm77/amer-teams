-- Compliance archive for business tenants that enable it (docs/COMPLIANCE.md).
-- Written only by the archiver service (the tenant's archiving account, a normal end-to-end encrypted member of
-- the conversations). One hash chain per tenant. Rows can never be changed. They can be deleted only once they
-- are past the tenant's retention, and only by the purge job.
CREATE TABLE compliance_archive (
  id         bigserial PRIMARY KEY,
  tenant     text NOT NULL REFERENCES tenants ON DELETE RESTRICT,
  room_id    text NOT NULL,
  room_name  text,
  event_id   text NOT NULL UNIQUE,
  sender     text NOT NULL,
  ts         timestamptz NOT NULL,             -- origin_server_ts of the message
  archived_at timestamptz NOT NULL DEFAULT now(),
  type       text NOT NULL,                     -- m.room.message, m.reaction, m.room.redaction, poll, call event ...
  body       text,                              -- plain text for search
  content    jsonb NOT NULL,                    -- full decrypted content
  prev_hash  char(64) NOT NULL,
  hash       char(64) NOT NULL UNIQUE
);
CREATE INDEX compliance_archive_tenant_ts ON compliance_archive (tenant, ts DESC);
CREATE INDEX compliance_archive_sender ON compliance_archive (sender, ts DESC);
CREATE INDEX compliance_archive_room ON compliance_archive (room_id, ts DESC);
CREATE INDEX compliance_archive_body ON compliance_archive USING gin (to_tsvector('simple', coalesce(body, '')));

CREATE FUNCTION compliance_archive_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'compliance_archive is append-only'; END IF;
  -- DELETE: only the purge job (session flag) and only rows past the tenant's retention
  IF coalesce(current_setting('amer.purge', true), '') <> 'on' THEN
    RAISE EXCEPTION 'compliance_archive rows can only be removed by the retention purge';
  END IF;
  IF OLD.ts >= now() - make_interval(days => (SELECT retention_days FROM tenants WHERE tenant = OLD.tenant)) THEN
    RAISE EXCEPTION 'compliance_archive row % is still within retention', OLD.id;
  END IF;
  RETURN OLD;
END $$;
CREATE TRIGGER compliance_archive_guard BEFORE UPDATE OR DELETE ON compliance_archive FOR EACH ROW EXECUTE FUNCTION compliance_archive_guard();

-- Conversations the archiving account has joined, and the tenant they are archived for (the inviter's tenant).
CREATE TABLE compliance_rooms (
  room_id    text PRIMARY KEY,
  tenant     text NOT NULL REFERENCES tenants ON DELETE RESTRICT,
  invited_by text NOT NULL,
  joined_at  timestamptz NOT NULL DEFAULT now()
);

INSERT INTO schema_migrations (version) VALUES (4);
