-- Index effect on >= 1M seeded usage_metrics rows (run with `make demo-explain`).
-- "Before" = an unindexed temp copy of the table; "after" = the same copy once the index from
-- 006_indexes.sql is created on it. Compare the plan node and "Execution Time" in each pair.
\timing off
\pset pager off
SELECT count(*) AS usage_metrics_rows FROM usage_metrics;

CREATE TEMP TABLE um_plain AS SELECT * FROM usage_metrics;
CREATE TEMP TABLE logs_plain AS SELECT * FROM log_entries;
ANALYZE um_plain;
ANALYZE logs_plain;
SELECT resource_id AS rid FROM resources WHERE name = 'web-1' \gset

\echo
\echo '=== 1. Latest day of one metric for one resource: BEFORE (no index) ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT avg(value) FROM um_plain
 WHERE resource_id = :rid AND metric = 'cpu_percent' AND ts > now() - interval '1 day';

CREATE INDEX um_plain_res_metric_ts ON um_plain (resource_id, metric, ts DESC);
ANALYZE um_plain;
\echo '=== 1. AFTER: btree (resource_id, metric, ts DESC) ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT avg(value) FROM um_plain
 WHERE resource_id = :rid AND metric = 'cpu_percent' AND ts > now() - interval '1 day';

\echo
\echo '=== 2. Narrow time range across all resources: BEFORE ==='
DROP INDEX um_plain_res_metric_ts;
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM um_plain WHERE ts BETWEEN now() - interval '2 hours' AND now() - interval '1 hour';
-- BRIN stores one min/max summary per block range, so it is tiny and works because rows are
-- appended in time order (the copy inherits that order partition by partition).
CREATE INDEX um_plain_ts_brin ON um_plain USING brin (ts);
ANALYZE um_plain;
\echo '=== 2. AFTER: BRIN on ts (tiny index, skips whole block ranges) ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM um_plain WHERE ts BETWEEN now() - interval '2 hours' AND now() - interval '1 hour';
CREATE INDEX um_plain_btree_ts ON um_plain (ts);
SELECT pg_size_pretty(pg_relation_size('um_plain_ts_brin'))  AS brin_size,
       pg_size_pretty(pg_relation_size('um_plain_btree_ts')) AS btree_size_for_comparison;

\echo
\echo '=== 3. JSONB containment on log attrs: BEFORE ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM logs_plain WHERE attrs @> '{"status": 500, "container": "api-1"}';
CREATE INDEX logs_plain_attrs ON logs_plain USING gin (attrs);
ANALYZE logs_plain;
\echo '=== 3. AFTER: GIN on attrs ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM logs_plain WHERE attrs @> '{"status": 500, "container": "api-1"}';

\echo
\echo '=== 4. Full-text search on message: BEFORE ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM logs_plain WHERE to_tsvector('english', message) @@ plainto_tsquery('english', 'redis');
CREATE INDEX logs_plain_fts ON logs_plain USING gin (to_tsvector('english', message));
ANALYZE logs_plain;
\echo '=== 4. AFTER: GIN full-text index ==='
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY ON)
SELECT count(*) FROM logs_plain WHERE to_tsvector('english', message) @@ plainto_tsquery('english', 'redis');

\echo
\echo '=== 5. Partition pruning on the real table: only the partitions overlapping the range are scanned ==='
SELECT date_trunc('month', now())::text AS m_start \gset
EXPLAIN (COSTS OFF)
SELECT count(*) FROM usage_metrics WHERE ts >= :'m_start'::timestamptz AND ts < :'m_start'::timestamptz + interval '1 month';

\echo
\echo '=== 6. Partial index: live resources of a project (terminated rows are not indexed) ==='
SET enable_seqscan = off;   -- the table is tiny, so force the planner to show the index it would use at scale
EXPLAIN (ANALYZE, COSTS OFF, SUMMARY OFF)
SELECT name FROM resources WHERE project_id = (SELECT project_id FROM projects WHERE name = 'Web Platform') AND state <> 'terminated';
