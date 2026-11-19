-- Quiet hours and priority senders (docs/NOTIFICATIONS.md), with the push keys of the user's devices.
CREATE TABLE IF NOT EXISTS notify_settings (user_id text PRIMARY KEY, data jsonb NOT NULL, updated_at timestamptz NOT NULL DEFAULT now());
CREATE INDEX IF NOT EXISTS notify_settings_pushkeys ON notify_settings USING gin ((data->'pushkeys'));
INSERT INTO schema_migrations (version) VALUES (10);
