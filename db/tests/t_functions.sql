-- fn_next_free_ip, fn_has_permission (role hierarchy), fn_resource_cost / fn_cost_segments.
DO $t$
DECLARE
  net   integer := pg_temp.rid('web-net');
  v_ip  inet;
  v_net integer;
  wp    integer := pg_temp.pid('Web Platform');
  v_id  integer;
  v_cost numeric;
  v_boundary timestamptz := date_trunc('day', now()) - interval '20 days';   -- price change of compute
BEGIN
  ----- fn_next_free_ip -----
  SELECT fn_next_free_ip(net) INTO v_ip;
  PERFORM pg_temp.assert(host(v_ip) = '10.10.1.7', 'first free address after 6 used is .7, got ' || v_ip);
  DELETE FROM network_attachments WHERE network_id = net AND ip = '10.10.1.2';
  PERFORM pg_temp.assert(host(fn_next_free_ip(net)) = '10.10.1.2', 'freed address is reused first');
  -- a /30 has exactly two hosts; the third request must fail
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 3, 'tiny-net') RETURNING resource_id INTO v_net;
  INSERT INTO networks (resource_id, cidr) VALUES (v_net, '172.20.0.0/30');
  PERFORM pg_temp.assert(host(fn_next_free_ip(v_net)) = '172.20.0.1', '/30 first host');
  INSERT INTO network_attachments VALUES (pg_temp.rid('web-1'), v_net, '172.20.0.1');
  PERFORM pg_temp.assert(host(fn_next_free_ip(v_net)) = '172.20.0.2', '/30 second host');
  INSERT INTO network_attachments VALUES (pg_temp.rid('web-2'), v_net, '172.20.0.2');
  PERFORM pg_temp.expect_message(format('SELECT fn_next_free_ip(%s)', v_net), '%no free addresses%', 'full network');
  PERFORM pg_temp.expect_message('SELECT fn_next_free_ip(999999)', '%does not exist%', 'unknown network');

  ----- fn_has_permission: recursive CTE over role hierarchy -----
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('carol@crms.test'), wp, 'view', 'resource'), 'viewer can view');
  PERFORM pg_temp.assert(NOT fn_has_permission(pg_temp.uid('carol@crms.test'), wp, 'create', 'compute'), 'viewer cannot create');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('bob@crms.test'), wp, 'create', 'compute'), 'developer can create compute');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('bob@crms.test'), wp, 'view', 'invoice'), 'developer inherits viewer permissions');
  PERFORM pg_temp.assert(NOT fn_has_permission(pg_temp.uid('bob@crms.test'), wp, 'delete', 'compute'), 'developer cannot delete');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('alice@crms.test'), wp, 'delete', 'compute'), 'manager can delete');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('alice@crms.test'), wp, 'create', 'compute'), 'manager inherits developer permissions');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('alice@crms.test'), wp, 'view'), 'NULL resource type matches any');
  PERFORM pg_temp.assert(NOT fn_has_permission(pg_temp.uid('alice@crms.test'), wp, 'manage', 'quota'), 'manager cannot manage quotas');
  PERFORM pg_temp.assert(NOT fn_has_permission(pg_temp.uid('alice@crms.test'), pg_temp.pid('Data Lab'), 'view'), 'no membership, no permission');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('bob@crms.test'), pg_temp.pid('Data Lab'), 'view', 'resource'), 'bob is viewer in Data Lab');
  PERFORM pg_temp.assert(NOT fn_has_permission(pg_temp.uid('bob@crms.test'), pg_temp.pid('Data Lab'), 'create', 'compute'), 'bob only views in Data Lab');
  PERFORM pg_temp.assert(NOT fn_has_permission(pg_temp.uid('erin@crms.test'), pg_temp.pid('Data Lab'), 'view'), 'suspended users have no permissions');
  PERFORM pg_temp.assert(fn_has_permission(pg_temp.uid('admin@crms.test'), wp, 'manage', 'quota'), 'admin can do everything');
  PERFORM pg_temp.assert(NOT fn_has_permission(NULL, wp, 'view'), 'no user, no permission');

  ----- fn_resource_cost: hand-computed -----
  -- 2 vCPU for exactly 10h inside the old compute price (0.03) => 20 units * 0.03 = 0.60
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 1, 'cost-vm') RETURNING resource_id INTO v_id;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (v_id, 2, 512);
  INSERT INTO allocations (resource_id, project_id, period)
  VALUES (v_id, wp, tstzrange(v_boundary - interval '10 days', v_boundary - interval '10 days' + interval '10 hours'));
  v_cost := fn_resource_cost(v_id, v_boundary - interval '11 days', v_boundary);
  PERFORM pg_temp.assert(v_cost = 0.60, 'cost of 10h x 2 vcpu at 0.03 is 0.60, got ' || v_cost);
  -- the requested window clips the allocation: only 5 of the 10 hours => 0.30
  v_cost := fn_resource_cost(v_id, v_boundary - interval '10 days', v_boundary - interval '10 days' + interval '5 hours');
  PERFORM pg_temp.assert(v_cost = 0.30, 'window clips allocation, got ' || v_cost);
  PERFORM pg_temp.assert(fn_resource_cost(v_id, now(), now() + interval '1 day') = 0, 'no overlap, no cost');

  -- allocation straddling the price change: 24h at 0.03 + 24h at 0.025 for 1 vCPU = 0.72 + 0.60
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 1, 'cost-vm2') RETURNING resource_id INTO v_id;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (v_id, 1, 512);
  INSERT INTO allocations (resource_id, project_id, period)
  VALUES (v_id, wp, tstzrange(v_boundary - interval '1 day', v_boundary + interval '1 day'));
  PERFORM pg_temp.assert((SELECT count(*) FROM fn_cost_segments(v_id, v_boundary - interval '2 days', v_boundary + interval '2 days')) = 2,
                         'one segment per price plan');
  v_cost := fn_resource_cost(v_id, v_boundary - interval '2 days', v_boundary + interval '2 days');
  PERFORM pg_temp.assert(v_cost = 1.32, 'straddling cost is 1.32, got ' || v_cost);

  -- storage: GB-hours; 100 GB x 24h x 0.0002 = 0.48
  INSERT INTO resources (project_id, type_id, name) VALUES (wp, 2, 'cost-vol') RETURNING resource_id INTO v_id;
  INSERT INTO storage_volumes (resource_id, size_gb) VALUES (v_id, 100);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_id, wp, tstzrange(v_boundary - interval '5 days', v_boundary - interval '4 days'));
  v_cost := fn_resource_cost(v_id, v_boundary - interval '6 days', v_boundary);
  PERFORM pg_temp.assert(v_cost = 0.48, 'storage cost 0.48, got ' || v_cost);
END $t$;
