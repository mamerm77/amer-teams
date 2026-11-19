-- Find-a-time (docs/FIND_A_TIME.md): free/busy blocks only (no titles, no rooms), working hours, time zone,
-- optional prayer-time and Ramadan settings, as published by each user's own app.
CREATE TABLE IF NOT EXISTS calendar_freebusy (user_id text PRIMARY KEY, data jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_migrations (version) VALUES (8);
