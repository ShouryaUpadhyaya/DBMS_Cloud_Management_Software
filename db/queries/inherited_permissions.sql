-- title: Inherited permissions per role
-- concept: recursive CTE walking roles.parent_role_id upward; depth shows how far the permission is inherited
WITH RECURSIVE chain(role_id, name, via_role_id, via_name, depth) AS (
  SELECT role_id, name, role_id, name, 0 FROM roles
  UNION ALL
  SELECT c.role_id, c.name, r.role_id, r.name, c.depth + 1
    FROM chain c
    JOIN roles child ON child.role_id = c.via_role_id
    JOIN roles r ON r.role_id = child.parent_role_id
)
SELECT c.name AS role, p.action, p.resource_type, c.via_name AS granted_by, c.depth
  FROM chain c
  JOIN role_permissions rp ON rp.role_id = c.via_role_id
  JOIN permissions p USING (perm_id)
 ORDER BY c.name, c.depth, p.action, p.resource_type;
