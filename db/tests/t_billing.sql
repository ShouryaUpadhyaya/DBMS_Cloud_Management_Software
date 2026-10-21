-- Invoice math, savepoint-per-project isolation, frozen prices, payments, rollup/retention.
DO $t$
DECLARE
  admin integer := pg_temp.uid('admin@crms.test');
  v_a integer; v_b integer;               -- two throw-away projects
  v_ra integer; v_rb integer;             -- their VMs
  v_t0 timestamptz := date_trunc('day', now()) - interval '100 days';   -- before any seeded cycle
  v_cycle integer;
  v_inv integer;
  v_res record;
  v_total numeric;
  v_n integer;
BEGIN
  PERFORM set_config('crms.user_id', admin::text, true);
  INSERT INTO projects (name, owner_id) VALUES ('Bill A', admin) RETURNING project_id INTO v_a;
  INSERT INTO projects (name, owner_id) VALUES ('Bill B', admin) RETURNING project_id INTO v_b;

  -- A: 2 vCPU for 10 h (0.03/unit-hour) = 20 units = 0.60; B: 4 vCPU for 5 h = 20 units = 0.60 too, plus 100 GB for 24 h = 0.48
  INSERT INTO resources (project_id, type_id, name) VALUES (v_a, 1, 'a-vm') RETURNING resource_id INTO v_ra;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (v_ra, 2, 512);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_ra, v_a, tstzrange(v_t0 + interval '2 hours', v_t0 + interval '12 hours'));
  INSERT INTO resources (project_id, type_id, name) VALUES (v_b, 1, 'b-vm') RETURNING resource_id INTO v_rb;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (v_rb, 4, 512);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_rb, v_b, tstzrange(v_t0 + interval '1 hour', v_t0 + interval '6 hours'));
  INSERT INTO resources (project_id, type_id, name) VALUES (v_b, 2, 'b-vol') RETURNING resource_id INTO v_n;
  INSERT INTO storage_volumes (resource_id, size_gb) VALUES (v_n, 100);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_n, v_b, tstzrange(v_t0, v_t0 + interval '24 hours'));

  v_cycle := sp_create_billing_cycle(v_t0, v_t0 + interval '1 day');

  -- Project A is already invoiced for this cycle, so its run must fail while B still succeeds.
  INSERT INTO invoices (project_id, cycle_id, total) VALUES (v_a, v_cycle, 0);

  SELECT count(*) FILTER (WHERE outcome = 'invoiced'), count(*) FILTER (WHERE outcome = 'failed')
    INTO v_n, v_total FROM sp_generate_invoices(v_cycle);
  PERFORM pg_temp.assert(v_n = 1 AND v_total = 1, 'one project invoiced, one failed (isolated), got ' || v_n || '/' || v_total);
  PERFORM pg_temp.assert((SELECT count(*) FROM billing_failures WHERE cycle_id = v_cycle AND project_id = v_a AND sqlstate = '23505') = 1,
                         'failure for A logged with SQLSTATE');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM invoice_line_items WHERE invoice_id = (SELECT invoice_id FROM invoices WHERE project_id = v_a AND cycle_id = v_cycle)),
                         'failed project left no partial lines (savepoint rolled back)');

  SELECT invoice_id, total INTO v_inv, v_total FROM invoices WHERE project_id = v_b AND cycle_id = v_cycle;
  PERFORM pg_temp.assert(v_total = 1.08, 'B total = 0.60 + 0.48 = 1.08, got ' || v_total);
  PERFORM pg_temp.assert((SELECT count(*) FROM invoice_line_items WHERE invoice_id = v_inv) = 2, 'two lines for B');
  PERFORM pg_temp.assert((SELECT sum(amount) FROM invoice_line_items WHERE invoice_id = v_inv) = v_total, 'total = sum of lines');
  PERFORM pg_temp.assert((SELECT units FROM invoice_line_items WHERE invoice_id = v_inv AND resource_id = v_rb) = 20, 'units = hours x vcpus');
  PERFORM pg_temp.assert((SELECT unit_price FROM invoice_line_items WHERE invoice_id = v_inv AND resource_id = v_rb) = 0.03, 'price frozen at 0.03');
  PERFORM pg_temp.assert((SELECT array_agg(line_no ORDER BY line_no) FROM invoice_line_items WHERE invoice_id = v_inv) = ARRAY[1, 2], 'line numbers 1..n');
  PERFORM pg_temp.assert(fn_resource_cost(v_rb, v_t0, v_t0 + interval '1 day') = 0.60, 'fn_resource_cost agrees with the invoice line');

  -- Historical invoices are not rewritten when prices change later.
  UPDATE pricing_plans SET unit_price = 9 WHERE type_id = 1 AND effective_from < now() - interval '100 days' AND effective_to IS NOT NULL;
  PERFORM pg_temp.assert((SELECT unit_price FROM invoice_line_items WHERE invoice_id = v_inv AND resource_id = v_rb) = 0.03, 'frozen price survives pricing change');
  PERFORM pg_temp.assert((SELECT total FROM invoices WHERE invoice_id = v_inv) = 1.08, 'frozen total survives pricing change');

  -- Deleting an invoice cascades to its lines (weak entity).
  DELETE FROM invoices WHERE invoice_id = v_inv;
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM invoice_line_items WHERE invoice_id = v_inv), 'ON DELETE CASCADE removes lines');

  -- payments through the procedure (trg_payment_settle does the status change)
  SELECT invoice_id INTO v_inv FROM invoices WHERE project_id = v_a AND cycle_id = v_cycle;
  UPDATE invoices SET total = 10 WHERE invoice_id = v_inv;
  PERFORM sp_record_payment(v_inv, 4);
  PERFORM pg_temp.assert((SELECT status FROM invoices WHERE invoice_id = v_inv) = 'issued', 'part paid');
  PERFORM sp_record_payment(v_inv, 6);
  PERFORM pg_temp.assert((SELECT status FROM invoices WHERE invoice_id = v_inv) = 'paid', 'fully paid');
  PERFORM pg_temp.expect_message('SELECT sp_record_payment(999999, 1)', '%does not exist%', 'unknown invoice');
  PERFORM pg_temp.expect_message('SELECT * FROM sp_generate_invoices(999999)', '%does not exist%', 'unknown cycle');
