-- 008: authorisation, addressing, costing and partition helpers.

-- Admin = holds the 'admin' role in any project. Used for RLS bypass and permission shortcut.
-- SECURITY DEFINER so it can read project_members regardless of the caller's rights.
CREATE FUNCTION fn_user_is_admin(p_user integer) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT EXISTS (
    SELECT 1 FROM project_members pm
      JOIN roles r ON r.role_id = pm.role_id
      JOIN users u ON u.user_id = pm.user_id
     WHERE pm.user_id = p_user AND r.name = 'admin' AND u.status = 'active')
$$;

CREATE FUNCTION fn_is_admin() RETURNS boolean
LANGUAGE sql STABLE AS $$ SELECT coalesce(fn_user_is_admin(fn_current_user()), false) $$;

CREATE FUNCTION fn_can_see_project(p_project integer) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT fn_is_admin() OR EXISTS (
    SELECT 1 FROM project_members WHERE project_id = p_project AND user_id = fn_current_user())
$$;

-- Recursive CTE over the role hierarchy: start at the user's role in the project, walk up
-- parent_role_id, and collect the permissions of every role on the way.
CREATE FUNCTION fn_has_permission(p_user integer, p_project integer, p_action text,
                                  p_resource_type text DEFAULT NULL) RETURNS boolean
LANGUAGE sql STABLE SECURITY DEFINER SET search_path = public, pg_temp AS $$
  SELECT fn_user_is_admin(p_user) OR EXISTS (
    WITH RECURSIVE chain(role_id, parent_role_id) AS (
      SELECT r.role_id, r.parent_role_id
        FROM project_members pm
        JOIN roles r ON r.role_id = pm.role_id
        JOIN users u ON u.user_id = pm.user_id AND u.status = 'active'
       WHERE pm.user_id = p_user AND pm.project_id = p_project
      UNION
      SELECT r.role_id, r.parent_role_id
        FROM roles r JOIN chain c ON r.role_id = c.parent_role_id
    )
    SELECT 1 FROM chain
      JOIN role_permissions rp ON rp.role_id = chain.role_id
      JOIN permissions p ON p.perm_id = rp.perm_id
     WHERE p.action = p_action AND (p_resource_type IS NULL OR p.resource_type = p_resource_type))
$$;

-- Guard used by every sp_* procedure. A connection from an application role must carry a user;
-- a maintenance session (superuser, no crms.user_id) is trusted.
CREATE FUNCTION fn_assert_permission(p_project integer, p_action text, p_resource_type text DEFAULT NULL)
RETURNS void
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_user integer := fn_current_user();
BEGIN
  IF v_user IS NULL THEN
    IF session_user IN ('crms_app', 'crms_readonly', 'crms_collector') THEN
      RAISE EXCEPTION 'No user context' USING ERRCODE = 'insufficient_privilege';
    END IF;
    RETURN;
  END IF;
  IF NOT fn_has_permission(v_user, p_project, p_action, p_resource_type) THEN
    RAISE EXCEPTION 'Permission denied: % % in project %', p_action, coalesce(p_resource_type, '*'), p_project
      USING ERRCODE = 'insufficient_privilege';
  END IF;
END $$;

-- First free host address in the network's CIDR (IPv4 and IPv6; scan capped at 65534 hosts).
CREATE FUNCTION fn_next_free_ip(p_network integer) RETURNS inet
LANGUAGE plpgsql STABLE AS $$
DECLARE
  v_cidr cidr;
  v_size numeric;
  v_ip   inet;
