-- Object inventory (everything SPEC.md names must exist) and view / index / partition behaviour.
DO $t$
DECLARE
  v_name text;
  v_n integer;
BEGIN
  -- extensions
  FOREACH v_name IN ARRAY ARRAY['btree_gist', 'pg_cron', 'pg_stat_statements', 'pgcrypto'] LOOP
    PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_extension WHERE extname = v_name), 'extension ' || v_name);
  END LOOP;
  -- tables (22 in the spec + rollup/failure helpers)
  FOREACH v_name IN ARRAY ARRAY['users','roles','permissions','role_permissions','project_members','api_keys',
      'projects','quotas','nodes','resource_types','resources','compute_instances','storage_volumes','networks',
      'network_attachments','pricing_plans','allocations','usage_metrics','billing_cycles','invoices',
      'invoice_line_items','payments','log_entries','alert_rules','alert_events','audit_log'] LOOP
    PERFORM pg_temp.assert(to_regclass('public.' || v_name) IS NOT NULL, 'table ' || v_name);
  END LOOP;
  -- triggers
  FOREACH v_name IN ARRAY ARRAY['trg_audit','trg_audit_immutable','trg_touch_updated_at','trg_state_machine',
      'trg_metric_alert','trg_allocation_close','trg_resource_total','trg_attachment_ip','trg_payment_settle'] LOOP
    PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_trigger WHERE tgname = v_name AND NOT tgisinternal), 'trigger ' || v_name);
  END LOOP;
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_trigger WHERE tgname = 'trg_audit') = 5, 'trg_audit on five tables');
  -- procedures / functions
  FOREACH v_name IN ARRAY ARRAY['sp_provision_vm','sp_provision_vm_unsafe','sp_create_volume','sp_create_network',
      'sp_terminate_resource','fn_next_free_ip','fn_resource_cost','sp_generate_invoices','fn_has_permission',
      'sp_ingest_metrics','sp_ingest_logs','sp_rollup_and_retention','fn_audit'] LOOP
    PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_proc WHERE proname = v_name), 'function ' || v_name);
  END LOOP;
  -- views
  FOREACH v_name IN ARRAY ARRAY['v_active_resources','v_project_cost_mtd','v_open_alerts','v_user_effective_permissions'] LOOP
    PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_views WHERE viewname = v_name), 'view ' || v_name);
  END LOOP;
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_matviews WHERE matviewname = 'mv_daily_usage'), 'materialized view');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE indexname = 'mv_daily_usage_uq' AND indexdef LIKE '%UNIQUE%'),
                         'unique index on the matview (required for CONCURRENTLY)');
  -- roles
  FOREACH v_name IN ARRAY ARRAY['crms_app','crms_collector','crms_readonly'] LOOP
    PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_roles WHERE rolname = v_name AND NOT rolsuper AND NOT rolbypassrls), 'role ' || v_name || ' is unprivileged');
  END LOOP;
  -- RLS flags
  FOREACH v_name IN ARRAY ARRAY['resources','invoices','usage_metrics','log_entries'] LOOP
    PERFORM pg_temp.assert((SELECT relrowsecurity FROM pg_class WHERE oid = ('public.' || v_name)::regclass), 'RLS enabled on ' || v_name);
  END LOOP;
  -- partitioning
  PERFORM pg_temp.assert((SELECT relkind FROM pg_class WHERE relname = 'usage_metrics') = 'p', 'usage_metrics is partitioned');
  PERFORM pg_temp.assert((SELECT relkind FROM pg_class WHERE relname = 'log_entries') = 'p', 'log_entries is partitioned');
  SELECT count(*) INTO v_n FROM pg_inherits WHERE inhparent = 'usage_metrics'::regclass;
  PERFORM pg_temp.assert(v_n >= 3, 'monthly partitions exist: ' || v_n);
  -- indexes named in the spec
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE tablename = 'usage_metrics' AND indexdef LIKE '%(resource_id, metric, ts DESC)%'), 'composite metrics index');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE tablename = 'usage_metrics' AND indexdef LIKE '%USING brin (ts)%'), 'BRIN on ts');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE tablename = 'resources' AND indexdef LIKE '%(project_id)%' AND indexdef LIKE '%WHERE%terminated%'), 'partial index on live resources');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE tablename = 'log_entries' AND indexdef LIKE '%gin (attrs)%'), 'GIN on attrs');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE tablename = 'log_entries' AND indexdef LIKE '%to_tsvector%'), 'GIN full-text on message');
  -- partition-local index exists on a child too
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM pg_indexes WHERE tablename LIKE 'usage_metrics\_20%' AND indexdef LIKE '%(resource_id, metric, ts DESC)%'), 'indexes cascade to partitions');
  -- exclusion constraints
  PERFORM pg_temp.assert((SELECT count(*) FROM pg_constraint WHERE contype = 'x') >= 3, 'EXCLUDE constraints (pricing, allocations, cycles)');
  -- pg_cron jobs
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'crms_refresh_daily_usage' AND schedule = '0 * * * *'), 'hourly matview refresh scheduled');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'crms_rollup_retention'), 'retention scheduled');
  -- >= 1M raw metric rows seeded
  PERFORM pg_temp.assert((SELECT count(*) FROM usage_metrics) >= 1000000, 'at least 1M seeded metric rows');
  -- seed shape
  PERFORM pg_temp.assert((SELECT count(*) FROM resources WHERE source = 'discovered' AND type_id = 1) >= 6, 'seeded containers');
  PERFORM pg_temp.assert((SELECT count(*) FROM storage_volumes) >= 2 AND (SELECT count(*) FROM networks) >= 2, 'seeded volumes and networks');
