-- 011: views, materialized view, scheduled jobs.
-- Two flavours:
--   * security_invoker views sit on RLS tables, so the CALLER's row-level policies apply;
--   * definer views (default) read tables the app role cannot touch and filter explicitly with
--     fn_can_see_project(), so they are safe to expose.

CREATE VIEW v_active_resources WITH (security_invoker = true) AS
SELECT r.resource_id, r.project_id, p.name AS project_name, rt.name AS type, r.name, r.state, r.source,
       r.external_id, n.hostname AS node, n.region, r.created_at, r.updated_at,
       ci.vcpus, ci.memory_mb, ci.image,
       sv.size_gb, sv.mount_path,
       nw.cidr,
       (SELECT string_agg(host(na.ip), ', ' ORDER BY na.ip) FROM network_attachments na
         WHERE na.resource_id = r.resource_id) AS ips
  FROM resources r
  JOIN projects p ON p.project_id = r.project_id
  JOIN resource_types rt ON rt.type_id = r.type_id
  LEFT JOIN nodes n ON n.node_id = r.node_id
  LEFT JOIN compute_instances ci ON ci.resource_id = r.resource_id
  LEFT JOIN storage_volumes sv ON sv.resource_id = r.resource_id
  LEFT JOIN networks nw ON nw.resource_id = r.resource_id
 WHERE r.state <> 'terminated';

CREATE VIEW v_project_cost_mtd AS
SELECT p.project_id, p.name AS project_name,
       coalesce(sum(s.amount), 0)::numeric(14,2) AS cost_mtd,
       date_trunc('month', now()) AS since
  FROM projects p
  LEFT JOIN allocations a ON a.project_id = p.project_id
  LEFT JOIN LATERAL fn_cost_segments(a.resource_id, date_trunc('month', now()), now(), a.project_id) s ON true
 WHERE fn_can_see_project(p.project_id)
 GROUP BY p.project_id, p.name;

CREATE VIEW v_open_alerts AS
SELECT e.event_id, e.rule_id, ar.project_id, p.name AS project_name, e.resource_id, r.name AS resource_name,
       ar.metric, ar.operator, ar.threshold, ar.window_seconds, e.fired_at, e.peak_value
  FROM alert_events e
  JOIN alert_rules ar ON ar.rule_id = e.rule_id
  JOIN projects p ON p.project_id = ar.project_id
  JOIN resources r ON r.resource_id = e.resource_id
 WHERE e.resolved_at IS NULL AND fn_can_see_project(ar.project_id);

CREATE VIEW v_alert_history AS
SELECT e.event_id, e.rule_id, ar.project_id, p.name AS project_name, e.resource_id, r.name AS resource_name,
       ar.metric, ar.operator, ar.threshold, e.fired_at, e.resolved_at, e.peak_value
  FROM alert_events e
  JOIN alert_rules ar ON ar.rule_id = e.rule_id
  JOIN projects p ON p.project_id = ar.project_id
  JOIN resources r ON r.resource_id = e.resource_id
 WHERE fn_can_see_project(ar.project_id);

CREATE VIEW v_alert_rules AS
SELECT ar.*, p.name AS project_name
  FROM alert_rules ar JOIN projects p USING (project_id)
 WHERE fn_can_see_project(ar.project_id);

-- Effective permissions: walk the role hierarchy upward (recursive CTE) and report from which
-- role each permission is inherited.
CREATE VIEW v_user_effective_permissions AS
WITH RECURSIVE chain(user_id, project_id, role_name, role_id, parent_role_id, via_role) AS (
  SELECT pm.user_id, pm.project_id, r.name, r.role_id, r.parent_role_id, r.name
    FROM project_members pm JOIN roles r ON r.role_id = pm.role_id
  UNION ALL
  SELECT c.user_id, c.project_id, c.role_name, r.role_id, r.parent_role_id, r.name
    FROM chain c JOIN roles r ON r.role_id = c.parent_role_id
)
SELECT u.user_id, u.email, c.project_id, pr.name AS project_name, c.role_name AS role,
       perm.action, perm.resource_type, c.via_role AS inherited_from
  FROM chain c
  JOIN users u ON u.user_id = c.user_id AND u.status = 'active'      -- suspended users have no effective rights
  JOIN projects pr ON pr.project_id = c.project_id
  JOIN role_permissions rp ON rp.role_id = c.role_id
  JOIN permissions perm ON perm.perm_id = rp.perm_id
 WHERE fn_is_admin() OR c.user_id = fn_current_user()
    OR fn_can_see_project(c.project_id) AND fn_has_permission(fn_current_user(), c.project_id, 'manage', 'member');

