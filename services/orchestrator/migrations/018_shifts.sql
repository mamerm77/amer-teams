-- Frontline shifts (docs/FRONTLINE.md): one person cannot hold overlapping shifts; swaps need a manager.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE IF NOT EXISTS shifts (id text PRIMARY KEY, room_id text NOT NULL, user_id text NOT NULL, during tstzrange NOT NULL, role text NOT NULL DEFAULT '',
  created_by text NOT NULL, clock_in timestamptz, clock_out timestamptz, swap_state text NOT NULL DEFAULT 'none', swap_to text, cancelled boolean NOT NULL DEFAULT false,
  EXCLUDE USING gist (user_id WITH =, during WITH &&) WHERE (NOT cancelled));
INSERT INTO schema_migrations (version) VALUES (18);
