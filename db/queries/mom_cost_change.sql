-- title: Month-over-month cost change
-- concept: LAG() over a per-project window ordered by billing period
SELECT p.name AS project,
       lower(c.period)::date AS month_start,
       i.total,
       lag(i.total) OVER w AS previous_total,
       round((i.total - lag(i.total) OVER w) / nullif(lag(i.total) OVER w, 0) * 100, 1) AS pct_change
  FROM invoices i
  JOIN projects p USING (project_id)
  JOIN billing_cycles c USING (cycle_id)
WINDOW w AS (PARTITION BY i.project_id ORDER BY lower(c.period))
 ORDER BY p.name, month_start;
