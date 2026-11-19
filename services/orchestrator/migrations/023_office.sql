-- Virtual office of your own agent team (docs/VIRTUAL_OFFICE.md).
CREATE TABLE IF NOT EXISTS office_agents (owner text NOT NULL, id text NOT NULL, name text NOT NULL, role text NOT NULL, dept text NOT NULL, room text NOT NULL,
  instructions text NOT NULL, status text NOT NULL DEFAULT 'available', enabled boolean NOT NULL DEFAULT true, PRIMARY KEY (owner, id));
CREATE TABLE IF NOT EXISTS office_tasks (id text PRIMARY KEY, owner text NOT NULL, parent text, agent text NOT NULL, title text NOT NULL, brief text NOT NULL,
  status text NOT NULL, result text, needs_approval boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(), updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS office_tasks_owner ON office_tasks (owner, created_at DESC);
CREATE TABLE IF NOT EXISTS office_messages (id bigserial PRIMARY KEY, owner text NOT NULL, task text, sender text NOT NULL, recipient text NOT NULL, body text NOT NULL, at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS office_messages_owner ON office_messages (owner, id DESC);
INSERT INTO schema_migrations (version) VALUES (23);
