-- Triggers: audit, immutable audit, updated_at, state machine, allocation close, totality,
-- metric alerts, payment settlement.
DO $t$
DECLARE
  alice integer := pg_temp.uid('alice@crms.test');
  wp    integer := pg_temp.pid('Web Platform');
  dl    integer := pg_temp.pid('Data Lab');
  v_n   integer;
  v_id  integer;
  v_row audit_log%ROWTYPE;
  v_at  timestamptz;
BEGIN
  ----- trg_audit (generic function, actor from crms.user_id, composite pks) -----
  PERFORM set_config('crms.user_id', alice::text, true);
  SELECT count(*) INTO v_n FROM audit_log;
  UPDATE quotas SET max_units = max_units + 1 WHERE project_id = wp AND resource_type_id = 1;
  SELECT * INTO v_row FROM audit_log ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.assert(v_row.table_name = 'quotas' AND v_row.op = 'UPDATE', 'quota update audited');
  PERFORM pg_temp.assert(v_row.actor_id = alice, 'audit records the acting user');
  PERFORM pg_temp.assert(v_row.row_pk = wp || ',1', 'composite pk captured: ' || v_row.row_pk);
  PERFORM pg_temp.assert((v_row.new_data ->> 'max_units')::int = (v_row.old_data ->> 'max_units')::int + 1, 'old/new images differ by 1');

  UPDATE resources SET name = 'web-1-renamed' WHERE name = 'web-1';
  SELECT * INTO v_row FROM audit_log ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.assert(v_row.table_name = 'resources' AND v_row.old_data ->> 'name' = 'web-1', 'resource update audited');
  UPDATE resources SET name = 'web-1-renamed' WHERE name = 'web-1-renamed';       -- no change: no audit row
  SELECT count(*) INTO v_n FROM audit_log;
  UPDATE resources SET name = 'web-1-renamed' WHERE name = 'web-1-renamed';
  PERFORM pg_temp.assert((SELECT count(*) FROM audit_log) = v_n, 'no-op update is not audited');

  INSERT INTO project_members VALUES (dl, alice, (SELECT role_id FROM roles WHERE name = 'viewer'));
  SELECT * INTO v_row FROM audit_log ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.assert(v_row.table_name = 'project_members' AND v_row.op = 'INSERT' AND v_row.old_data IS NULL, 'member insert audited');
  DELETE FROM project_members WHERE project_id = dl AND user_id = alice;
  SELECT * INTO v_row FROM audit_log ORDER BY audit_id DESC LIMIT 1;
  PERFORM pg_temp.assert(v_row.op = 'DELETE' AND v_row.new_data IS NULL, 'member delete audited');

  INSERT INTO pricing_plans (type_id, unit_price, effective_from, effective_to)
  VALUES (3, 0.02, now() - interval '200 days', now() - interval '150 days');
  PERFORM pg_temp.assert((SELECT table_name FROM audit_log ORDER BY audit_id DESC LIMIT 1) = 'pricing_plans', 'pricing audited');
  UPDATE invoices SET status = 'void' WHERE invoice_id = 3;
  PERFORM pg_temp.assert((SELECT table_name FROM audit_log ORDER BY audit_id DESC LIMIT 1) = 'invoices', 'invoice audited');

  ----- trg_audit_immutable -----
  PERFORM pg_temp.expect_message($$UPDATE audit_log SET op = 'DELETE' WHERE audit_id = 1$$, '%append-only%', 'audit UPDATE blocked');
  PERFORM pg_temp.expect_message($$DELETE FROM audit_log$$, '%append-only%', 'audit DELETE blocked');
  PERFORM pg_temp.expect_message($$TRUNCATE audit_log$$, '%append-only%', 'audit TRUNCATE blocked');

  ----- trg_touch_updated_at -----
  UPDATE users SET updated_at = '2000-01-01', name = 'Alice R.' WHERE user_id = alice;
  PERFORM pg_temp.assert((SELECT updated_at FROM users WHERE user_id = alice) = now(), 'users.updated_at touched');
  UPDATE resources SET updated_at = '2000-01-01', name = 'web-1' WHERE name = 'web-1-renamed';
  PERFORM pg_temp.assert((SELECT updated_at FROM resources WHERE name = 'web-1') = now(), 'resources.updated_at touched');

  ----- trg_state_machine -----
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 1, 'sm-test') RETURNING resource_id INTO v_id;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (v_id, 1, 512);
  PERFORM pg_temp.expect_message(format($$UPDATE resources SET state = 'stopped' WHERE resource_id = %s$$, v_id), 'Illegal state transition: pending -> stopped', 'pending->stopped illegal');
  UPDATE resources SET state = 'running' WHERE resource_id = v_id;
  PERFORM pg_temp.expect_message(format($$UPDATE resources SET state = 'pending' WHERE resource_id = %s$$, v_id), 'Illegal state transition: running -> pending', 'running->pending illegal');
  UPDATE resources SET state = 'stopped' WHERE resource_id = v_id;
  PERFORM pg_temp.expect_message(format($$UPDATE resources SET state = 'pending' WHERE resource_id = %s$$, v_id), 'Illegal%', 'stopped->pending illegal');
  UPDATE resources SET state = 'running' WHERE resource_id = v_id;
  UPDATE resources SET state = 'stopped' WHERE resource_id = v_id;
  UPDATE resources SET state = 'terminated' WHERE resource_id = v_id;
  PERFORM pg_temp.expect_message(format($$UPDATE resources SET state = 'running' WHERE resource_id = %s$$, v_id), 'Illegal state transition: terminated -> running', 'terminated is final');
  PERFORM pg_temp.expect_message(format($$UPDATE resources SET state = 'pending' WHERE resource_id = %s$$, v_id), 'Illegal%', 'terminated->pending illegal');

  ----- trg_allocation_close: created and terminated in one transaction still leaves a valid range -----
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 1, 'alloc-test') RETURNING resource_id INTO v_id;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (v_id, 1, 512);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_id, wp, tstzrange(now(), NULL));
  UPDATE resources SET state = 'running' WHERE resource_id = v_id;
  UPDATE resources SET state = 'terminated' WHERE resource_id = v_id;
  PERFORM pg_temp.assert((SELECT NOT upper_inf(period) AND NOT isempty(period) FROM allocations WHERE resource_id = v_id),
                         'allocation closed on termination');
  -- and for an older allocation the range ends at now()
  SELECT resource_id INTO v_id FROM resources WHERE name = 'staging-web-1';
  UPDATE resources SET state = 'terminated' WHERE resource_id = v_id;
  PERFORM pg_temp.assert((SELECT upper(period) = now() FROM allocations WHERE resource_id = v_id), 'open allocation closed at now()');

  ----- trg_resource_total (constraint trigger) accepts resource + subtype in one transaction -----
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 2, 'total-ok') RETURNING resource_id INTO v_id;
  INSERT INTO storage_volumes (resource_id, size_gb) VALUES (v_id, 1);
  SET CONSTRAINTS ALL IMMEDIATE;
  SET CONSTRAINTS ALL DEFERRED;

  ----- trg_payment_settle -----
  UPDATE invoices SET status = 'issued' WHERE invoice_id = 3;
  DELETE FROM payments WHERE invoice_id = 3 AND false;
  SELECT total INTO v_n FROM invoices WHERE invoice_id = 6;
  INSERT INTO payments (invoice_id, amount) VALUES (6, 1);
  PERFORM pg_temp.assert((SELECT status FROM invoices WHERE invoice_id = 6) = 'issued', 'partial payment keeps invoice open');
  INSERT INTO payments (invoice_id, amount) SELECT 6, total - 1 FROM invoices WHERE invoice_id = 6;
  PERFORM pg_temp.assert((SELECT status FROM invoices WHERE invoice_id = 6) = 'paid', 'full payment settles invoice');
  UPDATE invoices SET status = 'void' WHERE invoice_id = 5;
  PERFORM pg_temp.expect_message($$INSERT INTO payments (invoice_id, amount) VALUES (5, 1)$$, '%cannot be paid%', 'void invoice cannot be paid');
