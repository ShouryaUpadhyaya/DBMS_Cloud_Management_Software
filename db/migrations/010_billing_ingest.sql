-- 010: invoice generation, collector ingestion, rollup/retention.

-- One invoice per project with billable usage in the cycle. Each project runs in its own
-- BEGIN .. EXCEPTION block: that is a SAVEPOINT in plpgsql, so a failure rolls back only that
-- project's invoice, is logged in billing_failures, and the loop continues.
CREATE FUNCTION sp_generate_invoices(p_cycle integer)
RETURNS TABLE (project_id integer, outcome text, invoice_id integer, detail text)
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cycle billing_cycles%ROWTYPE;
  v_proj  integer;
  v_inv   integer;
BEGIN
  IF session_user IN ('crms_app', 'crms_readonly') AND NOT fn_is_admin() THEN
    RAISE EXCEPTION 'Permission denied: only admins generate invoices' USING ERRCODE = 'insufficient_privilege';
  END IF;
  SELECT * INTO v_cycle FROM billing_cycles bc WHERE bc.cycle_id = p_cycle;
  IF NOT FOUND THEN RAISE EXCEPTION 'Billing cycle % does not exist', p_cycle; END IF;

  FOR v_proj IN
    SELECT DISTINCT a.project_id
      FROM allocations a
      CROSS JOIN LATERAL fn_cost_segments(a.resource_id, lower(v_cycle.period), upper(v_cycle.period), a.project_id) s
     ORDER BY 1
  LOOP
    BEGIN
      INSERT INTO invoices (project_id, cycle_id) VALUES (v_proj, p_cycle) RETURNING invoices.invoice_id INTO v_inv;

      INSERT INTO invoice_line_items (invoice_id, line_no, resource_id, units, unit_price, amount)
      SELECT v_inv, row_number() OVER (ORDER BY seg.resource_id, seg.seg_start), seg.resource_id,
             seg.units, seg.unit_price, seg.amount        -- price frozen here on purpose
        FROM (SELECT s.*
                FROM allocations a
                CROSS JOIN LATERAL fn_cost_segments(a.resource_id, lower(v_cycle.period), upper(v_cycle.period), v_proj) s
               WHERE a.project_id = v_proj) seg;

      UPDATE invoices i SET total = (SELECT coalesce(sum(li.amount), 0) FROM invoice_line_items li
                                      WHERE li.invoice_id = v_inv)
       WHERE i.invoice_id = v_inv;

      project_id := v_proj; outcome := 'invoiced'; invoice_id := v_inv; detail := NULL;
      RETURN NEXT;
    EXCEPTION WHEN OTHERS THEN
      INSERT INTO billing_failures (cycle_id, project_id, sqlstate, message)
      VALUES (p_cycle, v_proj, SQLSTATE, SQLERRM);
      project_id := v_proj; outcome := 'failed'; invoice_id := NULL; detail := SQLSTATE || ': ' || SQLERRM;
      RETURN NEXT;
    END;
  END LOOP;
END $$;

