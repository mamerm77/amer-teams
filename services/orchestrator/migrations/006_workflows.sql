-- Plain-language workflows (docs/WORKFLOWS.md). Definitions are versioned: a save never overwrites a version,
-- and a run is pinned to the version it started with. Runs hold status and metadata only, never message content.
CREATE TABLE IF NOT EXISTS workflows (
  id text NOT NULL, version int NOT NULL, owner text NOT NULL, name text NOT NULL,
  definition jsonb NOT NULL, enabled boolean NOT NULL DEFAULT false, created_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (id, version));
CREATE INDEX IF NOT EXISTS workflows_owner ON workflows (owner);
CREATE TABLE IF NOT EXISTS workflow_runs (
  id text PRIMARY KEY, workflow_id text NOT NULL, version int NOT NULL, owner text NOT NULL,
  status text NOT NULL, trigger jsonb NOT NULL DEFAULT '{}', step_results jsonb NOT NULL DEFAULT '{}',
  started_at timestamptz NOT NULL DEFAULT now(), ended_at timestamptz, idem text);
CREATE INDEX IF NOT EXISTS workflow_runs_wf ON workflow_runs (workflow_id, started_at DESC);
CREATE TABLE IF NOT EXISTS workflow_hosts (host text PRIMARY KEY, approved_at timestamptz NOT NULL DEFAULT now());
INSERT INTO schema_migrations (version) VALUES (6);
