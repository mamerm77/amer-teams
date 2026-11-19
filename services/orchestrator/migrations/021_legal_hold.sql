-- Legal hold (docs/LEGAL_HOLD.md): held rooms or people are never purged, and Synapse refuses deletions there.
CREATE TABLE IF NOT EXISTS legal_holds (id text PRIMARY KEY, scope text NOT NULL CHECK (scope IN ('room','user')), target text NOT NULL, matter text NOT NULL,
  placed_by text NOT NULL, placed_at timestamptz NOT NULL DEFAULT now(), released_by text, released_at timestamptz);
CREATE INDEX IF NOT EXISTS legal_holds_active ON legal_holds (scope, target) WHERE released_at IS NULL;
CREATE OR REPLACE FUNCTION compliance_archive_guard() RETURNS trigger LANGUAGE plpgsql AS $$
BEGIN
  IF TG_OP = 'UPDATE' THEN RAISE EXCEPTION 'compliance_archive is append-only'; END IF;
  IF coalesce(current_setting('amer.purge', true), '') <> 'on' THEN
    RAISE EXCEPTION 'compliance_archive rows can only be removed by the retention purge';
  END IF;
  IF OLD.ts >= now() - make_interval(days => (SELECT retention_days FROM tenants WHERE tenant = OLD.tenant)) THEN
    RAISE EXCEPTION 'compliance_archive row % is still within retention', OLD.id;
  END IF;
  IF EXISTS (SELECT 1 FROM legal_holds h WHERE h.released_at IS NULL AND ((h.scope = 'room' AND h.target = OLD.room_id) OR (h.scope = 'user' AND h.target = OLD.sender))) THEN
    RAISE EXCEPTION 'compliance_archive row % is under legal hold', OLD.id;
  END IF;
  RETURN OLD;
END $$;
INSERT INTO schema_migrations (version) VALUES (21);
