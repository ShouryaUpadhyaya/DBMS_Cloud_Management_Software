-- Seed 2: the same 8 containers, 2 volumes and 2 networks the mock collector simulates, with
-- allocations backdated 75 days so two full calendar months can be invoiced.
SELECT set_config('crms.user_id', (SELECT user_id::text FROM users WHERE email = 'admin@crms.test'), false);

INSERT INTO nodes (hostname, region) VALUES ('crms-local', 'local');

CREATE TEMP TABLE seed_res (name text, project text, type text, state text, vcpus int, mem int,
                            image text, size_gb int, mount text, cidr cidr, net text);
INSERT INTO seed_res VALUES
  ('web-net',       'Web Platform', 'network', 'running', NULL, NULL, NULL, NULL, NULL, '10.10.1.0/24', NULL),
  ('data-net',      'Data Lab',     'network', 'running', NULL, NULL, NULL, NULL, NULL, '10.10.2.0/24', NULL),
  ('pgdata',        'Web Platform', 'storage', 'running', NULL, NULL, NULL, 100, '/var/lib/postgresql', NULL, NULL),
  ('datasets',      'Data Lab',     'storage', 'running', NULL, NULL, NULL, 400, '/data', NULL, NULL),
  ('web-1',         'Web Platform', 'compute', 'running', 2, 2048, 'nginx:1.27', NULL, NULL, NULL, 'web-net'),
  ('web-2',         'Web Platform', 'compute', 'running', 2, 2048, 'nginx:1.27', NULL, NULL, NULL, 'web-net'),
  ('api-1',         'Web Platform', 'compute', 'running', 2, 4096, 'crms/api:latest', NULL, NULL, NULL, 'web-net'),
  ('worker-1',      'Web Platform', 'compute', 'running', 1, 1024, 'crms/worker:latest', NULL, NULL, NULL, 'web-net'),
  ('cache-1',       'Web Platform', 'compute', 'stopped', 1, 512, 'redis:7', NULL, NULL, NULL, 'web-net'),
  ('staging-web-1', 'Web Platform Staging', 'compute', 'running', 1, 1024, 'nginx:1.27', NULL, NULL, NULL, NULL),
  ('etl-1',         'Data Lab',     'compute', 'running', 4, 8192, 'python:3.12', NULL, NULL, NULL, 'data-net'),
  ('notebook-1',    'Data Lab',     'compute', 'running', 2, 4096, 'jupyter/base:latest', NULL, NULL, NULL, 'data-net');

DO $$
DECLARE
  s record;
  v_id integer;
  v_born timestamptz := now() - interval '75 days';
BEGIN
  -- networks first so containers can attach
  FOR s IN SELECT * FROM seed_res ORDER BY CASE type WHEN 'network' THEN 1 WHEN 'storage' THEN 2 ELSE 3 END, name LOOP
    INSERT INTO resources (project_id, type_id, node_id, name, external_id, state, source, created_at)
    SELECT p.project_id, rt.type_id, n.node_id, s.name, 'mock-' || s.name, 'pending', 'discovered', v_born
      FROM projects p, resource_types rt, nodes n
     WHERE p.name = s.project AND rt.name = s.type AND n.hostname = 'crms-local'
    RETURNING resource_id INTO v_id;

    IF s.type = 'network' THEN
      INSERT INTO networks (resource_id, cidr) VALUES (v_id, s.cidr);
    ELSIF s.type = 'storage' THEN
      INSERT INTO storage_volumes (resource_id, size_gb, mount_path) VALUES (v_id, s.size_gb, s.mount);
    ELSE
      INSERT INTO compute_instances (resource_id, vcpus, memory_mb, image) VALUES (v_id, s.vcpus, s.mem, s.image);
      IF s.net IS NOT NULL THEN
        INSERT INTO network_attachments (resource_id, network_id, ip)
        SELECT v_id, r.resource_id, fn_next_free_ip(r.resource_id) FROM resources r WHERE r.name = s.net;
      END IF;
    END IF;

    INSERT INTO allocations (resource_id, project_id, period)
    SELECT v_id, project_id, tstzrange(v_born, NULL) FROM resources WHERE resource_id = v_id;
    UPDATE resources SET state = 'running' WHERE resource_id = v_id;
    IF s.state = 'stopped' THEN
      UPDATE resources SET state = 'stopped' WHERE resource_id = v_id;
    END IF;
  END LOOP;
END $$;

-- One VM created through the real procedure (quota lock, IP allocation, allocation row).
SELECT sp_provision_vm((SELECT project_id FROM projects WHERE name = 'Web Platform'),
                       'bastion', 1, 1024, (SELECT resource_id FROM resources WHERE name = 'web-net'));
-- It is a provisioned VM with no collector, so it has no heartbeat (see missed_heartbeats query).
-- Backdate it so it appears in billing history too.
UPDATE allocations SET period = tstzrange(now() - interval '40 days', NULL)
 WHERE resource_id = (SELECT resource_id FROM resources WHERE name = 'bastion');
UPDATE resources SET created_at = now() - interval '40 days' WHERE name = 'bastion';

-- Alert rules: breach of a windowed average opens an event (trg_metric_alert).
INSERT INTO alert_rules (project_id, metric, operator, threshold, window_seconds)
SELECT p.project_id, r.metric, r.op, r.threshold, r.win
  FROM (VALUES ('Web Platform', 'cpu_percent', '>', 85, 300),
               ('Web Platform', 'mem_percent', '>', 92, 300),
               ('Data Lab',     'cpu_percent', '>', 90, 600),
               ('Data Lab',     'disk_percent', '>', 85, 900)) AS r(project, metric, op, threshold, win)
  JOIN projects p ON p.name = r.project;
