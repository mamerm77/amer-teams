-- Agents propose concrete actions (post a message, create a task, schedule a meeting). The server never runs them:
-- after you approve, your app runs them with your own keys, so end-to-end encryption is kept.
ALTER TABLE office_tasks ADD COLUMN IF NOT EXISTS actions jsonb NOT NULL DEFAULT '[]'::jsonb;
