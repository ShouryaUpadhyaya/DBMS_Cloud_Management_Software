-- 001: extensions and database roles.
-- Concepts: extensions, least-privilege roles (grants are added in 012_grants.sql).
CREATE EXTENSION IF NOT EXISTS btree_gist;          -- gist support for = on scalars (EXCLUDE constraints)
CREATE EXTENSION IF NOT EXISTS pgcrypto;            -- crypt()/gen_salt() for password + API key hashes
CREATE EXTENSION IF NOT EXISTS pg_stat_statements;  -- query statistics for the DB Lab
CREATE EXTENSION IF NOT EXISTS pg_cron;             -- in-database scheduler (jobs in 011)

SELECT format('CREATE ROLE crms_app LOGIN PASSWORD %L', :'app_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crms_app') \gexec
SELECT format('CREATE ROLE crms_collector LOGIN PASSWORD %L', :'collector_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crms_collector') \gexec
SELECT format('CREATE ROLE crms_readonly LOGIN PASSWORD %L', :'readonly_pw')
 WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname = 'crms_readonly') \gexec
