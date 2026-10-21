-- Provisioning procedures, quotas, permissions inside procedures, state changes, administration.
DO $t$
DECLARE
  wp    integer := pg_temp.pid('Web Platform');
  dl    integer := pg_temp.pid('Data Lab');
  stg   integer := pg_temp.pid('Web Platform Staging');
  admin integer := pg_temp.uid('admin@crms.test');
  alice integer := pg_temp.uid('alice@crms.test');
  bob   integer := pg_temp.uid('bob@crms.test');
  carol integer := pg_temp.uid('carol@crms.test');
  dave  integer := pg_temp.uid('dave@crms.test');
  v_net integer;
  v_vm  integer;
  v_vm2 integer;
  v_rule integer;
BEGIN
  ----- quota enforcement: Web Platform already holds 6 of 6 VMs -----
  PERFORM set_config('crms.user_id', alice::text, true);
  PERFORM pg_temp.expect_message(format($$SELECT sp_provision_vm(%s, 'one-too-many', 1, 512, %s)$$, wp, pg_temp.rid('web-net')),
                                 'Quota exceeded: 6 of 6 VMs used', 'VM quota enforced with the documented message');

  ----- successful provisioning in Data Lab (dave manages it) -----
  PERFORM set_config('crms.user_id', dave::text, true);
  v_vm := sp_provision_vm(dl, 'etl-2', 2, 2048, pg_temp.rid('data-net'));
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE resource_id = v_vm) = 'running', 'new VM is running');
  PERFORM pg_temp.assert((SELECT vcpus FROM compute_instances WHERE resource_id = v_vm) = 2, 'subtype row created');
  PERFORM pg_temp.assert((SELECT host(ip) FROM network_attachments WHERE resource_id = v_vm) = '10.10.2.3', 'IP picked by fn_next_free_ip');
  PERFORM pg_temp.assert((SELECT upper_inf(period) AND project_id = dl FROM allocations WHERE resource_id = v_vm), 'open allocation created');
  PERFORM pg_temp.assert((SELECT source FROM resources WHERE resource_id = v_vm) = 'provisioned', 'source = provisioned');
  PERFORM sp_provision_vm(dl, 'etl-3', 1, 512, pg_temp.rid('data-net'));
  PERFORM pg_temp.expect_message(format($$SELECT sp_provision_vm(%s, 'etl-4', 1, 512, %s)$$, dl, pg_temp.rid('data-net')),
                                 'Quota exceeded: 4 of 4 VMs used', 'Data Lab quota reached after 2 more VMs');
  -- terminating frees quota and the address
  PERFORM sp_terminate_resource(v_vm);
  PERFORM pg_temp.assert((SELECT state FROM resources WHERE resource_id = v_vm) = 'terminated', 'terminated');
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM network_attachments WHERE resource_id = v_vm), 'IP released');
  PERFORM pg_temp.assert((SELECT NOT upper_inf(period) FROM allocations WHERE resource_id = v_vm), 'allocation closed');
  PERFORM sp_provision_vm(dl, 'etl-4', 1, 512, pg_temp.rid('data-net'));
  PERFORM pg_temp.expect_message(format('SELECT sp_terminate_resource(%s)', v_vm), '%already terminated%', 'double terminate rejected');
  PERFORM pg_temp.expect_message('SELECT sp_terminate_resource(999999)', '%does not exist%', 'unknown resource');

  ----- validation inside the procedure -----
  PERFORM set_config('crms.user_id', alice::text, true);   -- staging has quota room (1 of 2), so validation is reached
  PERFORM pg_temp.expect_message(format($$SELECT sp_provision_vm(%s, 'x', 1, 512, %s)$$, stg, pg_temp.rid('web-net')), '%belongs to another project%', 'network must belong to the project');
  PERFORM pg_temp.expect_message(format($$SELECT sp_provision_vm(%s, 'x', 1, 512, 999999)$$, stg), '%does not exist%', 'network must exist');

  ----- networks: create, quota, overlap, in-use -----
  PERFORM set_config('crms.user_id', alice::text, true);
  v_net := sp_create_network(stg, 'stg-net', '10.50.0.0/24');
  PERFORM pg_temp.assert((SELECT cidr FROM networks WHERE resource_id = v_net) = '10.50.0.0/24', 'network created');
  PERFORM pg_temp.expect_message(format($$SELECT sp_create_network(%s, 'n2', '10.51.0.0/24')$$, stg), 'Quota exceeded: 1 of 1 networks used', 'network quota');
  PERFORM pg_temp.expect_message(format($$SELECT sp_create_network(%s, 'overlap', '10.10.1.128/25')$$, wp), '%overlaps%', 'overlapping CIDR in a project rejected');
  v_vm2 := sp_provision_vm(stg, 'stg-vm', 1, 512, v_net);
  PERFORM pg_temp.expect_message(format('SELECT sp_terminate_resource(%s)', v_net), '%still has attached instances%', 'network in use cannot be terminated');
  PERFORM sp_terminate_resource(v_vm2);
  PERFORM sp_terminate_resource(v_net);

  ----- volumes: quota is in GB -----
  PERFORM sp_create_volume(wp, 'v1', 300, '/mnt/v1');
  PERFORM pg_temp.expect_message(format($$SELECT sp_create_volume(%s, 'v2', 150)$$, wp), 'Quota exceeded: 400 of 500 GB used (requested 150)', 'storage quota in GB');
  PERFORM pg_temp.expect_error(format($$SELECT sp_create_volume(%s, 'v3', 0)$$, wp), '23514', 'volume size must be positive');

  ----- permissions enforced inside procedures -----
  PERFORM set_config('crms.user_id', carol::text, true);                            -- viewer
  PERFORM pg_temp.expect_error(format($$SELECT sp_create_volume(%s, 'nope', 1)$$, wp), '42501', 'viewer cannot create volumes');
  PERFORM pg_temp.expect_error(format('SELECT sp_terminate_resource(%s)', pg_temp.rid('web-1')), '42501', 'viewer cannot terminate');
  PERFORM pg_temp.expect_error(format($$SELECT sp_set_resource_state(%s, 'stopped')$$, pg_temp.rid('web-1')), '42501', 'viewer cannot stop');
  PERFORM set_config('crms.user_id', bob::text, true);                              -- developer
  PERFORM pg_temp.assert(sp_set_resource_state(pg_temp.rid('web-1'), 'stopped') = 'stopped', 'developer can stop');
  PERFORM sp_set_resource_state(pg_temp.rid('web-1'), 'running');
  PERFORM pg_temp.expect_error(format('SELECT sp_terminate_resource(%s)', pg_temp.rid('web-1')), '42501', 'developer cannot terminate (manager only)');
  PERFORM pg_temp.expect_error(format($$SELECT sp_create_volume(%s, 'x', 1)$$, dl), '42501', 'viewer in Data Lab cannot create');
  PERFORM pg_temp.expect_message(format($$SELECT sp_set_resource_state(%s, 'pending')$$, pg_temp.rid('web-1')), 'Illegal state transition%', 'state machine reached through the procedure');

  ----- membership, quotas, alert rules -----
  PERFORM set_config('crms.user_id', bob::text, true);
  PERFORM pg_temp.expect_error(format($$SELECT sp_add_member(%s, %s, 'viewer')$$, wp, dave), '42501', 'developer cannot add members');
  v_rule := sp_create_alert_rule(wp, 'net_kbps', '>', 5000, 120);
  PERFORM pg_temp.assert(EXISTS (SELECT 1 FROM alert_rules WHERE rule_id = v_rule), 'developer creates alert rule');
  PERFORM pg_temp.expect_error(format('SELECT sp_delete_alert_rule(%s)', v_rule), '42501', 'developer cannot delete alert rules');
  PERFORM set_config('crms.user_id', alice::text, true);
  PERFORM sp_delete_alert_rule(v_rule);
  PERFORM pg_temp.assert(NOT EXISTS (SELECT 1 FROM alert_rules WHERE rule_id = v_rule), 'manager deletes alert rule');
  PERFORM sp_add_member(wp, dave, 'viewer');
  PERFORM pg_temp.assert((SELECT r.name FROM project_members pm JOIN roles r USING (role_id) WHERE pm.project_id = wp AND pm.user_id = dave) = 'viewer', 'manager adds member');
  PERFORM sp_add_member(wp, dave, 'developer');
  PERFORM pg_temp.assert((SELECT r.name FROM project_members pm JOIN roles r USING (role_id) WHERE pm.project_id = wp AND pm.user_id = dave) = 'developer', 'add_member upserts role');
  PERFORM pg_temp.expect_message(format($$SELECT sp_add_member(%s, %s, 'overlord')$$, wp, dave), 'Unknown role%', 'unknown role');
  PERFORM sp_remove_member(wp, dave);
  PERFORM pg_temp.expect_message(format('SELECT sp_remove_member(%s, %s)', wp, alice), '%owner cannot be removed%', 'owner stays');
  PERFORM pg_temp.expect_error(format($$SELECT sp_set_quota(%s, 'compute', 10)$$, wp), '42501', 'manager cannot change quotas');
  PERFORM set_config('crms.user_id', admin::text, true);
  PERFORM sp_set_quota(wp, 'compute', 7);
  PERFORM pg_temp.assert((SELECT max_units FROM quotas WHERE project_id = wp AND resource_type_id = 1) = 7, 'admin changes quota');
  PERFORM sp_provision_vm(wp, 'seventh', 1, 512, pg_temp.rid('web-net'));            -- now fits
  PERFORM pg_temp.expect_message(format($$SELECT sp_set_quota(%s, 'gpu', 1)$$, wp), 'Unknown resource type%', 'unknown type');
END $t$;
