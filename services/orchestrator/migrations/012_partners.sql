-- Partner organisations for shared channels (docs/PARTNERS.md). The one-time handshake code is stored hashed.
CREATE TABLE IF NOT EXISTS partners (server text PRIMARY KEY, state text NOT NULL, code_hash text, note text NOT NULL DEFAULT '', updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_migrations (version) VALUES (12);
