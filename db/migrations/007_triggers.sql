-- 007: triggers. Rules that must hold no matter which client writes.

-- ---------------------------------------------------------------------------------------------
-- fn_current_user: the application user for this transaction, set by the API with
--   SET LOCAL crms.user_id = <id>      (NULL when unset)
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_current_user() RETURNS integer
LANGUAGE sql STABLE AS $$
  SELECT nullif(current_setting('crms.user_id', true), '')::integer
$$;

-- True when the caller is one of the application roles (by login or via SET ROLE). Procedures use
-- it to tell a user-facing connection (must carry a user) from a trusted maintenance session.
CREATE FUNCTION fn_is_app_caller() RETURNS boolean
LANGUAGE sql STABLE AS $$
  SELECT session_user IN ('crms_app', 'crms_readonly', 'crms_collector')
      OR coalesce(current_setting('role', true), 'none') IN ('crms_app', 'crms_readonly', 'crms_collector')
$$;

-- ---------------------------------------------------------------------------------------------
-- trg_audit: ONE generic function for every audited table (to_jsonb(OLD/NEW) makes it
-- schema-agnostic). TG_ARGV lists the primary-key column(s) so row_pk can be built generically.
-- SECURITY DEFINER: callers hold no INSERT right on audit_log.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_audit() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_old jsonb := CASE WHEN TG_OP IN ('UPDATE', 'DELETE') THEN to_jsonb(OLD) END;
  v_new jsonb := CASE WHEN TG_OP IN ('INSERT', 'UPDATE') THEN to_jsonb(NEW) END;
  v_row jsonb := coalesce(v_new, v_old);
  v_pk  text;
BEGIN
  SELECT string_agg(v_row ->> k, ',' ORDER BY ord) INTO v_pk
    FROM unnest(TG_ARGV) WITH ORDINALITY AS t(k, ord);
  -- Skip no-op updates (touch trigger only bumped updated_at, or nothing changed).
  IF TG_OP = 'UPDATE' AND (v_old - 'updated_at') = (v_new - 'updated_at') THEN
    RETURN NEW;
  END IF;
  INSERT INTO audit_log (actor_id, table_name, op, row_pk, old_data, new_data)
  VALUES (fn_current_user(), TG_TABLE_NAME, TG_OP, v_pk, v_old, v_new);
  RETURN coalesce(NEW, OLD);
END $$;

CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON resources
  FOR EACH ROW EXECUTE FUNCTION fn_audit('resource_id');
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON quotas
  FOR EACH ROW EXECUTE FUNCTION fn_audit('project_id', 'resource_type_id');
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON project_members
  FOR EACH ROW EXECUTE FUNCTION fn_audit('project_id', 'user_id');
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON pricing_plans
  FOR EACH ROW EXECUTE FUNCTION fn_audit('plan_id');
CREATE TRIGGER trg_audit AFTER INSERT OR UPDATE OR DELETE ON invoices
  FOR EACH ROW EXECUTE FUNCTION fn_audit('invoice_id');

-- ---------------------------------------------------------------------------------------------
-- trg_audit_immutable: the audit trail is append-only, even for the table owner.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_audit_immutable() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  RAISE EXCEPTION 'audit_log is append-only (% blocked)', TG_OP;
END $$;

CREATE TRIGGER trg_audit_immutable BEFORE UPDATE OR DELETE ON audit_log
  FOR EACH ROW EXECUTE FUNCTION fn_audit_immutable();
-- TRUNCATE bypasses row triggers, so block it with a statement trigger as well.
CREATE TRIGGER trg_audit_no_truncate BEFORE TRUNCATE ON audit_log
  FOR EACH STATEMENT EXECUTE FUNCTION fn_audit_immutable();

-- ---------------------------------------------------------------------------------------------
-- trg_touch_updated_at
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_touch_updated_at() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  NEW.updated_at := now();
  RETURN NEW;
END $$;

CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON users
  FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();
CREATE TRIGGER trg_touch_updated_at BEFORE UPDATE ON resources
  FOR EACH ROW EXECUTE FUNCTION fn_touch_updated_at();