BEGIN
  SELECT cidr INTO v_cidr FROM networks WHERE resource_id = p_network;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'Network % does not exist', p_network;
  END IF;
  IF family(v_cidr) = 4 THEN
    v_size := 2 ^ (32 - masklen(v_cidr)) - 2;                -- minus network and broadcast
  ELSE
    v_size := 65534;
  END IF;
  SELECT host(network(v_cidr)::inet + g)::inet INTO v_ip
    FROM generate_series(1, least(v_size, 65534)::integer) AS g
   WHERE NOT EXISTS (SELECT 1 FROM network_attachments na
                      WHERE na.network_id = p_network AND na.ip = host(network(v_cidr)::inet + g)::inet)
   ORDER BY g LIMIT 1;
  IF v_ip IS NULL THEN
    RAISE EXCEPTION 'Network % has no free addresses', p_network;
  END IF;
  RETURN v_ip;
END $$;

-- Cost segments: allocation range x pricing range x requested window. One row per
-- (allocation, plan) overlap so an invoice can freeze the exact price used for each stretch.
-- quantity = vCPUs for compute, GB for storage, 1 for a network.
CREATE FUNCTION fn_cost_segments(p_resource integer, p_from timestamptz, p_to timestamptz,
                                 p_project integer DEFAULT NULL)
RETURNS TABLE (resource_id integer, plan_id integer, seg_start timestamptz, seg_end timestamptz,
               units numeric, unit_price numeric, amount numeric)
LANGUAGE sql STABLE AS $$
  SELECT a.resource_id, p.plan_id, lower(s.x), upper(s.x),
         round(extract(epoch FROM upper(s.x) - lower(s.x))::numeric / 3600
               * coalesce(ci.vcpus, sv.size_gb, 1), 4)                       AS units,
         p.unit_price,
         round(round(extract(epoch FROM upper(s.x) - lower(s.x))::numeric / 3600
               * coalesce(ci.vcpus, sv.size_gb, 1), 4) * p.unit_price, 2)    AS amount
    FROM allocations a
    JOIN resources r ON r.resource_id = a.resource_id
    JOIN pricing_plans p ON p.type_id = r.type_id
    LEFT JOIN compute_instances ci ON ci.resource_id = r.resource_id
    LEFT JOIN storage_volumes sv ON sv.resource_id = r.resource_id
   CROSS JOIN LATERAL (SELECT a.period * tstzrange(p.effective_from, p.effective_to)
                              * tstzrange(p_from, p_to) AS x) s
   WHERE a.resource_id = p_resource
     AND (p_project IS NULL OR a.project_id = p_project)
     AND NOT isempty(s.x)
   ORDER BY lower(s.x)
$$;

CREATE FUNCTION fn_resource_cost(p_resource integer, p_from timestamptz, p_to timestamptz)
RETURNS numeric
LANGUAGE sql STABLE AS $$
  SELECT coalesce(sum(amount), 0) FROM fn_cost_segments(p_resource, p_from, p_to)
$$;

-- Monthly partitions for usage_metrics and log_entries covering [p_from, p_to].
CREATE FUNCTION fn_ensure_partitions(p_from timestamptz, p_to timestamptz) RETURNS integer
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_month timestamptz := date_trunc('month', p_from AT TIME ZONE 'UTC') AT TIME ZONE 'UTC';
  v_next  timestamptz;
  v_made  integer := 0;
  v_tbl   text;
  v_part  text;
BEGIN
  WHILE v_month <= p_to LOOP
    v_next := v_month + interval '1 month';
    FOREACH v_tbl IN ARRAY ARRAY['usage_metrics', 'log_entries'] LOOP
      v_part := v_tbl || '_' || to_char(v_month AT TIME ZONE 'UTC', 'YYYY_MM');
      IF to_regclass(format('public.%I', v_part)) IS NULL THEN
        EXECUTE format('CREATE TABLE %I PARTITION OF %I FOR VALUES FROM (%L) TO (%L)',
                       v_part, v_tbl, v_month, v_next);
        v_made := v_made + 1;
      END IF;
    END LOOP;
    v_month := v_next;
  END LOOP;
  RETURN v_made;
END $$;

SELECT fn_ensure_partitions(now() - interval '3 months', now() + interval '2 months');
