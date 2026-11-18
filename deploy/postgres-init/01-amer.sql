-- Runs once on first start of the PostgreSQL volume.
-- 'synapse' DB (UTF8, C collation) is created by POSTGRES_DB + POSTGRES_INITDB_ARGS.
CREATE DATABASE amer OWNER synapse ENCODING 'UTF8';