-- ---------------------------------------------------------------------------------------------
-- trg_state_machine: only legal lifecycle transitions; terminated is final.
--   pending -> running | terminated
--   running -> stopped | terminated
--   stopped -> running | terminated
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_state_machine() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  IF OLD.state = NEW.state THEN
    RETURN NEW;
  END IF;
  IF NOT ((OLD.state, NEW.state) IN (
        ('pending', 'running'), ('pending', 'terminated'),
        ('running', 'stopped'), ('running', 'terminated'),
        ('stopped', 'running'), ('stopped', 'terminated'))) THEN
    RAISE EXCEPTION 'Illegal state transition: % -> %', OLD.state, NEW.state;
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_state_machine BEFORE UPDATE OF state ON resources
  FOR EACH ROW EXECUTE FUNCTION fn_state_machine();

-- ---------------------------------------------------------------------------------------------
-- trg_allocation_close: termination ends billing. The open range is closed at now() (or one
-- microsecond after its start when the resource is created and terminated in one transaction,
-- because an empty range is not allowed).
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_allocation_close() RETURNS trigger
LANGUAGE plpgsql AS $$
BEGIN
  UPDATE allocations
     SET period = tstzrange(lower(period), greatest(now(), lower(period) + interval '1 microsecond'))
   WHERE resource_id = NEW.resource_id AND upper_inf(period);
  RETURN NEW;
END $$;

CREATE TRIGGER trg_allocation_close AFTER UPDATE OF state ON resources
  FOR EACH ROW WHEN (NEW.state = 'terminated' AND OLD.state <> 'terminated')
  EXECUTE FUNCTION fn_allocation_close();

-- ---------------------------------------------------------------------------------------------
-- Supertype/subtype TOTALITY: every resource must have exactly the subtype row matching its
-- type. A deferred constraint trigger checks at COMMIT so the resource and its subtype can be
-- inserted in either order inside one transaction. (Disjointness is the composite FK in 003.)
-- ---------------------------------------------------------------------------------------------
-- SECURITY DEFINER because deferred triggers fire at COMMIT, after the calling procedure has
-- returned, i.e. with the privileges of the connected role (e.g. crms_collector, who can read nothing).
CREATE FUNCTION fn_resource_total() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_ok boolean;
BEGIN
  SELECT CASE r.type_id
           WHEN 1 THEN EXISTS (SELECT 1 FROM compute_instances WHERE resource_id = r.resource_id)
           WHEN 2 THEN EXISTS (SELECT 1 FROM storage_volumes WHERE resource_id = r.resource_id)
           WHEN 3 THEN EXISTS (SELECT 1 FROM networks WHERE resource_id = r.resource_id)
         END
    INTO v_ok
    FROM resources r WHERE r.resource_id = NEW.resource_id;
  IF v_ok IS NOT NULL AND NOT v_ok THEN   -- NULL: row already deleted in this transaction
    RAISE EXCEPTION 'resource % has no subtype row for its type', NEW.resource_id
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NULL;
END $$;

CREATE CONSTRAINT TRIGGER trg_resource_total AFTER INSERT ON resources
  DEFERRABLE INITIALLY DEFERRED FOR EACH ROW EXECUTE FUNCTION fn_resource_total();

-- ---------------------------------------------------------------------------------------------
-- network_attachments: the address must be a usable host address inside the network's CIDR.
-- A CHECK cannot look at another table, so this is a trigger.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_attachment_ip_in_cidr() RETURNS trigger
LANGUAGE plpgsql AS $$
DECLARE
  v_cidr cidr;
BEGIN
  SELECT cidr INTO v_cidr FROM networks WHERE resource_id = NEW.network_id;
  NEW.ip := host(NEW.ip)::inet;                      -- store hosts as /32 (or /128) so UNIQUE compares equal
  IF NOT (NEW.ip << v_cidr) THEN
    RAISE EXCEPTION 'ip % is outside network %', NEW.ip, v_cidr USING ERRCODE = 'check_violation';
  END IF;
  IF family(v_cidr) = 4 AND masklen(v_cidr) < 31
     AND (NEW.ip = host(network(v_cidr))::inet OR NEW.ip = host(broadcast(v_cidr))::inet) THEN
    RAISE EXCEPTION 'ip % is the network or broadcast address of %', NEW.ip, v_cidr
      USING ERRCODE = 'check_violation';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_attachment_ip BEFORE INSERT OR UPDATE OF ip, network_id ON network_attachments
  FOR EACH ROW EXECUTE FUNCTION fn_attachment_ip_in_cidr();