CREATE VIEW v_projects AS
SELECT p.project_id, p.name, p.owner_id, u.name AS owner_name, p.parent_project_id, p.created_at,
       (SELECT r.name FROM project_members pm JOIN roles r USING (role_id)
         WHERE pm.project_id = p.project_id AND pm.user_id = fn_current_user()) AS my_role
  FROM projects p JOIN users u ON u.user_id = p.owner_id
 WHERE fn_can_see_project(p.project_id);

CREATE VIEW v_project_members AS
SELECT pm.project_id, p.name AS project_name, pm.user_id, u.name AS user_name, u.email, r.name AS role
  FROM project_members pm
  JOIN projects p USING (project_id) JOIN users u USING (user_id) JOIN roles r USING (role_id)
 WHERE fn_can_see_project(pm.project_id);

CREATE VIEW v_users AS
SELECT user_id, email, name, status, created_at FROM users WHERE fn_is_admin() OR user_id = fn_current_user()
   OR EXISTS (SELECT 1 FROM project_members pm WHERE pm.user_id = users.user_id AND fn_can_see_project(pm.project_id));

CREATE VIEW v_roles AS
SELECT r.role_id, r.name, r.parent_role_id, pr.name AS parent_name
  FROM roles r LEFT JOIN roles pr ON pr.role_id = r.parent_role_id;

CREATE VIEW v_quota_usage AS
SELECT q.project_id, p.name AS project_name, rt.name AS resource_type, q.max_units,
       CASE q.resource_type_id
         WHEN 2 THEN (SELECT coalesce(sum(sv.size_gb), 0) FROM resources r JOIN storage_volumes sv USING (resource_id)
                       WHERE r.project_id = q.project_id AND r.state <> 'terminated')
         ELSE (SELECT count(*) FROM resources r
                WHERE r.project_id = q.project_id AND r.type_id = q.resource_type_id AND r.state <> 'terminated')
       END AS used_units
  FROM quotas q JOIN projects p USING (project_id) JOIN resource_types rt ON rt.type_id = q.resource_type_id
 WHERE fn_can_see_project(q.project_id);

CREATE VIEW v_invoices WITH (security_invoker = true) AS
SELECT i.invoice_id, i.project_id, p.name AS project_name, i.cycle_id, lower(c.period) AS period_start,
       upper(c.period) AS period_end, i.total, i.status, i.created_at,
       coalesce((SELECT sum(amount) FROM payments py WHERE py.invoice_id = i.invoice_id), 0)::numeric(14,2) AS paid
  FROM invoices i JOIN projects p USING (project_id) JOIN billing_cycles c USING (cycle_id)
 WHERE fn_can_see_project(i.project_id);

CREATE VIEW v_invoice_lines AS
SELECT li.invoice_id, li.line_no, i.project_id, li.resource_id, r.name AS resource_name,
       li.units, li.unit_price, li.amount
  FROM invoice_line_items li JOIN invoices i USING (invoice_id) JOIN resources r ON r.resource_id = li.resource_id
 WHERE fn_can_see_project(i.project_id);

CREATE VIEW v_billing_cycles AS
SELECT cycle_id, lower(period) AS period_start, upper(period) AS period_end FROM billing_cycles;

CREATE VIEW v_pricing AS
SELECT pp.plan_id, rt.name AS resource_type, pp.unit_price, rt.unit, pp.effective_from, pp.effective_to
  FROM pricing_plans pp JOIN resource_types rt USING (type_id);

