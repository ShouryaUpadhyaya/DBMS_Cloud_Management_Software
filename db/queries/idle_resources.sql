-- title: Idle resources (7-day average CPU below 5%)
-- concept: GROUP BY ... HAVING on an aggregate over a time window; uses the (resource_id, metric, ts) index
SELECT r.resource_id, r.name, p.name AS project,
       round(avg(um.value)::numeric, 2) AS avg_cpu_percent,
       count(*) AS samples
  FROM usage_metrics um
  JOIN resources r USING (resource_id)
  JOIN projects p USING (project_id)
 WHERE um.metric = 'cpu_percent'
   AND um.ts > now() - interval '7 days'
   AND r.state = 'running'
 GROUP BY r.resource_id, r.name, p.name
HAVING avg(um.value) < 5
 ORDER BY avg_cpu_percent;
