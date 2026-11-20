-- Missed activity emails (Teams parity, docs/PEOPLE.md): unread counts per chat from Synapse's push notifications
-- (counts only; message content stays end-to-end encrypted), and each person's email frequency.
CREATE TABLE IF NOT EXISTS missed_activity (
  user_id text NOT NULL, room_id text NOT NULL, unread int NOT NULL DEFAULT 0, last_at timestamptz NOT NULL DEFAULT now(),
  PRIMARY KEY (user_id, room_id)
);
CREATE TABLE IF NOT EXISTS missed_email (
  user_id text PRIMARY KEY, frequency text NOT NULL DEFAULT 'hourly',   -- off | hourly | daily (Teams offers a similar choice)
  last_sent timestamptz
);