END $t$;

-- ----- views (as the admin user: the definer views filter on crms.user_id) -----
SELECT set_config('crms.user_id', pg_temp.uid('admin@crms.test')::text, true);
DO $t$
DECLARE
  v_n integer;
  v_cost numeric;
BEGIN
  PERFORM pg_temp.assert((SELECT vcpus FROM v_active_resources WHERE name = 'web-1') = 2, 'v_active_resources joins compute subtype');
  PERFORM pg_temp.assert((SELECT image FROM v_active_resources WHERE name = 'web-1') = 'nginx:1.27', 'image');
  PERFORM pg_temp.assert((SELECT size_gb FROM v_active_resources WHERE name = 'pgdata') = 100, 'joins storage subtype');
  PERFORM pg_temp.assert((SELECT cidr FROM v_active_resources WHERE name = 'web-net') = '10.10.1.0/24', 'joins network subtype');
  PERFORM pg_temp.assert((SELECT ips FROM v_active_resources WHERE name = 'web-1') LIKE '10.10.1.%', 'attached ip listed');
  PERFORM pg_temp.assert((SELECT type FROM v_active_resources WHERE name = 'etl-1') = 'compute', 'type name');
  UPDATE resources SET state = 'terminated' WHERE name = 'notebook-1';
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_active_resources WHERE name = 'notebook-1'), 'terminated resources leave the view');

  SELECT cost_mtd INTO v_cost FROM v_project_cost_mtd WHERE project_name = 'Web Platform';
  PERFORM pg_temp.assert(v_cost > 0, 'month-to-date cost is positive: ' || v_cost);
  PERFORM pg_temp.assert(v_cost = (SELECT coalesce(sum(fn_resource_cost(resource_id, date_trunc('month', now()), now())), 0)
                                     FROM resources WHERE project_id = pg_temp.pid('Web Platform')),
                         'cost view equals the sum of fn_resource_cost');
  PERFORM pg_temp.assert((SELECT cost_mtd FROM v_project_cost_mtd WHERE project_name = 'Unassigned') = 0, 'idle project costs 0');

  -- (the live collector resolves seeded events, so open one explicitly)
  INSERT INTO alert_events (rule_id, resource_id, peak_value)
  SELECT ar.rule_id, r.resource_id, 97 FROM resources r JOIN alert_rules ar ON ar.project_id = r.project_id AND ar.metric = 'cpu_percent'
   WHERE r.name = 'web-2';
  PERFORM pg_temp.assert((SELECT count(*) FROM v_open_alerts WHERE resource_name = 'web-2' AND metric = 'cpu_percent') = 1, 'open alert shown');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_open_alerts o JOIN alert_events e USING (event_id) WHERE e.resolved_at IS NOT NULL), 'resolved alerts hidden');
  PERFORM pg_temp.assert((SELECT count(*) FROM v_alert_history) > (SELECT count(*) FROM v_open_alerts), 'history includes resolved events');

  -- effective permissions follow the role hierarchy upward
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'alice@crms.test' AND project_name = 'Web Platform'
                                   AND action = 'delete' AND resource_type = 'compute' AND inherited_from = 'manager'), 'manager own permission');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'alice@crms.test' AND project_name = 'Web Platform'
                                   AND action = 'create' AND resource_type = 'compute' AND inherited_from = 'developer'), 'inherited from developer');
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'alice@crms.test' AND project_name = 'Web Platform'
                                   AND action = 'view' AND resource_type = 'resource' AND inherited_from = 'viewer'), 'inherited from viewer, two levels up');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'carol@crms.test' AND action <> 'view'), 'viewer only views');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM v_user_effective_permissions WHERE email = 'bob@crms.test' AND project_name = 'Data Lab' AND action <> 'view'), 'bob views only in Data Lab');
  -- the view agrees with fn_has_permission
  PERFORM pg_temp.assert(NOT EXISTS (
    SELECT 1 FROM v_user_effective_permissions v
     WHERE NOT fn_has_permission(v.user_id, v.project_id, v.action, v.resource_type)), 'view and function agree');

  -- materialized view
  PERFORM pg_temp.assert((SELECT count(*) FROM mv_daily_usage) > 100, 'matview populated');
  REFRESH MATERIALIZED VIEW CONCURRENTLY mv_daily_usage;
  PERFORM pg_temp.assert((SELECT count(*) FROM v_daily_usage WHERE resource_name = 'web-1' AND metric = 'cpu_percent') >= 30, 'daily usage per day');
  PERFORM pg_temp.assert((SELECT max(samples) FROM mv_daily_usage WHERE metric = 'cpu_percent') BETWEEN 1400 AND 1441, 'about 1440 per-minute samples per full day');

  -- chart helper
  SELECT count(*) INTO v_n FROM fn_metric_series(pg_temp.rid('web-1'), 'cpu_percent', now() - interval '1 day', now(), 300);
  PERFORM pg_temp.assert(v_n BETWEEN 287 AND 289, '24h at 5 minute buckets is ~288 points, got ' || v_n);
END $t$;
