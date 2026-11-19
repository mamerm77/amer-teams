-- Agent Ops: AI agent teams that deliver projects, with a live event stream of what each agent does.
CREATE TABLE agentops_projects (
  project_id  text PRIMARY KEY,
  name        text NOT NULL,
  prompt      text NOT NULL,
  workdir     text,
  status      text NOT NULL DEFAULT 'running' CHECK (status IN ('running','done','failed','interrupted')),
  replay      boolean NOT NULL DEFAULT false,
  created_by  text NOT NULL,
  cost_usd    real,
  started_at  timestamptz NOT NULL DEFAULT now(),
  finished_at timestamptz
);
CREATE INDEX agentops_projects_started ON agentops_projects (started_at DESC);

-- Append-only. seq orders events across replicas; clients resume a stream with ?after=<seq>.
CREATE TABLE agentops_events (
  seq        bigserial PRIMARY KEY,
  id         text NOT NULL,
  ts         double precision NOT NULL,
  project_id text NOT NULL,
  type       text NOT NULL,
  agent      text,
  agent_id   text,
  data       jsonb NOT NULL DEFAULT '{}'
);
CREATE INDEX agentops_events_project ON agentops_events (project_id, seq);

INSERT INTO schema_migrations (version) VALUES (5);
