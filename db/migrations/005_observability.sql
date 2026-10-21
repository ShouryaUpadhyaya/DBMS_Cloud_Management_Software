-- 005: usage metrics, logs, alerts, audit.
-- Concepts: declarative range partitioning, jsonb, windowed alert state, append-only audit.

-- Monthly partitions; the PK must include the partition key (ts).
CREATE TABLE usage_metrics (
  resource_id integer NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
  ts          timestamptz NOT NULL,
  metric      text NOT NULL CHECK (metric IN ('cpu_percent', 'mem_percent', 'net_kbps', 'disk_percent')),
  value       double precision NOT NULL CHECK (value >= 0),
  PRIMARY KEY (resource_id, metric, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE usage_rollup_daily (
  resource_id integer NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
  day         date NOT NULL,
  metric      text NOT NULL,
  avg_value   double precision NOT NULL,
  max_value   double precision NOT NULL,
  min_value   double precision NOT NULL,
  samples     integer NOT NULL,
  PRIMARY KEY (resource_id, day, metric)
);

CREATE TABLE log_entries (
  log_id      bigint GENERATED ALWAYS AS IDENTITY,
  resource_id integer NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
  ts          timestamptz NOT NULL,
  level       text NOT NULL CHECK (level IN ('debug', 'info', 'warn', 'error')),
  message     text NOT NULL,
  attrs       jsonb NOT NULL DEFAULT '{}'::jsonb,
  PRIMARY KEY (log_id, ts)
) PARTITION BY RANGE (ts);

CREATE TABLE alert_rules (
  rule_id        integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  project_id     integer NOT NULL REFERENCES projects(project_id) ON DELETE CASCADE,
  metric         text NOT NULL CHECK (metric IN ('cpu_percent', 'mem_percent', 'net_kbps', 'disk_percent')),
  operator       text NOT NULL CHECK (operator IN ('>', '>=', '<', '<=')),
  threshold      double precision NOT NULL,
  window_seconds integer NOT NULL CHECK (window_seconds > 0)
);

CREATE TABLE alert_events (
  event_id    integer GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  rule_id     integer NOT NULL REFERENCES alert_rules(rule_id) ON DELETE CASCADE,
  resource_id integer NOT NULL REFERENCES resources(resource_id) ON DELETE CASCADE,
  fired_at    timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  peak_value  double precision NOT NULL,
  CHECK (resolved_at IS NULL OR resolved_at >= fired_at)
);
-- At most one open event per (rule, resource).
CREATE UNIQUE INDEX alert_events_open_uq ON alert_events (rule_id, resource_id) WHERE resolved_at IS NULL;

CREATE TABLE audit_log (
  audit_id   bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
  actor_id   integer,                                  -- no FK: audit must outlive users
  table_name text NOT NULL,
  op         text NOT NULL CHECK (op IN ('INSERT', 'UPDATE', 'DELETE')),
  row_pk     text NOT NULL,
  old_data   jsonb,
  new_data   jsonb,
  at         timestamptz NOT NULL DEFAULT now()
);
