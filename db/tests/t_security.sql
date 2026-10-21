-- RLS isolation, role grants, credential protection, login.
SELECT set_config('t.carol', pg_temp.uid('carol@crms.test')::text, true),
       set_config('t.admin', pg_temp.uid('admin@crms.test')::text, true),
       set_config('t.alice', pg_temp.uid('alice@crms.test')::text, true),
       set_config('t.wp', pg_temp.pid('Web Platform')::text, true),
       set_config('t.dl', pg_temp.pid('Data Lab')::text, true),
       set_config('t.etl', pg_temp.rid('etl-1')::text, true) \gset

-- ===== crms_app as carol (viewer of Web Platform only) =====
SELECT set_config('crms.user_id', current_setting('t.carol'), true);
SET LOCAL ROLE crms_app;
DO $t$
DECLARE
  wp integer := current_setting('t.wp')::int;
  v_n bigint;
BEGIN
  SELECT count(*) INTO v_n FROM resources;
  PERFORM pg_temp.assert(v_n > 0, 'carol sees her resources');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM resources WHERE project_id <> wp), 'RLS: no resource of another project (resources)');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM compute_instances ci WHERE ci.resource_id NOT IN (SELECT resource_id FROM resources)), 'subtype rows follow the parent');
  PERFORM pg_temp.assert((SELECT count(*) FROM compute_instances) = (SELECT count(*) FROM resources WHERE type_id = 1), 'RLS on compute_instances');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM invoices WHERE project_id <> wp), 'RLS: invoices');
  PERFORM pg_temp.assert((SELECT count(*) FROM invoices) = 2, 'carol sees the two Web Platform invoices');
  PERFORM pg_temp.assert((SELECT count(*) FROM invoice_line_items) > 0 AND NOT EXISTS (
      SELECT 1 FROM invoice_line_items li JOIN invoices i USING (invoice_id) WHERE i.project_id <> wp), 'RLS: invoice lines');
  PERFORM pg_temp.assert((SELECT count(*) FROM usage_metrics WHERE ts > now() - interval '1 day') > 0, 'metrics visible for own resources');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM usage_metrics WHERE resource_id = current_setting('t.etl')::int), 'RLS: usage_metrics of another project (etl-1) are invisible');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM usage_metrics m WHERE m.resource_id NOT IN (SELECT resource_id FROM resources)), 'RLS: metrics visible exactly when their resource is');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM log_entries l WHERE l.resource_id NOT IN (SELECT resource_id FROM resources)) AND (SELECT count(*) FROM log_entries) > 0, 'RLS: log_entries');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_active_resources WHERE project_id <> wp), 'view v_active_resources honours RLS');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_logs WHERE project_id <> wp), 'view v_logs honours RLS');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_project_cost_mtd) = 1, 'cost view shows only her project');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_projects) = 1, 'projects view');
  PERFORM pg_temp.assert(fn_resource_cost((SELECT resource_id FROM v_active_resources LIMIT 1), now() - interval '10 days', now()) > 0, 'cost of own resource');
  PERFORM pg_temp.assert(fn_resource_cost(1, now() - interval '10 days', now()) >= 0, 'cost function callable');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_audit_log) = 0, 'carol has made no audited change');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_invoices WHERE project_id <> wp), 'v_invoices');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_daily_usage WHERE project_id <> wp) AND (SELECT count(*) FROM v_daily_usage) > 0, 'v_daily_usage filtered');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_stat_statements) = 0, 'pg_stat_statements is admin only');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email <> 'carol@crms.test'), 'carol sees only her own permissions');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_open_alerts WHERE project_id <> wp), 'alerts filtered');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_billing_failures) = 0, 'billing failures admin only');
END $t$;

