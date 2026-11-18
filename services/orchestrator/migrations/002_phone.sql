-- Phone network (SIP) policy. Off by default.
CREATE TABLE phone_settings (
  id                int PRIMARY KEY CHECK (id = 1),
  enabled           boolean NOT NULL DEFAULT false,
  allowed_prefixes  text[]  NOT NULL DEFAULT '{}',
  outbound_trunk_id text
);
INSERT INTO schema_migrations (version) VALUES (2);