-- Raw telemetry through RLS (caller's policies apply).
CREATE VIEW v_usage_metrics WITH (security_invoker = true) AS
SELECT um.resource_id, um.ts, um.metric, um.value FROM usage_metrics um;

CREATE VIEW v_logs WITH (security_invoker = true) AS
SELECT l.log_id, l.resource_id, r.name AS resource_name, r.project_id, l.ts, l.level, l.message, l.attrs
  FROM log_entries l JOIN resources r ON r.resource_id = l.resource_id;

-- Audit trail: admins see everything, others only their own actions.
CREATE VIEW v_audit_log AS
SELECT a.audit_id, a.actor_id, u.name AS actor_name, a.table_name, a.op, a.row_pk, a.old_data, a.new_data, a.at
  FROM audit_log a LEFT JOIN users u ON u.user_id = a.actor_id
 WHERE fn_is_admin() OR a.actor_id = fn_current_user();

CREATE VIEW v_billing_failures AS
SELECT f.* FROM billing_failures f WHERE fn_is_admin();

-- ---------------------------------------------------------------------------------------------
-- Materialized view: daily usage per resource/metric. The UNIQUE index is required for
-- REFRESH MATERIALIZED VIEW CONCURRENTLY (readers are never blocked).
-- ---------------------------------------------------------------------------------------------
CREATE MATERIALIZED VIEW mv_daily_usage AS
SELECT resource_id, date_trunc('day', ts) AS day, metric,
       avg(value) AS avg_value, max(value) AS max_value, min(value) AS min_value, count(*) AS samples
  FROM usage_metrics
 GROUP BY resource_id, date_trunc('day', ts), metric;
CREATE UNIQUE INDEX mv_daily_usage_uq ON mv_daily_usage (resource_id, day, metric);

-- Exposed through a filter: materialized views cannot carry RLS.
CREATE VIEW v_daily_usage AS
SELECT m.resource_id, r.name AS resource_name, r.project_id, m.day, m.metric,
       m.avg_value, m.max_value, m.min_value, m.samples
  FROM mv_daily_usage m JOIN resources r ON r.resource_id = m.resource_id
 WHERE fn_can_see_project(r.project_id);

-- pg_stat_statements needs rights the app role does not have, so a guarded definer function wraps it.
CREATE FUNCTION fn_stat_statements()
RETURNS TABLE (queryid bigint, calls bigint, total_ms numeric, mean_ms numeric, rows bigint, query text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT s.queryid, s.calls, round(s.total_exec_time::numeric, 2), round(s.mean_exec_time::numeric, 3),
         s.rows, left(s.query, 300)
    FROM pg_stat_statements s
   WHERE fn_is_admin()
   ORDER BY s.total_exec_time DESC LIMIT 25
$$;
CREATE VIEW v_stat_statements AS SELECT * FROM fn_stat_statements();

-- Downsampled series for charts: caller's RLS applies (SECURITY INVOKER is the default).
CREATE FUNCTION fn_metric_series(p_resource integer, p_metric text, p_from timestamptz, p_to timestamptz,
                                 p_bucket_seconds integer DEFAULT 300)
RETURNS TABLE (bucket timestamptz, avg_value double precision, max_value double precision)
LANGUAGE sql STABLE AS $$
  SELECT to_timestamp(floor(extract(epoch FROM ts) / p_bucket_seconds) * p_bucket_seconds) AS bucket,
         avg(value), max(value)
    FROM usage_metrics
   WHERE resource_id = p_resource AND metric = p_metric AND ts >= p_from AND ts < p_to
   GROUP BY 1 ORDER BY 1
$$;

-- ---------------------------------------------------------------------------------------------
-- pg_cron (runs inside database "crms", see cron.database_name in the Dockerfile).
-- ---------------------------------------------------------------------------------------------
SELECT cron.schedule('crms_refresh_daily_usage', '0 * * * *',
                     'REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_usage');
SELECT cron.schedule('crms_rollup_retention', '15 3 * * *', 'SELECT sp_rollup_and_retention(30)');
