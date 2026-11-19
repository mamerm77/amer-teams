-- Feature flags per tenant (docs/FEATURE_FLAGS.md). Tenant '*' applies to every tenant without its own row.
CREATE TABLE IF NOT EXISTS flags (tenant text NOT NULL, feature text NOT NULL, enabled boolean NOT NULL, rollout_pct int NOT NULL DEFAULT 100 CHECK (rollout_pct BETWEEN 0 AND 100),
  updated_at timestamptz NOT NULL DEFAULT now(), PRIMARY KEY (tenant, feature));
INSERT INTO schema_migrations (version) VALUES (11);
