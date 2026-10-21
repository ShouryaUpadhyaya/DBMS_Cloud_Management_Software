-- 009: provisioning procedures. All are SECURITY DEFINER (callers have no table write rights)
-- and start with fn_assert_permission, so authorisation is enforced in the database.

-- Shared insert half of VM provisioning (no quota logic here, so the safe and unsafe variants
-- differ ONLY in how they check the quota).
CREATE FUNCTION _provision_vm_insert(p_project integer, p_name text, p_vcpus integer, p_mem_mb integer,
                                     p_network integer, p_image text) RETURNS integer
LANGUAGE plpgsql SET search_path = public, pg_temp AS $$
DECLARE
  v_id integer;
  v_net_project integer;
BEGIN
  SELECT project_id INTO v_net_project FROM resources WHERE resource_id = p_network AND type_id = 3
     AND state <> 'terminated';
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Network % does not exist or is terminated', p_network;
  END IF;
  IF v_net_project <> p_project THEN
    RAISE EXCEPTION 'Network % belongs to another project', p_network;
  END IF;

  INSERT INTO resources (project_id, type_id, name, state, source)
  VALUES (p_project, 1, p_name, 'pending', 'provisioned') RETURNING resource_id INTO v_id;
  INSERT INTO compute_instances (resource_id, vcpus, memory_mb, image)
  VALUES (v_id, p_vcpus, p_mem_mb, p_image);
  PERFORM 1 FROM resources WHERE resource_id = p_network FOR UPDATE;      -- serialise IP choice
  INSERT INTO network_attachments (resource_id, network_id, ip)
  VALUES (v_id, p_network, fn_next_free_ip(p_network));
  INSERT INTO allocations (resource_id, project_id, period)
  VALUES (v_id, p_project, tstzrange(now(), NULL));
  UPDATE resources SET state = 'running' WHERE resource_id = v_id;         -- simulated boot
  RETURN v_id;
END $$;

-- Quota enforcement WITH the lock. Concurrency concept: SELECT ... FOR UPDATE on the quota row
-- serialises provisioning per project, so the count-then-insert below cannot interleave.
CREATE FUNCTION sp_provision_vm(p_project integer, p_name text, p_vcpus integer, p_mem_mb integer,
                                p_network integer, p_image text DEFAULT 'ubuntu:24.04') RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_max  integer;
  v_used integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'create', 'compute');
  SELECT max_units INTO v_max FROM quotas
   WHERE project_id = p_project AND resource_type_id = 1 FOR UPDATE;      -- <- the lock
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No compute quota defined for project %', p_project;
  END IF;
  SELECT count(*) INTO v_used FROM resources
   WHERE project_id = p_project AND type_id = 1 AND state <> 'terminated';
  IF v_used >= v_max THEN
    RAISE EXCEPTION 'Quota exceeded: % of % VMs used', v_used, v_max;
  END IF;
  RETURN _provision_vm_insert(p_project, p_name, p_vcpus, p_mem_mb, p_network, p_image);
END $$;

-- DEMO ONLY: identical but WITHOUT the lock and with an optional pause between check and
-- insert, which widens the race window. Two sessions both see "used < max" and both insert.
CREATE FUNCTION sp_provision_vm_unsafe(p_project integer, p_name text, p_vcpus integer, p_mem_mb integer,
                                       p_network integer, p_sleep_seconds double precision DEFAULT 0,
                                       p_image text DEFAULT 'ubuntu:24.04') RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_max  integer;
  v_used integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'create', 'compute');
  SELECT max_units INTO v_max FROM quotas WHERE project_id = p_project AND resource_type_id = 1;  -- no lock
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No compute quota defined for project %', p_project;
  END IF;
  SELECT count(*) INTO v_used FROM resources
   WHERE project_id = p_project AND type_id = 1 AND state <> 'terminated';
  IF v_used >= v_max THEN
    RAISE EXCEPTION 'Quota exceeded: % of % VMs used', v_used, v_max;
  END IF;
  IF p_sleep_seconds > 0 THEN PERFORM pg_sleep(p_sleep_seconds); END IF;
  RETURN _provision_vm_insert(p_project, p_name, p_vcpus, p_mem_mb, p_network, p_image);
END $$;

