-- title: Log volume and errors per hour (last 24h)
-- concept: aggregate FILTER clauses compute several conditional counts in one pass
SELECT date_trunc('hour', ts) AS hour,
       count(*) AS lines,
       count(*) FILTER (WHERE level = 'error') AS errors,
       count(*) FILTER (WHERE level = 'warn')  AS warnings,
       round(100.0 * count(*) FILTER (WHERE level = 'error') / count(*), 1) AS error_pct
  FROM log_entries
 WHERE ts > now() - interval '24 hours'
 GROUP BY 1
 ORDER BY 1;
