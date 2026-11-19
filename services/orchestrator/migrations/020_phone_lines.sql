-- Phone dial-in bridges and inbound call handling (docs/PHONE_DIALIN.md).
CREATE TABLE IF NOT EXISTS phone_bridges (room_id text PRIMARY KEY, livekit_room text NOT NULL, pin text NOT NULL, dispatch_rule_id text NOT NULL, number text NOT NULL,
  created_by text NOT NULL, created_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS phone_line (id int PRIMARY KEY DEFAULT 1, notify_room text, hunt_group jsonb NOT NULL DEFAULT '[]', greeting text NOT NULL DEFAULT '');
CREATE TABLE IF NOT EXISTS phone_inbound (livekit_room text PRIMARY KEY, caller_masked text NOT NULL, arrived_at timestamptz NOT NULL DEFAULT now(), answered_by text, answered_at timestamptz);
INSERT INTO schema_migrations (version) VALUES (20);
