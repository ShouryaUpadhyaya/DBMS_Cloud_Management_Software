-- Seed 3: 30 days of per-minute metrics (>1M rows) and ~25k log lines.
-- Triggers (alerting, FK checks) are skipped for the bulk load: replica mode needs superuser
-- and is reset right after. History for alerts is inserted explicitly below.
SET session_replication_role = replica;

-- cpu/mem/net per minute for every compute instance (8 containers), disk every 5 minutes.
-- Shape: daily sine wave + noise + rare spikes; per-container base levels; cache-1 stopped
-- one day ago so it has no recent data; notebook-1 is deliberately idle.
INSERT INTO usage_metrics (resource_id, ts, metric, value)
SELECT r.resource_id, t.ts, m.metric,
       greatest(0, least(100,
         CASE m.metric
           WHEN 'cpu_percent' THEN b.cpu_base + b.cpu_amp * sin((extract(epoch FROM t.ts) / 86400.0) * 2 * pi() - 1.2)
                                   + (random() - 0.5) * 6
                                   + CASE WHEN random() < 0.0015 THEN 35 + random() * 40 ELSE 0 END
           WHEN 'mem_percent' THEN b.mem_base + 6 * sin((extract(epoch FROM t.ts) / 86400.0) * 2 * pi())
                                   + (random() - 0.5) * 2 + (extract(epoch FROM t.ts - now()) / 86400.0) * 0.15
         END))::double precision
  FROM resources r
  JOIN compute_instances ci ON ci.resource_id = r.resource_id
  JOIN (VALUES ('web-1', 28, 18, 45), ('web-2', 26, 17, 44), ('api-1', 35, 22, 55), ('worker-1', 20, 15, 38),
               ('cache-1', 8, 4, 30), ('staging-web-1', 10, 6, 35), ('etl-1', 40, 35, 60),
               ('notebook-1', 2, 1.5, 25)) AS b(name, cpu_base, cpu_amp, mem_base) ON b.name = r.name
  CROSS JOIN (VALUES ('cpu_percent'), ('mem_percent')) AS m(metric)
  CROSS JOIN LATERAL generate_series(date_trunc('minute', now()) - interval '30 days',
        date_trunc('minute', now()) - CASE WHEN r.name = 'cache-1' THEN interval '1 day' ELSE interval '0' END,
        interval '1 minute') AS t(ts);

INSERT INTO usage_metrics (resource_id, ts, metric, value)
SELECT r.resource_id, t.ts, 'net_kbps',
       greatest(0, (CASE r.name WHEN 'notebook-1' THEN 5 WHEN 'etl-1' THEN 900 ELSE 400 END)
                   * (1 + 0.6 * sin((extract(epoch FROM t.ts) / 86400.0) * 2 * pi() - 1.0))
                   * (0.7 + random() * 0.6)
                   * CASE WHEN random() < 0.001 THEN 4 ELSE 1 END)::double precision
  FROM resources r
  JOIN compute_instances ci ON ci.resource_id = r.resource_id
  CROSS JOIN LATERAL generate_series(date_trunc('minute', now()) - interval '30 days',
        date_trunc('minute', now()) - CASE WHEN r.name = 'cache-1' THEN interval '1 day' ELSE interval '0' END,
        interval '1 minute') AS t(ts)
 WHERE r.name <> 'bastion';

INSERT INTO usage_metrics (resource_id, ts, metric, value)
SELECT r.resource_id, t.ts, 'disk_percent',
       least(100, (CASE r.name WHEN 'datasets' THEN 60 ELSE 35 END)
                  + extract(epoch FROM t.ts - (now() - interval '30 days')) / 86400.0 * 0.4
                  + (random() - 0.5))::double precision
  FROM resources r
  JOIN storage_volumes sv ON sv.resource_id = r.resource_id
  CROSS JOIN LATERAL generate_series(date_trunc('minute', now()) - interval '30 days',
        date_trunc('minute', now()), interval '5 minutes') AS t(ts);

-- Logs: random lines per container, mostly info, some warn, few error (more on api-1).
INSERT INTO log_entries (resource_id, ts, level, message, attrs)
SELECT r.resource_id, l.ts, l.level, l.message,
       jsonb_build_object('container', r.name, 'request_id', md5(random()::text),
                          'latency_ms', (random() * 900)::int, 'status', l.status)
  FROM resources r
  JOIN compute_instances ci ON ci.resource_id = r.resource_id AND r.name <> 'bastion'
  CROSS JOIN LATERAL (
    SELECT now() - (random() * interval '30 days') AS ts,
           CASE WHEN x.p < 0.80 THEN 'info' WHEN x.p < 0.95 THEN 'warn' ELSE 'error' END AS level,
           x.p,
           CASE WHEN x.p < 0.80 THEN 200 WHEN x.p < 0.95 THEN 429 ELSE 500 END AS status,
           CASE WHEN x.p < 0.40 THEN 'GET /api/items 200 served'
                WHEN x.p < 0.60 THEN 'POST /api/orders created order'
                WHEN x.p < 0.80 THEN 'health check ok'
                WHEN x.p < 0.88 THEN 'slow query took over 1000 ms'
                WHEN x.p < 0.95 THEN 'rate limit reached for client'
                WHEN x.p < 0.97 THEN 'connection refused to redis:6379'
                WHEN x.p < 0.99 THEN 'upstream timed out while reading response'
                ELSE 'unhandled exception in request handler' END AS message
      FROM (SELECT random() AS p, g FROM generate_series(1, 3000) AS g) x
     WHERE r.name = 'api-1' OR x.g <= 2500
  ) l;

SET session_replication_role = origin;

-- Alert history for the Alerts screen: two resolved incidents and one still open.
INSERT INTO alert_events (rule_id, resource_id, fired_at, resolved_at, peak_value)
SELECT ar.rule_id, r.resource_id, now() - e.fired, now() - e.resolved, e.peak
  FROM (VALUES ('api-1', 'cpu_percent', interval '9 days', interval '9 days' - interval '40 minutes', 93.4),
               ('web-1', 'cpu_percent', interval '4 days', interval '4 days' - interval '25 minutes', 88.7),
               ('api-1', 'mem_percent', interval '3 hours', NULL, 94.1)) AS e(res, metric, fired, resolved, peak)
  JOIN resources r ON r.name = e.res
  JOIN alert_rules ar ON ar.project_id = r.project_id AND ar.metric = e.metric;

-- Pre-aggregate for the materialized view.
REFRESH MATERIALIZED VIEW mv_daily_usage;