-- ---------------------------------------------------------------------------------------------
-- Payments settle invoices: when payments cover the total, the invoice becomes 'paid'.
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_payment_settle() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  v_inv invoices%ROWTYPE;
BEGIN
  SELECT * INTO v_inv FROM invoices WHERE invoice_id = NEW.invoice_id FOR UPDATE;
  IF v_inv.status IN ('void', 'draft') THEN
    RAISE EXCEPTION 'Invoice % is % and cannot be paid', v_inv.invoice_id, v_inv.status;
  END IF;
  IF (SELECT sum(amount) FROM payments WHERE invoice_id = NEW.invoice_id) >= v_inv.total THEN
    UPDATE invoices SET status = 'paid' WHERE invoice_id = NEW.invoice_id AND status <> 'paid';
  END IF;
  RETURN NEW;
END $$;

CREATE TRIGGER trg_payment_settle AFTER INSERT ON payments
  FOR EACH ROW EXECUTE FUNCTION fn_payment_settle();

-- ---------------------------------------------------------------------------------------------
-- trg_metric_alert: evaluate every rule of the resource's project for the inserted metric.
-- The window average is compared with the threshold; a breach opens an alert_event, recovery
-- resolves it. pg_notify('alerts', json) pushes the change to LISTENing clients (API SSE).
-- ---------------------------------------------------------------------------------------------
CREATE FUNCTION fn_metric_alert() RETURNS trigger
LANGUAGE plpgsql SECURITY DEFINER SET search_path = public, pg_temp AS $$
DECLARE
  r        record;
  v_avg    double precision;
  v_max    double precision;
  v_breach boolean;
  v_event  alert_events%ROWTYPE;
BEGIN
  FOR r IN
    SELECT ar.rule_id, ar.operator, ar.threshold, ar.window_seconds, res.project_id
      FROM resources res
      JOIN alert_rules ar ON ar.project_id = res.project_id AND ar.metric = NEW.metric
     WHERE res.resource_id = NEW.resource_id
  LOOP
    SELECT avg(value), max(value) INTO v_avg, v_max
      FROM usage_metrics
     WHERE resource_id = NEW.resource_id AND metric = NEW.metric
       AND ts > NEW.ts - make_interval(secs => r.window_seconds) AND ts <= NEW.ts;

    v_breach := CASE r.operator
                  WHEN '>'  THEN v_avg >  r.threshold
                  WHEN '>=' THEN v_avg >= r.threshold
                  WHEN '<'  THEN v_avg <  r.threshold
                  WHEN '<=' THEN v_avg <= r.threshold
                END;

    SELECT * INTO v_event FROM alert_events
     WHERE rule_id = r.rule_id AND resource_id = NEW.resource_id AND resolved_at IS NULL;

    IF v_breach AND NOT FOUND THEN
      INSERT INTO alert_events (rule_id, resource_id, fired_at, peak_value)
      VALUES (r.rule_id, NEW.resource_id, NEW.ts, v_max);
      PERFORM pg_notify('alerts', json_build_object(
        'type', 'fired', 'rule_id', r.rule_id, 'project_id', r.project_id,
        'resource_id', NEW.resource_id, 'metric', NEW.metric, 'value', v_avg, 'at', NEW.ts)::text);
    ELSIF v_breach THEN
      UPDATE alert_events SET peak_value = greatest(peak_value, v_max)
       WHERE event_id = v_event.event_id AND peak_value < v_max;
    ELSIF FOUND THEN
      UPDATE alert_events SET resolved_at = greatest(NEW.ts, fired_at)
       WHERE event_id = v_event.event_id;
      PERFORM pg_notify('alerts', json_build_object(
        'type', 'resolved', 'rule_id', r.rule_id, 'project_id', r.project_id,
        'resource_id', NEW.resource_id, 'metric', NEW.metric, 'value', v_avg, 'at', NEW.ts)::text);
    END IF;
  END LOOP;
  RETURN NULL;
END $$;

CREATE TRIGGER trg_metric_alert AFTER INSERT ON usage_metrics
  FOR EACH ROW EXECUTE FUNCTION fn_metric_alert();
