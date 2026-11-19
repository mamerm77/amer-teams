-- Reusable AI skills, custom agents and the organisation's agent marketplace (docs/SKILLS.md).
CREATE TABLE IF NOT EXISTS skills (id text PRIMARY KEY, tenant text NOT NULL, owner text NOT NULL, kind text NOT NULL, name text NOT NULL, description text NOT NULL DEFAULT '',
  instructions text NOT NULL, inputs jsonb NOT NULL DEFAULT '[]', status text NOT NULL DEFAULT 'private', review_note text NOT NULL DEFAULT '', version int NOT NULL DEFAULT 1,
  installs int NOT NULL DEFAULT 0, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE TABLE IF NOT EXISTS skill_installs (user_id text NOT NULL, skill_id text NOT NULL REFERENCES skills(id) ON DELETE CASCADE, at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (user_id, skill_id));
INSERT INTO schema_migrations (version) VALUES (16);