-- ---------------------------------------------------------------------------------------------
-- Collector ingestion. Payload shape:
--   { "node": {"hostname": "...", "region": "..."},
--     "full_snapshot": true,
--     "resources": [{"external_id","type":"compute|storage|network","name","state",
--                    "project","vcpus","memory_mb","image","size_gb","mount_path","cidr"}],
--     "metrics":   [{"external_id","ts","metric","value"}] }
-- Unknown external_ids are upserted as discovered resources in the 'unassigned' project
-- (or the named project).
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION sp_ingest_metrics(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_node       integer;
  v_default    integer;
  rec          jsonb;
  v_project    integer;
  v_type       integer;
  v_id         integer;
  v_state      text;
  v_res        integer := 0;
  v_met        integer;
  v_term       integer := 0;
  v_seen       text[] := '{}';
BEGIN
  IF jsonb_typeof(p_payload) <> 'object' THEN
    RAISE EXCEPTION 'payload must be a JSON object';
  END IF;

  IF p_payload ? 'node' THEN
    INSERT INTO nodes (hostname, region)
    VALUES (p_payload #>> '{node,hostname}', coalesce(p_payload #>> '{node,region}', 'local'))
    ON CONFLICT (hostname) DO UPDATE SET region = EXCLUDED.region
    RETURNING node_id INTO v_node;
  END IF;

  SELECT project_id INTO v_default FROM projects WHERE name = 'Unassigned';
  IF v_default IS NULL THEN RAISE EXCEPTION 'Default project "Unassigned" is missing'; END IF;

  FOR rec IN SELECT * FROM jsonb_array_elements(coalesce(p_payload -> 'resources', '[]'::jsonb)) LOOP
    v_type := CASE rec ->> 'type' WHEN 'compute' THEN 1 WHEN 'storage' THEN 2 WHEN 'network' THEN 3
              ELSE NULL END;
    IF v_type IS NULL THEN RAISE EXCEPTION 'unknown resource type %', rec ->> 'type'; END IF;
    v_state := coalesce(rec ->> 'state', 'running');
    v_seen := v_seen || (rec ->> 'external_id');
    SELECT coalesce((SELECT p.project_id FROM projects p WHERE p.name = rec ->> 'project'), v_default)
      INTO v_project;

    SELECT resource_id INTO v_id FROM resources WHERE external_id = rec ->> 'external_id';
    IF v_id IS NULL THEN
      INSERT INTO resources (project_id, type_id, node_id, name, external_id, state, source)
      VALUES (v_project, v_type, v_node, rec ->> 'name', rec ->> 'external_id', v_state, 'discovered')
      RETURNING resource_id INTO v_id;
      INSERT INTO allocations (resource_id, project_id, period) VALUES (v_id, v_project, tstzrange(now(), NULL));
      v_res := v_res + 1;
    ELSE
      -- terminated is final; only touch state when it really changes (state machine validates).
      UPDATE resources SET name = rec ->> 'name', node_id = coalesce(v_node, node_id),
             state = CASE WHEN state = 'terminated' THEN state ELSE v_state END
       WHERE resource_id = v_id;
    END IF;

    IF v_type = 1 THEN
      INSERT INTO compute_instances (resource_id, vcpus, memory_mb, image)
      VALUES (v_id, coalesce((rec ->> 'vcpus')::int, 1), coalesce((rec ->> 'memory_mb')::int, 512),
              coalesce(rec ->> 'image', 'unknown'))
      ON CONFLICT (resource_id) DO UPDATE
        SET vcpus = EXCLUDED.vcpus, memory_mb = EXCLUDED.memory_mb, image = EXCLUDED.image;
    ELSIF v_type = 2 THEN
      INSERT INTO storage_volumes (resource_id, size_gb, mount_path)
      VALUES (v_id, coalesce((rec ->> 'size_gb')::int, 1), rec ->> 'mount_path')
      ON CONFLICT (resource_id) DO UPDATE
        SET size_gb = EXCLUDED.size_gb, mount_path = EXCLUDED.mount_path;
    ELSE
      INSERT INTO networks (resource_id, cidr)
      VALUES (v_id, coalesce((rec ->> 'cidr')::cidr, '10.255.0.0/24'))
      ON CONFLICT (resource_id) DO UPDATE SET cidr = EXCLUDED.cidr;
    END IF;
  END LOOP;

  -- A full snapshot lists every object on the node; anything missing has been removed.
  IF coalesce((p_payload ->> 'full_snapshot')::boolean, false) AND v_node IS NOT NULL THEN
    UPDATE resources SET state = 'terminated'
     WHERE node_id = v_node AND source = 'discovered' AND state <> 'terminated'
       AND NOT (external_id = ANY (v_seen));
    GET DIAGNOSTICS v_term = ROW_COUNT;
  END IF;

  PERFORM fn_ensure_partitions(now(), now() + interval '1 day');
  PERFORM fn_ensure_partitions(min_ts, max_ts)
     FROM (SELECT min((m ->> 'ts')::timestamptz) AS min_ts, max((m ->> 'ts')::timestamptz) AS max_ts
             FROM jsonb_array_elements(coalesce(p_payload -> 'metrics', '[]'::jsonb)) m) b
    WHERE min_ts IS NOT NULL;

  INSERT INTO usage_metrics (resource_id, ts, metric, value)
  SELECT r.resource_id, m.ts, m.metric, m.value
    FROM jsonb_to_recordset(coalesce(p_payload -> 'metrics', '[]'::jsonb))
         AS m(external_id text, ts timestamptz, metric text, value double precision)
    JOIN resources r ON r.external_id = m.external_id
  ON CONFLICT (resource_id, metric, ts) DO NOTHING;
  GET DIAGNOSTICS v_met = ROW_COUNT;

  RETURN jsonb_build_object('new_resources', v_res, 'metrics', v_met, 'terminated', v_term);
END $$;

-- Payload: { "logs": [{"external_id","ts","level","message","attrs"}] }
CREATE FUNCTION sp_ingest_logs(p_payload jsonb) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_n integer;
BEGIN
  PERFORM fn_ensure_partitions(now(), now() + interval '1 day');
  PERFORM fn_ensure_partitions(min_ts, max_ts)
     FROM (SELECT min((l ->> 'ts')::timestamptz) AS min_ts, max((l ->> 'ts')::timestamptz) AS max_ts
             FROM jsonb_array_elements(coalesce(p_payload -> 'logs', '[]'::jsonb)) l) b
    WHERE min_ts IS NOT NULL;

  INSERT INTO log_entries (resource_id, ts, level, message, attrs)
  SELECT r.resource_id, l.ts,
         CASE WHEN lower(l.level) IN ('debug', 'info', 'warn', 'error') THEN lower(l.level) ELSE 'info' END,
         l.message, coalesce(l.attrs, '{}'::jsonb)
    FROM jsonb_to_recordset(coalesce(p_payload -> 'logs', '[]'::jsonb))
         AS l(external_id text, ts timestamptz, level text, message text, attrs jsonb)
    JOIN resources r ON r.external_id = l.external_id;
  GET DIAGNOSTICS v_n = ROW_COUNT;
  RETURN jsonb_build_object('logs', v_n);
END $$;

-- ---------------------------------------------------------------------------------------------
-- Rollup + retention. Raw monthly partitions that lie wholly beyond p_days are summarised into
-- usage_rollup_daily and then dropped (dropping a partition is instant, unlike DELETE).
-- Next month's partitions are created ahead of time.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION sp_rollup_and_retention(p_days integer DEFAULT 30) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_cutoff  timestamptz := now() - make_interval(days => p_days);
  v_part    record;
  v_upper   timestamptz;
  v_dropped text[] := '{}';
BEGIN
  PERFORM fn_ensure_partitions(now(), now() + interval '1 month');

  FOR v_part IN
    SELECT c.relname, parent.relname AS parent_name
      FROM pg_inherits i
      JOIN pg_class c ON c.oid = i.inhrelid
      JOIN pg_class parent ON parent.oid = i.inhparent
     WHERE parent.relname IN ('usage_metrics', 'log_entries')
       AND c.relname ~ '_[0-9]{4}_[0-9]{2}$'
     ORDER BY c.relname
  LOOP
    v_upper := (to_date(right(v_part.relname, 7), 'YYYY_MM') + interval '1 month') AT TIME ZONE 'UTC';
    CONTINUE WHEN v_upper > v_cutoff;

    IF v_part.parent_name = 'usage_metrics' THEN
      EXECUTE format($q$
        INSERT INTO usage_rollup_daily (resource_id, day, metric, avg_value, max_value, min_value, samples)
        SELECT resource_id, (ts AT TIME ZONE 'UTC')::date, metric, avg(value), max(value), min(value), count(*)
          FROM %I GROUP BY 1, 2, 3
        ON CONFLICT (resource_id, day, metric) DO UPDATE
          SET avg_value = EXCLUDED.avg_value, max_value = EXCLUDED.max_value,
              min_value = EXCLUDED.min_value, samples = EXCLUDED.samples$q$, v_part.relname);
    END IF;
    EXECUTE format('DROP TABLE %I', v_part.relname);
    v_dropped := v_dropped || v_part.relname::text;
  END LOOP;
  RETURN coalesce('dropped: ' || array_to_string(v_dropped, ', '), 'dropped: none');
END $$;
