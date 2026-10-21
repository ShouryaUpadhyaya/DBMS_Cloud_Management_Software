-- Seed 0: reference data every deployment needs (also used by deploy/bootstrap.sql):
-- the role hierarchy, the permission catalogue and the pricing plans.

-- Role hierarchy: admin > manager > developer > viewer (child inherits parent's permissions).
INSERT INTO roles (name, parent_role_id) VALUES ('viewer', NULL);
INSERT INTO roles (name, parent_role_id) SELECT 'developer', role_id FROM roles WHERE name = 'viewer';
INSERT INTO roles (name, parent_role_id) SELECT 'manager', role_id FROM roles WHERE name = 'developer';
INSERT INTO roles (name, parent_role_id) SELECT 'admin', role_id FROM roles WHERE name = 'manager';

INSERT INTO permissions (action, resource_type) VALUES
  ('view','resource'), ('view','metric'), ('view','log'), ('view','alert'), ('view','invoice'),
  ('view','member'), ('view','quota'),
  ('create','compute'), ('create','storage'), ('create','network'), ('create','alert_rule'),
  ('update','compute'), ('update','storage'), ('update','network'),
  ('delete','compute'), ('delete','storage'), ('delete','network'), ('delete','alert_rule'),
  ('manage','member'), ('create','payment'),
  ('manage','quota'), ('create','invoice');

INSERT INTO role_permissions (role_id, perm_id)
SELECT r.role_id, p.perm_id FROM roles r JOIN permissions p ON
  (r.name = 'viewer'    AND p.action = 'view')
  OR (r.name = 'developer' AND p.action IN ('create','update') AND p.resource_type IN ('compute','storage','network','alert_rule'))
  OR (r.name = 'manager'   AND ((p.action = 'delete') OR (p.action = 'manage' AND p.resource_type = 'member')
                                OR (p.action = 'create' AND p.resource_type = 'payment')))
  OR (r.name = 'admin'     AND ((p.action = 'manage' AND p.resource_type = 'quota')
                                OR (p.action = 'create' AND p.resource_type = 'invoice')));

-- Pricing history (non-overlapping per type, enforced by the EXCLUDE constraint).
INSERT INTO pricing_plans (type_id, unit_price, effective_from, effective_to) VALUES
  (1, 0.030000, date_trunc('day', now()) - interval '120 days', date_trunc('day', now()) - interval '20 days'),
  (1, 0.025000, date_trunc('day', now()) - interval '20 days', NULL),
  (2, 0.000200, date_trunc('day', now()) - interval '120 days', NULL),
  (3, 0.010000, date_trunc('day', now()) - interval '120 days', NULL);