-- ===== writes and protected objects are closed to crms_app =====
DO $t$
BEGIN
  PERFORM pg_temp.expect_error($$INSERT INTO invoices (project_id, cycle_id) VALUES (1, 1)$$, '42501', 'no direct INSERT on invoices');
  PERFORM pg_temp.expect_error($$UPDATE invoices SET total = 0$$, '42501', 'no direct UPDATE on invoices');
  PERFORM pg_temp.expect_error($$DELETE FROM invoice_line_items$$, '42501', 'no direct DELETE on invoice_line_items');
  PERFORM pg_temp.expect_error($$INSERT INTO payments (invoice_id, amount) VALUES (1, 1)$$, '42501', 'no direct INSERT on payments');
  PERFORM pg_temp.expect_error($$UPDATE resources SET state = 'terminated'$$, '42501', 'no direct UPDATE on resources');
  PERFORM pg_temp.expect_error($$INSERT INTO usage_metrics VALUES (1, now(), 'cpu_percent', 1)$$, '42501', 'no direct INSERT on usage_metrics');
  PERFORM pg_temp.expect_error($$INSERT INTO audit_log (table_name, op, row_pk) VALUES ('x', 'INSERT', '1')$$, '42501', 'no direct INSERT on audit_log');
  PERFORM pg_temp.expect_error($$SELECT * FROM audit_log$$, '42501', 'audit_log only through the view');
  PERFORM pg_temp.expect_error($$SELECT password_hash FROM users$$, '42501', 'password hashes unreadable');
  PERFORM pg_temp.expect_error($$SELECT * FROM api_keys$$, '42501', 'api_keys unreadable');
  PERFORM pg_temp.expect_error($$SELECT * FROM allocations$$, '42501', 'allocations only via views/functions');
  PERFORM pg_temp.expect_error($$SELECT * FROM billing_failures$$, '42501', 'billing_failures unreadable');
  PERFORM pg_temp.expect_error($$SELECT * FROM mv_daily_usage$$, '42501', 'materialized view only through filtered view');
  PERFORM pg_temp.expect_error($$SELECT sp_ingest_metrics('{}')$$, '42501', 'app role cannot call collector procedures');
  PERFORM pg_temp.expect_error($$SELECT sp_ingest_logs('{}')$$, '42501', 'app role cannot call collector procedures (logs)');
  PERFORM pg_temp.expect_error($$SELECT fn_assert_permission(1, 'view')$$, '42501', 'internal guard not callable');
  PERFORM pg_temp.expect_error($$SELECT * FROM sp_generate_invoices(1)$$, '42501', 'non-admin cannot generate invoices');
  PERFORM pg_temp.expect_error($$SELECT sp_create_billing_cycle(now() - interval '300 days', now() - interval '299 days')$$, '42501', 'non-admin cannot create cycles');
  PERFORM pg_temp.expect_error($$SELECT sp_rollup_and_retention(1)$$, '42501', 'maintenance is not for the app role');
  PERFORM pg_temp.expect_error($$SELECT fn_ensure_partitions(now(), now())$$, '42501', 'partition management is not for the app role');
  PERFORM pg_temp.expect_error($$CREATE TABLE sneaky (a int)$$, '42501', 'no DDL');
  -- a viewer's procedure call is stopped by the permission check, not by missing grants
  PERFORM pg_temp.expect_message($$SELECT sp_create_volume(1, 'x', 1)$$, 'Permission denied%', 'procedure-level authorisation');
END $t$;
RESET ROLE;

-- ===== no user context: nothing visible, procedures refuse =====
SELECT set_config('crms.user_id', '', true);
SET LOCAL ROLE crms_app;
DO $t$
BEGIN
  PERFORM pg_temp.assert((SELECT count(*) FROM resources) = 0, 'no user: no resources');
  PERFORM pg_temp.assert((SELECT count(*) FROM invoices) = 0, 'no user: no invoices');
  PERFORM pg_temp.assert((SELECT count(*) FROM usage_metrics) = 0, 'no user: no metrics');
  PERFORM pg_temp.assert((SELECT count(*) FROM log_entries) = 0, 'no user: no logs');
  PERFORM pg_temp.expect_message($$SELECT sp_create_volume(1, 'x', 1)$$, 'No user context', 'procedures need a user from the app role');
END $t$;
RESET ROLE;

-- ===== admin bypasses RLS =====
SELECT set_config('crms.user_id', current_setting('t.admin'), true);
SET LOCAL ROLE crms_app;
DO $t$
BEGIN
  PERFORM pg_temp.assert((SELECT count(DISTINCT project_id) FROM resources) >= 3, 'admin sees every project');
  PERFORM pg_temp.assert((SELECT count(*) FROM invoices) = 6, 'admin sees all invoices');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_projects) = 4, 'admin sees all projects');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_audit_log) > 10, 'admin sees the audit trail');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_stat_statements) > 0, 'admin sees statement stats');
END $t$;
RESET ROLE;

-- ===== alice (manager of Web Platform + Staging) =====
SELECT set_config('crms.user_id', current_setting('t.alice'), true);
SET LOCAL ROLE crms_app;
DO $t$
BEGIN
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM resources r JOIN projects p USING (project_id) WHERE p.name = 'Data Lab'), 'alice cannot see Data Lab');
  PERFORM pg_temp.assert((SELECT count(DISTINCT project_id) FROM resources) = 2, 'alice sees two projects');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'bob@crms.test'), 'a manager sees permissions of her members');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'dave@crms.test'), '...but not of other projects');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_audit_log WHERE actor_id <> current_setting('crms.user_id')::int) = 0, 'audit view limited to own actions');
