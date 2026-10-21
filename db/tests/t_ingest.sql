-- sp_ingest_metrics / sp_ingest_logs: upsert by external_id, idempotency, snapshots, partitions.
DO $t$
DECLARE
  v_payload jsonb;
  v_out jsonb;
  v_ts timestamptz := date_trunc('second', now());
  v_cpu integer;
BEGIN
  v_payload := jsonb_build_object(
    'node', jsonb_build_object('hostname', 'test-node', 'region', 'lab'),
    'full_snapshot', true,
    'resources', jsonb_build_array(
      jsonb_build_object('external_id', 't-c1', 'type', 'compute', 'name', 't-container-1', 'state', 'running',
                         'vcpus', 2, 'memory_mb', 1024, 'image', 'redis:7'),
      jsonb_build_object('external_id', 't-c2', 'type', 'compute', 'name', 't-container-2', 'state', 'running',
                         'project', 'Data Lab'),
      jsonb_build_object('external_id', 't-v1', 'type', 'storage', 'name', 't-volume', 'state', 'running', 'size_gb', 5),
      jsonb_build_object('external_id', 't-n1', 'type', 'network', 'name', 't-network', 'state', 'running', 'cidr', '172.30.0.0/16')),
    'metrics', jsonb_build_array(
      jsonb_build_object('external_id', 't-c1', 'ts', v_ts, 'metric', 'cpu_percent', 'value', 12.5),
      jsonb_build_object('external_id', 't-c1', 'ts', v_ts, 'metric', 'mem_percent', 'value', 40),
      jsonb_build_object('external_id', 't-c2', 'ts', v_ts, 'metric', 'cpu_percent', 'value', 3),
      jsonb_build_object('external_id', 'unknown-id', 'ts', v_ts, 'metric', 'cpu_percent', 'value', 3)));

  v_out := sp_ingest_metrics(v_payload);
  PERFORM pg_temp.assert((v_out ->> 'new_resources')::int = 4, 'four resources discovered: ' || v_out::text);
  PERFORM pg_temp.assert((v_out ->> 'metrics')::int = 3, 'unknown external_id metric skipped: ' || v_out::text);
  PERFORM pg_temp.assert((SELECT count(*) FROM resources WHERE source = 'discovered' AND external_id LIKE 't-%') = 4, 'discovered rows exist');
  PERFORM pg_temp.assert((SELECT p.name FROM resources r JOIN projects p USING (project_id) WHERE external_id = 't-c1') = 'Unassigned', 'default project');
  PERFORM pg_temp.assert((SELECT p.name FROM resources r JOIN projects p USING (project_id) WHERE external_id = 't-c2') = 'Data Lab', 'named project');
  PERFORM pg_temp.assert((SELECT vcpus FROM compute_instances ci JOIN resources r USING (resource_id) WHERE external_id = 't-c1') = 2, 'compute subtype');
  PERFORM pg_temp.assert((SELECT memory_mb FROM compute_instances ci JOIN resources r USING (resource_id) WHERE external_id = 't-c2') = 512, 'compute defaults');
  PERFORM pg_temp.assert((SELECT size_gb FROM storage_volumes sv JOIN resources r USING (resource_id) WHERE external_id = 't-v1') = 5, 'storage subtype');
  PERFORM pg_temp.assert((SELECT cidr FROM networks n JOIN resources r USING (resource_id) WHERE external_id = 't-n1') = '172.30.0.0/16', 'network subtype');
  PERFORM pg_temp.assert((SELECT count(*) FROM allocations a JOIN resources r USING (resource_id) WHERE r.external_id LIKE 't-%' AND upper_inf(a.period)) = 4, 'allocations opened for billing');
  PERFORM pg_temp.assert((SELECT hostname FROM nodes n JOIN resources r USING (node_id) WHERE external_id = 't-c1') = 'test-node', 'node upserted');

  -- idempotent: same payload again changes nothing
  v_out := sp_ingest_metrics(v_payload);
  PERFORM pg_temp.assert((v_out ->> 'new_resources')::int = 0 AND (v_out ->> 'metrics')::int = 0 AND (v_out ->> 'terminated')::int = 0, 're-ingest is idempotent: ' || v_out::text);

  -- state changes follow the state machine
  v_payload := jsonb_set(v_payload, '{resources,0,state}', '"stopped"');
  PERFORM sp_ingest_metrics(v_payload);
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE external_id = 't-c1') = 'stopped', 'running -> stopped');
  v_payload := jsonb_set(v_payload, '{resources,0,state}', '"running"');
  PERFORM sp_ingest_metrics(v_payload);
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE external_id = 't-c1') = 'running', 'stopped -> running');

  -- full snapshot without t-c2 terminates it, and billing stops
  v_out := sp_ingest_metrics(jsonb_set(v_payload, '{resources}', (v_payload -> 'resources') - 1));
  PERFORM pg_temp.assert((v_out ->> 'terminated')::int = 1, 'one resource missing from snapshot: ' || v_out::text);
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE external_id = 't-c2') = 'terminated', 'removed container terminated');
  PERFORM pg_temp.assert((SELECT NOT upper_inf(a.period) FROM allocations a JOIN resources r USING (resource_id) WHERE r.external_id = 't-c2'), 'allocation closed by ingest');
  -- terminated is final even if the same id shows up again
  PERFORM sp_ingest_metrics(v_payload);
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE external_id = 't-c2') = 'terminated', 'terminated stays terminated');
  -- another node's resources are never touched by this node's snapshot
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE external_id = 'mock-web-1') = 'running', 'other node untouched');

  -- partial payload (no full_snapshot) never terminates anything
  v_out := sp_ingest_metrics(jsonb_build_object('node', jsonb_build_object('hostname', 'test-node'), 'resources', '[]'::jsonb));
  PERFORM pg_temp.assert((v_out ->> 'terminated')::int = 0, 'no snapshot flag, no terminations');

  -- metrics in a month without a partition: the procedure creates it
  v_out := sp_ingest_metrics(jsonb_build_object('metrics', jsonb_build_array(
            jsonb_build_object('external_id', 't-c1', 'ts', now() + interval '150 days', 'metric', 'net_kbps', 'value', 1))));
  PERFORM pg_temp.assert((v_out ->> 'metrics')::int = 1, 'future partition auto-created');

  -- errors
  PERFORM pg_temp.expect_message($$SELECT sp_ingest_metrics('{"resources":[{"external_id":"x","type":"gpu","name":"x"}]}')$$, 'unknown resource type%', 'unknown type rejected');
  PERFORM pg_temp.expect_message($$SELECT sp_ingest_metrics('[1,2]')$$, '%JSON object%', 'non-object rejected');
  PERFORM pg_temp.expect_error($$SELECT sp_ingest_metrics('{"metrics":[{"external_id":"t-c1","ts":"2026-01-01T00:00:00Z","metric":"bogus","value":1}]}')$$, '23514', 'bad metric name rejected by CHECK');

  -- logs
  v_out := sp_ingest_logs(jsonb_build_object('logs', jsonb_build_array(
      jsonb_build_object('external_id', 't-c1', 'ts', v_ts, 'level', 'ERROR', 'message', 'boom', 'attrs', '{"code": 500}'::jsonb),
      jsonb_build_object('external_id', 't-c1', 'ts', v_ts, 'level', 'weird', 'message', 'odd level'),
      jsonb_build_object('external_id', 'nobody', 'ts', v_ts, 'level', 'info', 'message', 'dropped'))));
  PERFORM pg_temp.assert((v_out ->> 'logs')::int = 2, 'logs for unknown containers skipped: ' || v_out::text);
  PERFORM pg_temp.assert((SELECT level FROM log_entries WHERE message = 'boom') = 'error', 'level lower-cased');
  PERFORM pg_temp.assert((SELECT level FROM log_entries WHERE message = 'odd level') = 'info', 'unknown level becomes info');
  PERFORM pg_temp.assert((SELECT attrs ->> 'code' FROM log_entries WHERE message = 'boom') = '500', 'attrs stored');
  PERFORM pg_temp.assert((SELECT attrs FROM log_entries WHERE message = 'odd level') = '{}'::jsonb, 'attrs default {}');
  PERFORM pg_temp.assert((SELECT count(*) FROM log_entries WHERE attrs @> '{"code": 500}') >= 1, 'jsonb containment query works');
  PERFORM pg_temp.assert((SELECT count(*) FROM log_entries WHERE to_tsvector('english', message) @@ plainto_tsquery('english', 'boom')) = 1, 'full-text query works');
END $t$;
