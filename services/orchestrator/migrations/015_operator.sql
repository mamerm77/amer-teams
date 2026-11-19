-- Operator mode (docs/OPERATOR_MODE.md): incident numbers, states and times, on-call rotas, alerts waiting for a
-- war room. Incident discussion itself stays in the end-to-end encrypted war-room chat.
CREATE TABLE IF NOT EXISTS oncall_rotas (service text PRIMARY KEY, members jsonb NOT NULL, starts date NOT NULL, days_each int NOT NULL DEFAULT 7, escalation text NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS incidents (number text PRIMARY KEY, seq int NOT NULL, severity text NOT NULL, service text NOT NULL, state text NOT NULL,
  room_hash text, declared_by text NOT NULL, source text NOT NULL DEFAULT 'manual', alert_fingerprint text,
  declared_at timestamptz NOT NULL DEFAULT now(), acked_at timestamptz, acked_by text, mitigated_at timestamptz, resolved_at timestamptz);
CREATE UNIQUE INDEX IF NOT EXISTS incidents_alert ON incidents (alert_fingerprint) WHERE alert_fingerprint IS NOT NULL AND resolved_at IS NULL;
INSERT INTO schema_migrations (version) VALUES (15);
