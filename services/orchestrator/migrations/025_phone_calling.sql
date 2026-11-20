-- Teams-style calling on the company line: transfer, call park and forwarding (docs/PHONE_DIALIN.md).
ALTER TABLE phone_inbound ADD COLUMN IF NOT EXISTS transfer_to text;
ALTER TABLE phone_inbound ADD COLUMN IF NOT EXISTS transfer_from text;
ALTER TABLE phone_inbound ADD COLUMN IF NOT EXISTS park_code text;
ALTER TABLE phone_inbound ADD COLUMN IF NOT EXISTS parked_by text;
CREATE UNIQUE INDEX IF NOT EXISTS phone_inbound_park_code ON phone_inbound (park_code) WHERE park_code IS NOT NULL;
CREATE TABLE IF NOT EXISTS phone_forwarding (
  user_id text PRIMARY KEY,
  mode text NOT NULL DEFAULT 'off',          -- off | forward (to target) | also_ring (target rings too) | voicemail
  target text,
  updated_at timestamptz NOT NULL DEFAULT now()
);
