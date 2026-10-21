-- First-run data for a real deployment (instead of the demo seed): role hierarchy, permission
-- catalogue, pricing plans, one administrator and the default "Unassigned" project that
-- discovered containers land in. Run once after the migrations:
--   docker compose -f deploy/docker-compose.vps.yml exec -T db psql -U postgres -d crms \
--     -v ON_ERROR_STOP=1 -v admin_email=you@example.com -v admin_password='a long passphrase' \
--     -f /deploy/bootstrap.sql
\i /db/seed/00_reference.sql

INSERT INTO users (email, name, status, password_hash)
VALUES (lower(:'admin_email'), 'Administrator', 'active', crypt(:'admin_password', gen_salt('bf')));

INSERT INTO projects (name, owner_id) SELECT 'Unassigned', user_id FROM users WHERE email = lower(:'admin_email');

INSERT INTO project_members (project_id, user_id, role_id)
SELECT p.project_id, u.user_id, r.role_id
  FROM projects p, users u, roles r
 WHERE p.name = 'Unassigned' AND u.email = lower(:'admin_email') AND r.name = 'admin';

INSERT INTO quotas (project_id, resource_type_id, max_units)
SELECT p.project_id, rt.type_id, 1000 FROM projects p, resource_types rt WHERE p.name = 'Unassigned';