CREATE FUNCTION sp_create_volume(p_project integer, p_name text, p_size_gb integer,
                                 p_mount_path text DEFAULT NULL) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_max  integer;
  v_used integer;
  v_id   integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'create', 'storage');
  SELECT max_units INTO v_max FROM quotas
   WHERE project_id = p_project AND resource_type_id = 2 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No storage quota defined for project %', p_project;
  END IF;
  SELECT coalesce(sum(sv.size_gb), 0) INTO v_used
    FROM resources r JOIN storage_volumes sv USING (resource_id)
   WHERE r.project_id = p_project AND r.state <> 'terminated';
  IF v_used + p_size_gb > v_max THEN
    RAISE EXCEPTION 'Quota exceeded: % of % GB used (requested %)', v_used, v_max, p_size_gb;
  END IF;
  INSERT INTO resources (project_id, type_id, name, state, source)
  VALUES (p_project, 2, p_name, 'pending', 'provisioned') RETURNING resource_id INTO v_id;
  INSERT INTO storage_volumes (resource_id, size_gb, mount_path) VALUES (v_id, p_size_gb, p_mount_path);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_id, p_project, tstzrange(now(), NULL));
  UPDATE resources SET state = 'running' WHERE resource_id = v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION sp_create_network(p_project integer, p_name text, p_cidr cidr) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_max  integer;
  v_used integer;
  v_id   integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'create', 'network');
  SELECT max_units INTO v_max FROM quotas
   WHERE project_id = p_project AND resource_type_id = 3 FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'No network quota defined for project %', p_project;
  END IF;
  SELECT count(*) INTO v_used FROM resources
   WHERE project_id = p_project AND type_id = 3 AND state <> 'terminated';
  IF v_used >= v_max THEN
    RAISE EXCEPTION 'Quota exceeded: % of % networks used', v_used, v_max;
  END IF;
  IF EXISTS (SELECT 1 FROM networks n JOIN resources r USING (resource_id)
              WHERE r.project_id = p_project AND r.state <> 'terminated' AND n.cidr && p_cidr) THEN
    RAISE EXCEPTION 'CIDR % overlaps an existing network of project %', p_cidr, p_project;
  END IF;
  INSERT INTO resources (project_id, type_id, name, state, source)
  VALUES (p_project, 3, p_name, 'pending', 'provisioned') RETURNING resource_id INTO v_id;
  INSERT INTO networks (resource_id, cidr) VALUES (v_id, p_cidr);
  INSERT INTO allocations (resource_id, project_id, period) VALUES (v_id, p_project, tstzrange(now(), NULL));
  UPDATE resources SET state = 'running' WHERE resource_id = v_id;
  RETURN v_id;
END $$;

-- start / stop a compute instance (state machine decides legality)
CREATE FUNCTION sp_set_resource_state(p_resource integer, p_state text) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_res resources%ROWTYPE;
BEGIN
  SELECT * INTO v_res FROM resources WHERE resource_id = p_resource FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Resource % does not exist', p_resource; END IF;
  PERFORM fn_assert_permission(v_res.project_id, 'update', (SELECT name FROM resource_types WHERE type_id = v_res.type_id));
  UPDATE resources SET state = p_state WHERE resource_id = p_resource;   -- trg_state_machine validates
  RETURN p_state;
END $$;

CREATE FUNCTION sp_terminate_resource(p_resource integer) RETURNS text
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_res resources%ROWTYPE;
BEGIN
  SELECT * INTO v_res FROM resources WHERE resource_id = p_resource FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'Resource % does not exist', p_resource; END IF;
  PERFORM fn_assert_permission(v_res.project_id, 'delete', (SELECT name FROM resource_types WHERE type_id = v_res.type_id));
  IF v_res.state = 'terminated' THEN
    RAISE EXCEPTION 'Resource % is already terminated', p_resource;
  END IF;
  IF v_res.type_id = 3 AND EXISTS (
       SELECT 1 FROM network_attachments na JOIN resources vm ON vm.resource_id = na.resource_id
        WHERE na.network_id = p_resource AND vm.state <> 'terminated') THEN
    RAISE EXCEPTION 'Network % still has attached instances', p_resource;
  END IF;
  DELETE FROM network_attachments WHERE resource_id = p_resource;          -- release the IP
  UPDATE resources SET state = 'terminated' WHERE resource_id = p_resource; -- trg_allocation_close fires
  RETURN 'terminated';
END $$;

