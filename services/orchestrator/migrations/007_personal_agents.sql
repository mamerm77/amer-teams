-- Personal agent teams and the glass box (docs/PERSONAL_AGENTS.md)
ALTER TABLE agentops_projects ADD COLUMN IF NOT EXISTS scope text NOT NULL DEFAULT 'org';
CREATE TABLE IF NOT EXISTS agent_approvals (
  id text PRIMARY KEY, project_id text NOT NULL, owner text NOT NULL, agent text NOT NULL, tool text NOT NULL,
  category text NOT NULL,                          -- write_external | spend | delete
  payload_hash text NOT NULL, payload jsonb NOT NULL, preview jsonb NOT NULL,
  est_tokens int, est_cost_usd real,
  status text NOT NULL DEFAULT 'awaiting',         -- awaiting|approved|edited|rejected|expired|executing|done|failed|refused|cancelled
  decided_by text, decided_at timestamptz, reason text,
  created_at timestamptz NOT NULL DEFAULT now(), expires_at timestamptz NOT NULL);
CREATE INDEX IF NOT EXISTS agent_approvals_owner ON agent_approvals (owner, status);
CREATE TABLE IF NOT EXISTS personal_budgets (user_id text PRIMARY KEY, month date NOT NULL, tokens_used bigint NOT NULL DEFAULT 0, tokens_cap bigint NOT NULL);
INSERT INTO schema_migrations (version) VALUES (7);