END $t$;

-- trg_metric_alert: Web Platform rule "cpu_percent > 85 over 300s".
DO $t$
DECLARE
  w   integer := pg_temp.rid('worker-1');
  t0  timestamptz := date_trunc('minute', now()) + interval '10 days';
  v_rule integer;
BEGIN
  SELECT rule_id INTO v_rule FROM alert_rules
   WHERE project_id = pg_temp.pid('Web Platform') AND metric = 'cpu_percent';
  INSERT INTO usage_metrics VALUES (w, t0, 'cpu_percent', 70);
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM alert_events WHERE rule_id = v_rule AND resource_id = w), 'below threshold: no alert');
  INSERT INTO usage_metrics VALUES (w, t0 + interval '1 minute', 'cpu_percent', 99);   -- avg 84.5, still below
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM alert_events WHERE rule_id = v_rule AND resource_id = w), 'average (not point value) is compared');
  INSERT INTO usage_metrics VALUES (w, t0 + interval '2 minutes', 'cpu_percent', 98);  -- avg 89 -> fires
  PERFORM pg_temp.assert((SELECT count(*) FROM alert_events WHERE rule_id = v_rule AND resource_id = w AND resolved_at IS NULL) = 1, 'breach opens an event');
  INSERT INTO usage_metrics VALUES (w, t0 + interval '3 minutes', 'cpu_percent', 100); -- still breaching: same event, peak updated
  PERFORM pg_temp.assert((SELECT count(*) FROM alert_events WHERE rule_id = v_rule AND resource_id = w) = 1, 'no duplicate open event');
  PERFORM pg_temp.assert((SELECT peak_value FROM alert_events WHERE rule_id = v_rule AND resource_id = w) = 100, 'peak tracks the maximum');
  -- recovery: low values pull the 5-minute average under 85
  INSERT INTO usage_metrics VALUES (w, t0 + interval '4 minutes', 'cpu_percent', 5);
  INSERT INTO usage_metrics VALUES (w, t0 + interval '5 minutes', 'cpu_percent', 5);
  INSERT INTO usage_metrics VALUES (w, t0 + interval '6 minutes', 'cpu_percent', 5);
  PERFORM pg_temp.assert((SELECT resolved_at IS NOT NULL FROM alert_events WHERE rule_id = v_rule AND resource_id = w), 'recovery resolves the event');
  -- a rule of another project never fires for this resource
  INSERT INTO usage_metrics VALUES (w, t0 + interval '7 minutes', 'disk_percent', 99);
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM alert_events e JOIN alert_rules r USING (rule_id)
                                      WHERE e.resource_id = w AND r.metric = 'disk_percent'), 'other metrics/projects unaffected');
END $t$;
