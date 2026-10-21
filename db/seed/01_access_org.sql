-- Seed 1: roles, permissions, users, projects, quotas, pricing.

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

-- Password for every seeded user: password123 (stored only as a bcrypt hash).
INSERT INTO users (email, name, status, password_hash) VALUES
  ('admin@crms.test', 'Ada Admin',   'active',    crypt('password123', gen_salt('bf'))),
  ('alice@crms.test', 'Alice Rivera', 'active',   crypt('password123', gen_salt('bf'))),
  ('bob@crms.test',   'Bob Chen',     'active',   crypt('password123', gen_salt('bf'))),
  ('carol@crms.test', 'Carol Okafor', 'active',   crypt('password123', gen_salt('bf'))),
  ('dave@crms.test',  'Dave Novak',   'active',   crypt('password123', gen_salt('bf'))),
  ('erin@crms.test',  'Erin Walsh',   'suspended', crypt('password123', gen_salt('bf')));

-- Everything below is attributed to the admin in the audit trail.
SELECT set_config('crms.user_id', (SELECT user_id::text FROM users WHERE email = 'admin@crms.test'), false);

INSERT INTO projects (name, owner_id, parent_project_id)
SELECT 'Unassigned', user_id, NULL FROM users WHERE email = 'admin@crms.test';
INSERT INTO projects (name, owner_id, parent_project_id)
SELECT 'Web Platform', user_id, NULL FROM users WHERE email = 'alice@crms.test';
INSERT INTO projects (name, owner_id, parent_project_id)
SELECT 'Web Platform Staging', u.user_id, p.project_id FROM users u, projects p
 WHERE u.email = 'alice@crms.test' AND p.name = 'Web Platform';
INSERT INTO projects (name, owner_id, parent_project_id)
SELECT 'Data Lab', user_id, NULL FROM users WHERE email = 'dave@crms.test';

INSERT INTO project_members (project_id, user_id, role_id)
SELECT p.project_id, u.user_id, r.role_id
  FROM (VALUES ('Unassigned','admin@crms.test','admin'),
               ('Web Platform','alice@crms.test','manager'),
               ('Web Platform','bob@crms.test','developer'),
               ('Web Platform','carol@crms.test','viewer'),
               ('Web Platform Staging','alice@crms.test','manager'),
               ('Web Platform Staging','bob@crms.test','developer'),
               ('Data Lab','dave@crms.test','manager'),
               ('Data Lab','bob@crms.test','viewer'),
               ('Data Lab','erin@crms.test','developer')) AS m(project, email, role)
  JOIN projects p ON p.name = m.project
  JOIN users u ON u.email = m.email
  JOIN roles r ON r.name = m.role;

INSERT INTO quotas (project_id, resource_type_id, max_units)
SELECT p.project_id, rt.type_id, q.max_units
  FROM (VALUES ('Unassigned','compute',20), ('Unassigned','storage',2000), ('Unassigned','network',10),
               ('Web Platform','compute',6), ('Web Platform','storage',500), ('Web Platform','network',3),
               ('Web Platform Staging','compute',2), ('Web Platform Staging','storage',100), ('Web Platform Staging','network',1),
               ('Data Lab','compute',4), ('Data Lab','storage',1000), ('Data Lab','network',2)) AS q(project, type, max_units)
  JOIN projects p ON p.name = q.project
  JOIN resource_types rt ON rt.name = q.type;

-- Pricing history (non-overlapping per type, enforced by the EXCLUDE constraint).
INSERT INTO pricing_plans (type_id, unit_price, effective_from, effective_to) VALUES
  (1, 0.030000, date_trunc('day', now()) - interval '120 days', date_trunc('day', now()) - interval '20 days'),
  (1, 0.025000, date_trunc('day', now()) - interval '20 days', NULL),
  (2, 0.000200, date_trunc('day', now()) - interval '120 days', NULL),
  (3, 0.010000, date_trunc('day', now()) - interval '120 days', NULL);
