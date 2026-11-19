-- Guest accounts (docs/GUEST_ACCOUNTS.md): external people with a real, limited account that expires.
CREATE TABLE IF NOT EXISTS guest_accounts (user_id text PRIMARY KEY, sponsor text NOT NULL, email_domain text NOT NULL DEFAULT '',
  created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL, deactivated_at timestamptz);
INSERT INTO schema_migrations (version) VALUES (14);
