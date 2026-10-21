-- 006: indexes. Each one names the query it serves.

-- Latest-N points of one metric for one resource (charts, alert windows). Also used by the
-- window averages in trg_metric_alert. Partition-local indexes are created automatically.
CREATE INDEX usage_metrics_res_metric_ts_idx ON usage_metrics (resource_id, metric, ts DESC);
-- Time-range scans across all resources (rollups, anomaly queries): BRIN is tiny because the
-- table is append-only and physically ordered by ts.
CREATE INDEX usage_metrics_ts_brin ON usage_metrics USING brin (ts);

-- Most queries only care about live resources.
CREATE INDEX resources_live_project_idx ON resources (project_id) WHERE state <> 'terminated';
CREATE INDEX resources_node_idx ON resources (node_id);

-- jsonb containment (attrs @> '{"container":"web"}') and full-text search on message.
CREATE INDEX log_entries_attrs_gin ON log_entries USING gin (attrs);
CREATE INDEX log_entries_message_fts ON log_entries USING gin (to_tsvector('english', message));
CREATE INDEX log_entries_res_ts_idx ON log_entries (resource_id, ts DESC);

-- Foreign keys that are joined often but are not leading PK columns.
CREATE INDEX project_members_user_idx ON project_members (user_id);
CREATE INDEX allocations_project_idx ON allocations (project_id);
CREATE INDEX invoice_items_resource_idx ON invoice_line_items (resource_id);
CREATE INDEX audit_log_table_at_idx ON audit_log (table_name, at DESC);
CREATE INDEX alert_events_resource_idx ON alert_events (resource_id, fired_at DESC);
