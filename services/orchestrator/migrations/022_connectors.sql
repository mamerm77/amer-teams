-- Tool connectors (docs/TOOL_CONNECTORS.md): incoming webhooks that post into a chat through the connectors account.
CREATE TABLE IF NOT EXISTS connectors (id text PRIMARY KEY, room_id text NOT NULL, kind text NOT NULL, name text NOT NULL, token_hash text NOT NULL,
  created_by text NOT NULL, created_at timestamptz NOT NULL DEFAULT now(), last_used timestamptz, uses int NOT NULL DEFAULT 0, enabled boolean NOT NULL DEFAULT true);
INSERT INTO schema_migrations (version) VALUES (22);
