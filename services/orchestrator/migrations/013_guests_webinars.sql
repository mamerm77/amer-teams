-- Guest links, webinar registration and Q&A support (docs/GUESTS.md, docs/WEBINARS.md). Codes are stored hashed.
CREATE TABLE IF NOT EXISTS guest_links (code_hash text PRIMARY KEY, room_id text NOT NULL, call_id text NOT NULL, created_by text NOT NULL,
  attendee boolean NOT NULL DEFAULT false, name text NOT NULL DEFAULT '', expires_at timestamptz NOT NULL, uses int NOT NULL DEFAULT 0, max_uses int NOT NULL DEFAULT 50);
CREATE TABLE IF NOT EXISTS webinars (slug text PRIMARY KEY, room_id text NOT NULL, call_id text NOT NULL, title text NOT NULL, starts_at timestamptz,
  created_by text NOT NULL, open boolean NOT NULL DEFAULT true, capacity int NOT NULL DEFAULT 500);
CREATE TABLE IF NOT EXISTS webinar_registrations (slug text NOT NULL REFERENCES webinars(slug) ON DELETE CASCADE, email text NOT NULL, name text NOT NULL,
  code_hash text NOT NULL, registered_at timestamptz NOT NULL DEFAULT now(), joined_at timestamptz, PRIMARY KEY (slug, email));
INSERT INTO schema_migrations (version) VALUES (13);
