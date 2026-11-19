-- Meeting rooms, bookings and room devices (docs/ROOMS.md). No double booking: an exclusion constraint on time.
CREATE EXTENSION IF NOT EXISTS btree_gist;
CREATE TABLE IF NOT EXISTS meeting_rooms (id text PRIMARY KEY, name text NOT NULL, site text NOT NULL DEFAULT '', capacity int NOT NULL DEFAULT 6,
  equipment jsonb NOT NULL DEFAULT '[]', device_hash text, active boolean NOT NULL DEFAULT true);
CREATE TABLE IF NOT EXISTS room_bookings (id text PRIMARY KEY, room_id text NOT NULL REFERENCES meeting_rooms(id) ON DELETE CASCADE, during tstzrange NOT NULL,
  organiser text NOT NULL, title text NOT NULL DEFAULT '', show_title boolean NOT NULL DEFAULT false, chat_room text, checked_in_at timestamptz, released_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  EXCLUDE USING gist (room_id WITH =, during WITH &&) WHERE (released_at IS NULL));
INSERT INTO schema_migrations (version) VALUES (17);
