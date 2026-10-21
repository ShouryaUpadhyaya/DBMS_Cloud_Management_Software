-- 012: row-level security and least-privilege grants.
--
-- RLS: a row is visible when the transaction's crms.user_id is a member of the row's project,
-- or is an admin. Policies call SECURITY DEFINER helpers (008) so they cannot recurse into
-- their own tables. The table owner (migration superuser) bypasses RLS, which is why the
-- SECURITY DEFINER procedures can write; crms_app / crms_readonly never bypass it.

ALTER TABLE resources     ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoices      ENABLE ROW LEVEL SECURITY;
ALTER TABLE usage_metrics ENABLE ROW LEVEL SECURITY;
ALTER TABLE log_entries   ENABLE ROW LEVEL SECURITY;
-- Children follow their parent so no side door leaks data.
ALTER TABLE compute_instances    ENABLE ROW LEVEL SECURITY;
ALTER TABLE storage_volumes      ENABLE ROW LEVEL SECURITY;
ALTER TABLE networks             ENABLE ROW LEVEL SECURITY;
ALTER TABLE network_attachments  ENABLE ROW LEVEL SECURITY;
ALTER TABLE invoice_line_items   ENABLE ROW LEVEL SECURITY;

CREATE POLICY resources_member ON resources FOR SELECT USING (fn_can_see_project(project_id));
CREATE POLICY invoices_member  ON invoices  FOR SELECT USING (fn_can_see_project(project_id));
-- Uncorrelated IN (SELECT ...) is evaluated once as a hashed subplan, and resources' own RLS
-- applies inside it, so a metric is visible exactly when its resource is.
CREATE POLICY metrics_member ON usage_metrics FOR SELECT
  USING (resource_id IN (SELECT resource_id FROM resources));
CREATE POLICY logs_member ON log_entries FOR SELECT
  USING (resource_id IN (SELECT resource_id FROM resources));
CREATE POLICY compute_member  ON compute_instances   FOR SELECT USING (resource_id IN (SELECT resource_id FROM resources));
CREATE POLICY storage_member  ON storage_volumes     FOR SELECT USING (resource_id IN (SELECT resource_id FROM resources));
CREATE POLICY networks_member ON networks            FOR SELECT USING (resource_id IN (SELECT resource_id FROM resources));
CREATE POLICY attach_member   ON network_attachments FOR SELECT USING (resource_id IN (SELECT resource_id FROM resources));
CREATE POLICY items_member    ON invoice_line_items  FOR SELECT USING (invoice_id IN (SELECT invoice_id FROM invoices));

-- ---------------------------------------------------------------------------------------------
-- Grants. Start from nothing.
-- ---------------------------------------------------------------------------------------------
REVOKE ALL ON ALL TABLES IN SCHEMA public FROM PUBLIC;
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA public FROM PUBLIC;
GRANT USAGE ON SCHEMA public TO crms_app, crms_collector, crms_readonly;

-- crms_app: reads views (and the RLS tables behind the security_invoker ones); every write goes
-- through EXECUTE on sp_* functions. No INSERT/UPDATE/DELETE anywhere, billing tables included.
GRANT SELECT ON v_active_resources, v_project_cost_mtd, v_open_alerts, v_alert_history, v_alert_rules,
      v_user_effective_permissions, v_projects, v_project_members, v_users, v_roles, v_quota_usage,
      v_invoices, v_invoice_lines, v_billing_cycles, v_pricing, v_usage_metrics, v_logs, v_audit_log,
      v_billing_failures, v_daily_usage, v_stat_statements TO crms_app, crms_readonly;
GRANT SELECT ON resources, invoices, usage_metrics, log_entries, compute_instances, storage_volumes,
      networks, network_attachments, invoice_line_items,
      projects, resource_types, nodes, payments, billing_cycles
  TO crms_app;
GRANT EXECUTE ON FUNCTION fn_current_user(), fn_is_admin(), fn_can_see_project(integer),
      fn_has_permission(integer, integer, text, text), fn_next_free_ip(integer),
      fn_cost_segments(integer, timestamptz, timestamptz, integer),
      fn_resource_cost(integer, timestamptz, timestamptz),
      fn_metric_series(integer, text, timestamptz, timestamptz, integer)
  TO crms_app, crms_readonly;
GRANT EXECUTE ON FUNCTION sp_provision_vm(integer, text, integer, integer, integer, text),
      sp_provision_vm_unsafe(integer, text, integer, integer, integer, double precision, text),
      sp_create_volume(integer, text, integer, text), sp_create_network(integer, text, cidr),
      sp_set_resource_state(integer, text), sp_terminate_resource(integer),
      sp_add_member(integer, integer, text), sp_remove_member(integer, integer),
      sp_set_quota(integer, text, integer),
      sp_create_alert_rule(integer, text, text, double precision, integer), sp_delete_alert_rule(integer),
      sp_create_billing_cycle(timestamptz, timestamptz), sp_generate_invoices(integer),
      sp_record_payment(integer, numeric), sp_login(text, text)
  TO crms_app;
-- fn_assert_permission is called from inside definer functions only.

-- crms_collector: ingestion procedures and nothing else.
GRANT EXECUTE ON FUNCTION sp_ingest_metrics(jsonb), sp_ingest_logs(jsonb) TO crms_collector;

-- crms_readonly: SELECT on views plus the tables the named showcase queries read (RLS applies
-- to the four protected tables). Credentials, API keys, audit and migrations stay hidden.
GRANT SELECT ON resources, invoices, usage_metrics, log_entries, compute_instances, storage_volumes,
      networks, network_attachments, invoice_line_items, projects, resource_types, nodes, payments,
      billing_cycles, quotas, allocations, pricing_plans, alert_rules, alert_events, roles, permissions,
      role_permissions, project_members, usage_rollup_daily, mv_daily_usage
  TO crms_readonly;
GRANT SELECT (user_id, email, name, status, created_at, updated_at) ON users TO crms_readonly, crms_app;