-- ---------------------------------------------------------------------------------------------
-- Administration used by the Access / Alerts / Billing screens.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION sp_add_member(p_project integer, p_user integer, p_role text) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_role integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'manage', 'member');
  SELECT role_id INTO v_role FROM roles WHERE name = p_role;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown role %', p_role; END IF;
  INSERT INTO project_members (project_id, user_id, role_id) VALUES (p_project, p_user, v_role)
  ON CONFLICT (project_id, user_id) DO UPDATE SET role_id = EXCLUDED.role_id;
END $$;

CREATE FUNCTION sp_remove_member(p_project integer, p_user integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
BEGIN
  PERFORM fn_assert_permission(p_project, 'manage', 'member');
  IF (SELECT owner_id FROM projects WHERE project_id = p_project) = p_user THEN
    RAISE EXCEPTION 'The project owner cannot be removed';
  END IF;
  DELETE FROM project_members WHERE project_id = p_project AND user_id = p_user;
END $$;

CREATE FUNCTION sp_set_quota(p_project integer, p_type text, p_max_units integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_type integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'manage', 'quota');
  SELECT type_id INTO v_type FROM resource_types WHERE name = p_type;
  IF NOT FOUND THEN RAISE EXCEPTION 'Unknown resource type %', p_type; END IF;
  INSERT INTO quotas (project_id, resource_type_id, max_units) VALUES (p_project, v_type, p_max_units)
  ON CONFLICT (project_id, resource_type_id) DO UPDATE SET max_units = EXCLUDED.max_units;
END $$;

CREATE FUNCTION sp_create_alert_rule(p_project integer, p_metric text, p_operator text,
                                     p_threshold double precision, p_window_seconds integer) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id integer;
BEGIN
  PERFORM fn_assert_permission(p_project, 'create', 'alert_rule');
  INSERT INTO alert_rules (project_id, metric, operator, threshold, window_seconds)
  VALUES (p_project, p_metric, p_operator, p_threshold, p_window_seconds) RETURNING rule_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION sp_delete_alert_rule(p_rule integer) RETURNS void
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_project integer;
BEGIN
  SELECT project_id INTO v_project FROM alert_rules WHERE rule_id = p_rule;
  IF NOT FOUND THEN RAISE EXCEPTION 'Alert rule % does not exist', p_rule; END IF;
  PERFORM fn_assert_permission(v_project, 'delete', 'alert_rule');
  DELETE FROM alert_rules WHERE rule_id = p_rule;
END $$;

CREATE FUNCTION sp_create_billing_cycle(p_from timestamptz, p_to timestamptz) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_id integer;
BEGIN
  IF session_user IN ('crms_app', 'crms_readonly') AND NOT fn_is_admin() THEN
    RAISE EXCEPTION 'Permission denied: only admins manage billing cycles' USING ERRCODE = 'insufficient_privilege';
  END IF;
  INSERT INTO billing_cycles (period) VALUES (tstzrange(p_from, p_to)) RETURNING cycle_id INTO v_id;
  RETURN v_id;
END $$;

CREATE FUNCTION sp_record_payment(p_invoice integer, p_amount numeric) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_project integer;
  v_id integer;
BEGIN
  SELECT project_id INTO v_project FROM invoices WHERE invoice_id = p_invoice;
  IF NOT FOUND THEN RAISE EXCEPTION 'Invoice % does not exist', p_invoice; END IF;
  PERFORM fn_assert_permission(v_project, 'create', 'payment');
  INSERT INTO payments (invoice_id, amount) VALUES (p_invoice, p_amount) RETURNING payment_id INTO v_id;
  RETURN v_id;
END $$;

-- Login: verifies the pgcrypto hash inside the database; returns the user and their top role.
CREATE FUNCTION sp_login(p_email text, p_password text)
RETURNS TABLE (user_id integer, email text, name text, role text)
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT u.user_id, u.email, u.name,
         coalesce((SELECT r.name FROM project_members pm JOIN roles r USING (role_id)
                    WHERE pm.user_id = u.user_id
                    ORDER BY CASE r.name WHEN 'admin' THEN 1 WHEN 'manager' THEN 2
                                         WHEN 'developer' THEN 3 ELSE 4 END LIMIT 1), 'viewer')
    FROM users u
   WHERE u.email = lower(p_email) AND u.status = 'active'
     AND u.password_hash IS NOT NULL AND u.password_hash = crypt(p_password, u.password_hash)
$$;