END $t$;
-- Writing through a procedure works and RLS does not block the definer function.
SELECT sp_create_volume(current_setting('t.wp')::int, 'rls-vol', 1);
DO $t$
BEGIN
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM v_active_resources WHERE name = 'rls-vol'), 'created volume is visible to its creator');
  PERFORM pg_temp.assert((SELECT actor_id FROM v_audit_log WHERE table_name = 'resources' ORDER BY audit_id DESC LIMIT 1) = current_setting('crms.user_id')::int, 'audit captured alice');
END $t$;
RESET ROLE;

-- ===== login =====
SET LOCAL ROLE crms_app;
DO $t$
BEGIN
  PERFORM pg_temp.assert((SELECT role FROM sp_login('alice@crms.test', 'password123')) = 'manager', 'login returns top role');
  PERFORM pg_temp.assert((SELECT role FROM sp_login('ADMIN@crms.test', 'password123')) = 'admin', 'login is case-insensitive on email');
  PERFORM pg_temp.assert((SELECT role FROM sp_login('carol@crms.test', 'password123')) = 'viewer', 'viewer role');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM sp_login('alice@crms.test', 'wrong')), 'wrong password rejected');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM sp_login('nobody@crms.test', 'password123')), 'unknown user rejected');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM sp_login('erin@crms.test', 'password123')), 'suspended user rejected');
END $t$;
RESET ROLE;
SELECT pg_temp.assert((SELECT password_hash FROM users WHERE email = 'alice@crms.test') LIKE '$2%', 'passwords are stored as bcrypt hashes');

-- ===== crms_collector: ingestion only =====
SET LOCAL ROLE crms_collector;
DO $t$
BEGIN
  PERFORM pg_temp.assert((sp_ingest_logs('{"logs": []}') ->> 'logs')::int = 0, 'collector can ingest logs');
  PERFORM pg_temp.assert((sp_ingest_metrics('{"metrics": []}') ->> 'metrics')::int = 0, 'collector can ingest metrics');
  -- a brand-new discovered resource: the deferred totality trigger must work with the collector's own rights
  PERFORM sp_ingest_metrics('{"node": {"hostname": "sec-node"}, "resources": [{"external_id": "sec-1", "type": "compute", "name": "sec-container"}]}');
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;
  PERFORM pg_temp.expect_error($$SELECT * FROM resources$$, '42501', 'collector cannot read resources');
  PERFORM pg_temp.expect_error($$SELECT * FROM users$$, '42501', 'collector cannot read users');
  PERFORM pg_temp.expect_error($$INSERT INTO usage_metrics VALUES (1, now(), 'cpu_percent', 1)$$, '42501', 'collector cannot write tables directly');
  PERFORM pg_temp.expect_error($$SELECT sp_provision_vm(1, 'x', 1, 1, 1)$$, '42501', 'collector cannot provision');
  PERFORM pg_temp.expect_error($$SELECT * FROM v_active_resources$$, '42501', 'collector cannot read views');
  PERFORM pg_temp.expect_error($$SELECT sp_rollup_and_retention(1)$$, '42501', 'collector cannot run retention');
END $t$;
RESET ROLE;

-- ===== crms_readonly: SELECT only, RLS applies =====
SELECT set_config('crms.user_id', current_setting('t.carol'), true);
SET LOCAL ROLE crms_readonly;
DO $t$
BEGIN
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM resources WHERE project_id <> current_setting('t.wp')::int), 'readonly role is subject to RLS');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_active_resources) > 0, 'readonly reads views');
  PERFORM pg_temp.assert((SELECT count(*) FROM pricing_plans) > 0, 'readonly reads reference tables');
  PERFORM pg_temp.expect_error($$INSERT INTO projects (name, owner_id) VALUES ('x', 1)$$, '42501', 'readonly cannot insert');
  PERFORM pg_temp.expect_error($$DELETE FROM quotas$$, '42501', 'readonly cannot delete');
  PERFORM pg_temp.expect_error($$SELECT sp_create_volume(1, 'x', 1)$$, '42501', 'readonly cannot execute procedures');
  PERFORM pg_temp.expect_error($$SELECT password_hash FROM users$$, '42501', 'readonly cannot read hashes');
  PERFORM pg_temp.expect_error($$SELECT * FROM api_keys$$, '42501', 'readonly cannot read api keys');
  PERFORM pg_temp.expect_error($$SELECT * FROM audit_log$$, '42501', 'readonly cannot read raw audit');
  PERFORM pg_temp.expect_error($$SELECT sp_login('alice@crms.test', 'password123')$$, '42501', 'readonly cannot log in users');
END $t$;
RESET ROLE;
