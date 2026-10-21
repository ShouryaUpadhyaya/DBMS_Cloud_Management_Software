# CRMS — Cloud Resource Management System (build spec)

A DBMS course project. PostgreSQL is the core: business rules live in the database
(constraints, triggers, procedures, views, RLS). Node API and React UI are thin shells.
It monitors real Docker containers on a host, but MUST also run fully on a laptop
with a mock collector. Deployment to the real VPS is OUT OF SCOPE (the human does it).

## Stack
- PostgreSQL 16 with extensions: btree_gist, pg_cron, pg_stat_statements, pgcrypto
  (use an image that ships pg_cron, or build a small Dockerfile on postgres:16).
- API: Node 20 + Express + TypeScript, `pg` driver (no ORM; raw SQL by design).
- Web: React + Vite + TypeScript, TanStack Query, Recharts, Tailwind.
- Collector: Node + TypeScript. `COLLECTOR_MODE=mock|docker`.
- Everything in one Docker Compose project named `crms`.

## Repo layout
```
db/migrations/        numbered .sql files, applied in order (001_extensions.sql, ...)
db/seed/              seed data (users, roles, projects, pricing, 30 days of mock metrics)
db/tests/             SQL tests (pgTAP or plain DO-blocks that RAISE on failure)
db/demo/              scripted demos: race_condition_a.sql / _b.sql, explain_before_after.sql
api/                  Express API
web/                  React app
collector/            metrics + logs collector
deploy/               docker-compose.vps.yml + VPS_DEPLOY.md (instructions only, not executed)
docs/                 ER diagram (Mermaid erDiagram), normalization.md, viva-notes.md
docker-compose.yml    local dev stack
Makefile              up, down, migrate, seed, test, demo-race, lint
```

## Schema (~22 tables)
Identity and access
- users(user_id, email UNIQUE, name, status, created_at, updated_at)
- roles(role_id, name UNIQUE, parent_role_id FK roles NULL)   -- hierarchy
- permissions(perm_id, action, resource_type, UNIQUE(action, resource_type))
- role_permissions(role_id, perm_id, PK both)
- project_members(project_id, user_id, role_id, PK(project_id, user_id))  -- ternary
- api_keys(key_id, user_id, key_hash, created_at, revoked_at)          -- pgcrypto hash only

Organisation
- projects(project_id, name, owner_id FK users, parent_project_id FK projects NULL)
- quotas(project_id, resource_type_id, max_units CHECK >= 0, PK both)

Inventory (supertype/subtype, disjoint + total)
- nodes(node_id, hostname UNIQUE, region)
- resource_types(type_id, name UNIQUE, unit)  -- compute, storage, network
- resources(resource_id, project_id FK ON DELETE RESTRICT, type_id, node_id, name,
  external_id UNIQUE NULL (docker id), state CHECK in (pending,running,stopped,terminated),
  source CHECK in (discovered, provisioned), created_at, updated_at)
- compute_instances(resource_id PK/FK, vcpus, memory_mb, image)
- storage_volumes(resource_id PK/FK, size_gb CHECK > 0, mount_path)
- networks(resource_id PK/FK, cidr cidr)
- network_attachments(resource_id, network_id, ip inet, UNIQUE(network_id, ip))

Usage and billing
- pricing_plans(plan_id, type_id, unit_price CHECK >= 0, effective_from, effective_to,
  EXCLUDE USING gist (type_id WITH =, tstzrange(effective_from, effective_to) WITH &&))
- allocations(resource_id, project_id, period tstzrange, EXCLUDE no overlap per resource)
- usage_metrics(resource_id, ts, metric, value)  -- PARTITION BY RANGE (ts), monthly
- billing_cycles(cycle_id, period tstzrange)
- invoices(invoice_id, project_id, cycle_id, total, status, UNIQUE(project_id, cycle_id))
- invoice_line_items(invoice_id FK ON DELETE CASCADE, line_no, resource_id, units,
  unit_price, amount, PK(invoice_id, line_no))   -- weak entity; price frozen on purpose
- payments(payment_id, invoice_id, amount, paid_at)

Observability
- log_entries(log_id, resource_id, ts, level, message, attrs jsonb) -- partitioned monthly
- alert_rules(rule_id, project_id, metric, operator, threshold, window_seconds)
- alert_events(event_id, rule_id, resource_id, fired_at, resolved_at, peak_value)
- audit_log(audit_id, actor_id, table_name, op, row_pk, old_data jsonb, new_data jsonb, at)

## Triggers
- trg_audit (one generic plpgsql fn using to_jsonb(OLD/NEW) and current_setting('crms.user_id', true))
  on resources, quotas, project_members, pricing_plans, invoices.
- trg_audit_immutable: BEFORE UPDATE/DELETE on audit_log → RAISE.
- trg_touch_updated_at on tables with updated_at.
- trg_state_machine: legal transitions only; terminated is final.
- trg_metric_alert: AFTER INSERT on usage_metrics → open/resolve alert_events, and pg_notify('alerts', json).
- trg_allocation_close: on transition to terminated, close open allocation range at now().