END $t$;

-- Rollup + retention (partitions are dropped transactionally, so this is rolled back).
DO $t$
DECLARE
  web1 integer := pg_temp.rid('web-1');
  v_old timestamptz := date_trunc('hour', now()) - interval '65 days';
  v_part text := 'usage_metrics_' || to_char(v_old AT TIME ZONE 'UTC', 'YYYY_MM');
  v_msg text;
  v_n integer;
BEGIN
  INSERT INTO usage_metrics VALUES (web1, v_old, 'cpu_percent', 10), (web1, v_old + interval '1 minute', 'cpu_percent', 30);
  PERFORM pg_temp.assert(to_regclass(v_part) IS NOT NULL, 'old partition exists before retention');
  v_msg := sp_rollup_and_retention(30);
  PERFORM pg_temp.assert(v_msg LIKE '%' || v_part || '%', 'old partition reported dropped: ' || v_msg);
  PERFORM pg_temp.assert(to_regclass(v_part) IS NULL, 'old partition dropped');
  SELECT count(*) INTO v_n FROM usage_rollup_daily
   WHERE resource_id = web1 AND day = (v_old AT TIME ZONE 'UTC')::date AND metric = 'cpu_percent' AND samples >= 2;
  PERFORM pg_temp.assert(v_n = 1, 'daily rollup row written before the drop');
  PERFORM pg_temp.assert((SELECT min_value FROM usage_rollup_daily WHERE resource_id = web1 AND day = (v_old AT TIME ZONE 'UTC')::date AND metric = 'cpu_percent') <= 10,
                         'rollup keeps min');
  PERFORM pg_temp.assert(to_regclass('usage_metrics_' || to_char(date_trunc('month', now()) AT TIME ZONE 'UTC', 'YYYY_MM')) IS NOT NULL, 'current partition survives');
  PERFORM pg_temp.assert(to_regclass('usage_metrics_' || to_char((date_trunc('month', now()) + interval '1 month') AT TIME ZONE 'UTC', 'YYYY_MM')) IS NOT NULL, 'next month partition exists');
  PERFORM pg_temp.assert(sp_rollup_and_retention(30) = 'dropped: none', 'second run is a no-op');
END $t$;
