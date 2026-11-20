-- People and contacts (Teams parity, docs/PEOPLE.md).
CREATE TABLE IF NOT EXISTS people_profile (
  user_id text PRIMARY KEY, email text, phone text, title text, dept text, office text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS people_profile_email ON people_profile (lower(email));
CREATE INDEX IF NOT EXISTS people_profile_phone ON people_profile (phone);
CREATE TABLE IF NOT EXISTS contacts (
  owner text NOT NULL, user_id text NOT NULL, favourite boolean NOT NULL DEFAULT false, note text NOT NULL DEFAULT '',
  added_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (owner, user_id)
);
CREATE TABLE IF NOT EXISTS contact_groups (
  owner text NOT NULL, name text NOT NULL, members jsonb NOT NULL DEFAULT '[]'::jsonb, PRIMARY KEY (owner, name)
);
-- Invitations for people who do not have an account yet: a one-time link to create one.
CREATE TABLE IF NOT EXISTS people_invites (
  token_hash text PRIMARY KEY, inviter text NOT NULL, name text NOT NULL, email text, phone text,
  rooms jsonb NOT NULL DEFAULT '[]'::jsonb,            -- teams/chats to add them to once they join
  created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL,
  claimed_by text, claimed_at timestamptz, added boolean NOT NULL DEFAULT false
);
