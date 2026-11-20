-- Org chart: each person's manager on their contact card (one source for People, Organisation and search).
ALTER TABLE people_profile ADD COLUMN IF NOT EXISTS manager text;
