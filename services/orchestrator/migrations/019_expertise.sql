-- Live expertise map (docs/EXPERTISE.md): only what each person chose to publish about themselves.
CREATE TABLE IF NOT EXISTS expertise (user_id text PRIMARY KEY, tenant text NOT NULL, topics jsonb NOT NULL, about text NOT NULL DEFAULT '', updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_migrations (version) VALUES (19);