## Procedures / functions
- sp_provision_vm(project, name, vcpus, mem_mb, network) — quota row locked with FOR UPDATE,
  inserts resource + subtype + attachment + allocation; RAISE 'Quota exceeded: % of % VMs used'.
- sp_provision_vm_unsafe(...) — same WITHOUT the lock and with optional pg_sleep, for the race demo only.
- sp_create_volume, sp_create_network, sp_terminate_resource.
- fn_next_free_ip(network) — first free host address in the CIDR.
- fn_resource_cost(resource, from, to) — overlap allocations × pricing ranges.
- sp_generate_invoices(cycle) — SAVEPOINT per project, continue on failure, log failures.
- fn_has_permission(user, project, action) — recursive CTE over role hierarchy.
- sp_ingest_metrics(jsonb) and sp_ingest_logs(jsonb) — bulk ingest; upsert discovered resources by external_id.
- sp_rollup_and_retention(days int default 30) — drop raw partitions older than N days after rollup; create next month's partitions.

## Views
- v_active_resources (supertype joined with all subtypes)
- v_project_cost_mtd, v_open_alerts, v_user_effective_permissions
- mv_daily_usage (materialized, unique index, REFRESH CONCURRENTLY hourly via pg_cron)

## Named showcase queries (db/queries/*.sql, also exposed in DB Lab)
top3_costliest_projects (RANK), mom_cost_change (LAG), idle_resources (HAVING avg cpu < 5 over 7d),
mem_percentiles (percentile_cont), inherited_permissions (recursive CTE), project_tree_cost (recursive),
missed_heartbeats (anti-join), cpu_anomalies (window avg/stddev, 3 sigma), errors_per_hour (FILTER),
projects_without_invoice (LEFT JOIN IS NULL).

## Indexes
usage_metrics (resource_id, metric, ts DESC); BRIN on usage_metrics(ts);
partial resources(project_id) WHERE state <> 'terminated'; GIN on log_entries(attrs);
GIN full-text on log_entries(message). db/demo/explain_before_after.sql shows the effect on ≥1M seeded rows.

## Security
- DB roles: crms_app (EXECUTE procedures, SELECT views; no direct writes to billing tables),
  crms_collector (only sp_ingest_*), crms_readonly (SELECT on views + named queries).
- RLS on resources, invoices, usage_metrics, log_entries: rows of projects where current
  crms.user_id is a member; an admin role bypasses.
- API runs every request as: BEGIN; SET LOCAL crms.user_id = $id; ...; COMMIT.

## Collector
- mock mode: simulates 6–10 containers, 2 volumes, 2 networks with realistic CPU/mem/net
  curves, occasional spikes, and log lines (info/warn/error). Default for local dev.
- docker mode: reads Docker Engine API via DOCKER_HOST (meant to point at a read-only
  docker-socket-proxy with CONTAINERS=1 NETWORKS=1 VOLUMES=1). Never mounts docker.sock directly.
- Every 30 s (configurable), calls sp_ingest_metrics / sp_ingest_logs as crms_collector.

## API (Express)
- Registry pattern: api/src/registry.ts maps names → SQL + allowed roles.
- GET /api/views/:name, POST /api/procedures/:name, GET /api/queries/:name (returns SQL text,
  rows, and EXPLAIN (ANALYZE, FORMAT JSON)), GET /api/stream (SSE from LISTEN alerts).
- Simple auth: login with seeded users (email + password hashed with pgcrypto crypt()), JWT.
- SQLSTATE mapping: P0001 → 400 message as-is; 23505/23514/23P01 → 409 field error;
  40001 → retry up to 3 times server-side.
- Zod validation on inputs. Unknown names → 404.

## Web screens
Login, Dashboard, Resources, Resource detail, Launch wizard, Monitoring, Logs explorer,
Alerts, Billing, Access, Audit log (JSON diff), DB Lab (query cards: SQL, result table, plan).
Generic components: DataTable, ProcedureForm, MetricChart, SqlCard, JsonDiff.
Clean, dense admin-console look; dark mode; responsive enough for a projector.

## Quality bar
- `make up && make migrate && make seed && make test` works from a clean clone.
- SQL tests cover: every constraint rejects bad data, every trigger, quota enforcement,
  the race demo (unsafe version over-allocates, safe version does not), invoice math,
  RLS isolation, role grants.
- API tests (vitest + supertest) against the real DB in compose; web builds with no TS errors.
- README.md: what it is, how to run, demo script, DBMS concept → file index.
- deploy/VPS_DEPLOY.md: how the human deploys beside existing services (127.0.0.1 binding or no
  published DB port, crms_ prefixed volumes, memory limits, socket proxy, reverse-proxy block).
