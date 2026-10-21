-- title: Month-to-date cost rolled up the project tree
-- concept: recursive CTE building an ancestor/descendant closure, then aggregating per ancestor
WITH RECURSIVE closure(ancestor_id, project_id, depth) AS (
  SELECT project_id, project_id, 0 FROM projects
  UNION ALL
  SELECT c.ancestor_id, p.project_id, c.depth + 1
    FROM closure c JOIN projects p ON p.parent_project_id = c.project_id
)
SELECT a.name AS project,
       count(*) - 1 AS sub_projects,
       max(c.depth) AS tree_depth,
       sum(v.cost_mtd) AS subtree_cost_mtd
  FROM closure c
  JOIN projects a ON a.project_id = c.ancestor_id
  JOIN v_project_cost_mtd v ON v.project_id = c.project_id
 GROUP BY a.name
 ORDER BY subtree_cost_mtd DESC, project;
