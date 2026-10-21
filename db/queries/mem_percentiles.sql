-- title: Memory percentiles per resource (7 days)
-- concept: ordered-set aggregate percentile_cont(...) WITHIN GROUP (ORDER BY ...)
SELECT r.name,
       round((percentile_cont(0.50) WITHIN GROUP (ORDER BY um.value))::numeric, 1) AS p50,
       round((percentile_cont(0.95) WITHIN GROUP (ORDER BY um.value))::numeric, 1) AS p95,
       round((percentile_cont(0.99) WITHIN GROUP (ORDER BY um.value))::numeric, 1) AS p99
  FROM usage_metrics um
  JOIN resources r USING (resource_id)
 WHERE um.metric = 'mem_percent' AND um.ts > now() - interval '7 days'
 GROUP BY r.name
 ORDER BY p95 DESC;
