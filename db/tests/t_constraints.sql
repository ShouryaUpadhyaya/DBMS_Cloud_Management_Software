-- Every constraint must reject bad data (SQLSTATE: 23505 unique, 23514 check, 23503 FK, 23P01 exclusion).
DO $t$
DECLARE
  wp   integer := pg_temp.pid('Web Platform');
  web1 integer := pg_temp.rid('web-1');
  net  integer := pg_temp.rid('web-net');
  vol  integer := pg_temp.rid('pgdata');
  alice integer := pg_temp.uid('alice@crms.test');
BEGIN
  -- users
  PERFORM pg_temp.expect_error($$INSERT INTO users (email, name) VALUES ('alice@crms.test', 'Dup')$$, '23505', 'users.email unique');
  PERFORM pg_temp.expect_error($$INSERT INTO users (email, name) VALUES ('UPPER@crms.test', 'X')$$, '23514', 'email must be lowercase');
  PERFORM pg_temp.expect_error($$INSERT INTO users (email, name) VALUES ('nomail', 'X')$$, '23514', 'email must look like an address');
  PERFORM pg_temp.expect_error($$INSERT INTO users (email, name, status) VALUES ('s@crms.test', 'X', 'banned')$$, '23514', 'users.status enum');
  PERFORM pg_temp.expect_error($$INSERT INTO users (email, name) VALUES ('e@crms.test', '  ')$$, '23514', 'users.name not blank');
  -- roles / permissions
  PERFORM pg_temp.expect_error($$INSERT INTO roles (name) VALUES ('admin')$$, '23505', 'roles.name unique');
  PERFORM pg_temp.expect_error($$UPDATE roles SET parent_role_id = role_id WHERE name = 'viewer'$$, '23514', 'role cannot be its own parent');
  PERFORM pg_temp.expect_error($$INSERT INTO roles (name, parent_role_id) VALUES ('ghost', 9999)$$, '23503', 'parent role must exist');
  PERFORM pg_temp.expect_error($$INSERT INTO permissions (action, resource_type) VALUES ('view', 'resource')$$, '23505', 'permission unique');
  PERFORM pg_temp.expect_error($$INSERT INTO role_permissions SELECT role_id, perm_id FROM role_permissions LIMIT 1$$, '23505', 'role_permissions pk');
  PERFORM pg_temp.expect_error(format($$INSERT INTO api_keys (user_id, key_hash, created_at, revoked_at) VALUES (%s, 'h', now(), now() - interval '1 day')$$, alice), '23514', 'revoked_at >= created_at');
  -- projects / membership / quotas
  PERFORM pg_temp.expect_error($$INSERT INTO projects (name, owner_id) VALUES ('Web Platform', 1)$$, '23505', 'projects.name unique');
  PERFORM pg_temp.expect_error(format($$UPDATE projects SET parent_project_id = project_id WHERE project_id = %s$$, wp), '23514', 'project cannot be its own parent');
  PERFORM pg_temp.expect_error(format($$INSERT INTO project_members VALUES (%s, %s, 1)$$, wp, alice), '23505', 'membership pk');
  PERFORM pg_temp.expect_error(format($$INSERT INTO project_members VALUES (%s, 9999, 1)$$, wp), '23503', 'member user must exist');
  PERFORM pg_temp.expect_error(format($$UPDATE quotas SET max_units = -1 WHERE project_id = %s$$, wp), '23514', 'quota >= 0');
  -- resources and subtypes
  PERFORM pg_temp.expect_error(format($$INSERT INTO resources (project_id, type_id, name, state) VALUES (%s, 1, 'x', 'exploded')$$, wp), '23514', 'resources.state enum');
  PERFORM pg_temp.expect_error(format($$INSERT INTO resources (project_id, type_id, name, source) VALUES (%s, 1, 'x', 'magic')$$, wp), '23514', 'resources.source enum');
  PERFORM pg_temp.expect_error(format($$INSERT INTO resources (project_id, type_id, name, external_id) VALUES (%s, 1, 'x', 'abc')$$, wp), '23514', 'only discovered resources have external_id');
  PERFORM pg_temp.expect_error(format($$INSERT INTO resources (project_id, type_id, name, external_id, source) VALUES (%s, 1, 'x', 'mock-web-1', 'discovered')$$, wp), '23505', 'external_id unique');
  PERFORM pg_temp.expect_error(format($$INSERT INTO resources (project_id, type_id, name) VALUES (%s, 1, 'web-1')$$, wp), '23505', 'live name unique per project');
  PERFORM pg_temp.expect_error(format($$INSERT INTO resources (project_id, type_id, name) VALUES (%s, 9, 'x')$$, wp), '23503', 'resource type must exist');
  PERFORM pg_temp.expect_error($$DELETE FROM projects WHERE name = 'Web Platform'$$, '23503', 'ON DELETE RESTRICT protects projects with resources');
  PERFORM pg_temp.expect_error(format($$INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (%s, 0, 512)$$, 1), '23514', 'vcpus > 0 (or FK)');
  PERFORM pg_temp.expect_error(format($$UPDATE compute_instances SET vcpus = 0 WHERE resource_id = %s$$, web1), '23514', 'vcpus > 0');
  PERFORM pg_temp.expect_error(format($$UPDATE compute_instances SET memory_mb = 0 WHERE resource_id = %s$$, web1), '23514', 'memory_mb > 0');
  PERFORM pg_temp.expect_error(format($$UPDATE storage_volumes SET size_gb = 0 WHERE resource_id = %s$$, vol), '23514', 'size_gb > 0');
  -- disjointness: a compute row cannot point at a storage resource (composite FK pins type_id)
  PERFORM pg_temp.expect_error(format($$INSERT INTO compute_instances (resource_id, vcpus, memory_mb) VALUES (%s, 1, 512)$$, vol), '23503', 'subtype disjointness');
  PERFORM pg_temp.expect_error(format($$INSERT INTO compute_instances (resource_id, type_id, vcpus, memory_mb) VALUES (%s, 2, 1, 512)$$, vol), '23514', 'subtype type_id is pinned');
  -- totality: resource without its subtype row fails at commit time (forced here with IMMEDIATE)
  PERFORM pg_temp.expect_error(format($x$DO $b$ BEGIN
      INSERT INTO resources (project_id, type_id, name) VALUES (%s, 1, 'orphan');
      SET CONSTRAINTS ALL IMMEDIATE; END $b$$x$, wp), '23514', 'subtype totality');
  -- networking
  PERFORM pg_temp.expect_error(format($$INSERT INTO network_attachments (resource_id, network_id, ip) VALUES (%s, %s, '10.10.1.1')$$, pg_temp.rid('staging-web-1'), net), '23505', 'ip unique per network');
  PERFORM pg_temp.expect_error(format($$INSERT INTO network_attachments (resource_id, network_id, ip) VALUES (%s, %s, '192.168.0.9')$$, pg_temp.rid('staging-web-1'), net), '23514', 'ip must be inside cidr');
  PERFORM pg_temp.expect_error(format($$INSERT INTO network_attachments (resource_id, network_id, ip) VALUES (%s, %s, '10.10.1.0')$$, pg_temp.rid('staging-web-1'), net), '23514', 'network address not usable');
  PERFORM pg_temp.expect_error(format($$INSERT INTO network_attachments (resource_id, network_id, ip) VALUES (%s, %s, '10.10.1.255')$$, pg_temp.rid('staging-web-1'), net), '23514', 'broadcast address not usable');
  -- pricing / allocations / billing
  PERFORM pg_temp.expect_error($$INSERT INTO pricing_plans (type_id, unit_price, effective_from) VALUES (1, -1, now())$$, '23514', 'price >= 0');
  PERFORM pg_temp.expect_error($$INSERT INTO pricing_plans (type_id, unit_price, effective_from, effective_to) VALUES (1, 1, now(), now() - interval '1 day')$$, '23514', 'effective_to > effective_from');
  PERFORM pg_temp.expect_error($$INSERT INTO pricing_plans (type_id, unit_price, effective_from) VALUES (1, 1, now() - interval '5 days')$$, '23P01', 'pricing ranges must not overlap per type');
  PERFORM pg_temp.expect_error(format($$INSERT INTO allocations (resource_id, project_id, period) VALUES (%s, %s, tstzrange(now() + interval '1 day', NULL))$$, web1, wp), '23P01', 'allocations must not overlap per resource');
  PERFORM pg_temp.expect_error(format($$INSERT INTO allocations (resource_id, project_id, period) VALUES (%s, %s, 'empty')$$, vol, wp), '23514', 'allocation range must not be empty');
  PERFORM pg_temp.expect_error($$INSERT INTO billing_cycles (period) SELECT period FROM billing_cycles LIMIT 1$$, '23P01', 'billing cycles must not overlap');
  PERFORM pg_temp.expect_error($$INSERT INTO billing_cycles (period) VALUES (tstzrange(now(), NULL))$$, '23514', 'billing cycle must be bounded');
  PERFORM pg_temp.expect_error(format($$INSERT INTO invoices (project_id, cycle_id) SELECT %s, cycle_id FROM billing_cycles LIMIT 1$$, wp), '23505', 'one invoice per project and cycle');
  PERFORM pg_temp.expect_error(format($$INSERT INTO invoices (project_id, cycle_id, total, status) VALUES (%s, 1, -5, 'draft')$$, pg_temp.pid('Unassigned')), '23514', 'invoice total >= 0');
  PERFORM pg_temp.expect_error(format($$INSERT INTO invoices (project_id, cycle_id, status) VALUES (%s, 1, 'lost')$$, pg_temp.pid('Unassigned')), '23514', 'invoice status enum');
  PERFORM pg_temp.expect_error($$UPDATE invoice_line_items SET amount = -1 WHERE line_no = 1$$, '23514', 'line amount >= 0');
  PERFORM pg_temp.expect_error($$INSERT INTO invoice_line_items SELECT invoice_id, line_no, resource_id, units, unit_price, amount FROM invoice_line_items LIMIT 1$$, '23505', 'line item pk (weak entity)');
  PERFORM pg_temp.expect_error($$INSERT INTO invoice_line_items VALUES (9999, 1, 1, 1, 1, 1)$$, '23503', 'line item needs its invoice');
  PERFORM pg_temp.expect_error($$INSERT INTO payments (invoice_id, amount) VALUES (1, 0)$$, '23514', 'payment amount > 0');
  -- telemetry
  PERFORM pg_temp.expect_error(format($$INSERT INTO usage_metrics VALUES (%s, now(), 'bogus', 1)$$, web1), '23514', 'metric name enum');
  PERFORM pg_temp.expect_error(format($$INSERT INTO usage_metrics VALUES (%s, now(), 'cpu_percent', -1)$$, web1), '23514', 'metric value >= 0');
  PERFORM pg_temp.expect_error(format($$INSERT INTO usage_metrics SELECT resource_id, ts, metric, value FROM usage_metrics WHERE resource_id = %s LIMIT 1$$, web1), '23505', 'metric pk');
  PERFORM pg_temp.expect_error(format($$INSERT INTO usage_metrics VALUES (%s, now() + interval '20 years', 'cpu_percent', 1)$$, web1), '23514', 'row without partition is rejected');
  PERFORM pg_temp.expect_error(format($$INSERT INTO log_entries (resource_id, ts, level, message) VALUES (%s, now(), 'fatal', 'x')$$, web1), '23514', 'log level enum');
  PERFORM pg_temp.expect_error(format($$INSERT INTO alert_rules (project_id, metric, operator, threshold, window_seconds) VALUES (%s, 'cpu_percent', '!=', 1, 60)$$, wp), '23514', 'alert operator enum');
  PERFORM pg_temp.expect_error(format($$INSERT INTO alert_rules (project_id, metric, operator, threshold, window_seconds) VALUES (%s, 'cpu_percent', '>', 1, 0)$$, wp), '23514', 'alert window > 0');
  PERFORM pg_temp.expect_error($$UPDATE alert_events SET resolved_at = fired_at - interval '1 hour' WHERE resolved_at IS NOT NULL$$, '23514', 'resolved_at >= fired_at');
  PERFORM pg_temp.expect_error($$INSERT INTO alert_events (rule_id, resource_id, peak_value) SELECT rule_id, resource_id, 1 FROM alert_events WHERE resolved_at IS NULL LIMIT 1$$, '23505', 'one open alert per rule+resource');
  PERFORM pg_temp.expect_error($$INSERT INTO audit_log (table_name, op, row_pk) VALUES ('x', 'MERGE', '1')$$, '23514', 'audit op enum');
END $t$;
