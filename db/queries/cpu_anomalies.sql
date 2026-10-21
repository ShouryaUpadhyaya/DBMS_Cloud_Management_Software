-- title: CPU anomalies (3 sigma above the trailing hour)
-- concept: window avg()/stddev_samp() over ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING, then a z-score filter
WITH scored AS (
  SELECT resource_id, ts, value,
         avg(value)         OVER w AS mean_60,
         stddev_samp(value) OVER w AS sigma_60
    FROM usage_metrics
   WHERE metric = 'cpu_percent' AND ts > now() - interval '3 days'
  WINDOW w AS (PARTITION BY resource_id ORDER BY ts ROWS BETWEEN 60 PRECEDING AND 1 PRECEDING)
)
SELECT r.name, s.ts,
       round(s.value::numeric, 1) AS cpu,
       round(s.mean_60::numeric, 1) AS trailing_mean,
       round(s.sigma_60::numeric, 2) AS trailing_sigma,
       round(((s.value - s.mean_60) / s.sigma_60)::numeric, 1) AS z_score
  FROM scored s
  JOIN resources r USING (resource_id)
 WHERE s.sigma_60 > 0 AND s.value - s.mean_60 > 3 * s.sigma_60
 ORDER BY s.ts DESC
 LIMIT 50;
