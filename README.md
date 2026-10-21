# CRMS: Cloud Resource Management System

A DBMS course project. **PostgreSQL is the core**: business rules live in the database as constraints, triggers,
stored procedures, views and row-level security. The Node API and React UI are thin shells over it.
CRMS tracks cloud resources (VMs, volumes, networks), their usage, quotas, billing, alerts and access, and it can
monitor **real Docker containers** on a host. It also runs entirely on a laptop with a **mock collector**.

```
 browser ──► web (nginx + React) ──► api (Express, raw SQL) ──► PostgreSQL 16
                                            ▲ LISTEN alerts          ▲  sp_ingest_metrics / sp_ingest_logs
                                            └─ SSE to browser        │
                                                       collector (mock | docker via read-only socket proxy)
```

| Layer | Tech |
|---|---|
| Database | PostgreSQL 16 · btree_gist, pg_cron, pg_stat_statements, pgcrypto |
| API | Node 20, Express, TypeScript, `pg` (no ORM), Zod, JWT |
| Web | React, Vite, TypeScript, TanStack Query, Recharts, Tailwind |
| Collector | Node + TypeScript, `COLLECTOR_MODE=mock\|docker` |
| Packaging | One Docker Compose project, `crms` |

## Quick start

Requirements: Docker with Compose v2, `make`. (Node 20+ only if you run the API/web tests from the host.)

```bash
cp .env.example .env        # development defaults; optional
make up                     # build + start db, api, web, collector (mock mode)
make migrate                # apply db/migrations/001…012
make seed                   # 4 projects, 6 users, 13 resources, 30 days of metrics (1M+ rows), invoices
make test                   # database test suite (constraints, triggers, procedures, RLS, races)
```

Open **http://127.0.0.1:8088**. Seeded users all use the password `password123`:

| User | Role | Sees |
|---|---|---|
| `admin@crms.test` | admin | everything, DB Lab, billing admin |
| `alice@crms.test` | manager | Web Platform + Staging |
| `bob@crms.test` | developer (Web Platform), viewer (Data Lab) | |
| `carol@crms.test` | viewer | Web Platform, read-only |
| `dave@crms.test` | manager | Data Lab |

Start over: `make reset` (wipes the database volume, migrates, seeds). Stop: `make down` (keeps data) or
`make clean` (deletes the volume).

### Make targets

| Target | Does |
|---|---|
| `make up` / `down` / `clean` | start (build) / stop / stop and delete data |
| `make migrate` / `seed` / `reset` | schema, demo data, both from scratch |
| `make test` | SQL tests (`db/tests/t_*.sql`), named-query checks, concurrency test, NOTIFY test |
| `make test-api` | vitest + supertest against the real database |
| `make test-web` | web unit tests are `npm test` in `web/`; this target runs the production build (typecheck + bundle) |
| `make test-all` | all of the above |
| `make demo-race` | two concurrent sessions: unsafe vs locked provisioning |
| `make demo-explain` | before/after plans for every index on ≥1M rows |
| `make demo-alert` | fire a live CPU alert (watch the UI toast) |
| `make lint` | typecheck api, web, collector |
| `make psql` | open psql as superuser |

Ports (loopback only, change in `.env`): web `8088`, api `4000`, db `55432`.

## Demo script

1. `make reset && make test`: everything green from a clean database.
2. `make demo-race`: the unsafe procedure over-allocates the quota, the locked one refuses (`Quota exceeded: 1 of 1 VMs used`).
3. `make demo-explain`: seq scan 42 ms → index scan 0.2 ms, BRIN, GIN, partition pruning.
4. UI as **carol** (RLS: only her project), **alice** (launch a VM → quota error), **dave** (launch, terminate, then
   read the **Audit log** JSON diff), **admin** (**DB Lab**: run a query and open its *Plan* tab).
5. `make demo-alert` with the **Alerts** page open: trigger → `pg_notify` → SSE → toast.

The full question-by-question walkthrough is in [`docs/viva-notes.md`](docs/viva-notes.md).

## Screens

Login · Dashboard · Resources · Resource detail · Launch wizard · Monitoring · Logs explorer · Alerts · Billing ·
Access · Audit log (JSON diff) · DB Lab (SQL, result table and `EXPLAIN (ANALYZE, FORMAT JSON)` per query).
Generic building blocks: `DataTable`, `ProcedureForm`, `MetricChart`, `SqlCard`, `JsonDiff`. Dark mode, dense layout.

## Collector

Every 30 s (`COLLECTOR_INTERVAL_SECONDS`) it calls `sp_ingest_metrics` and `sp_ingest_logs` as `crms_collector`,
a role that can execute nothing else.

- **mock** (default): 8 containers, 2 volumes, 2 networks with daily CPU curves, memory drift, occasional spikes,
  sustained "incidents" that trip alert rules, and info/warn/error log lines. Names match the seed, so live data
  continues the seeded history.
- **docker**: reads the Docker Engine API through `DOCKER_HOST=tcp://docker-proxy:2375`, a read-only
  `docker-socket-proxy` (`CONTAINERS=1 NETWORKS=1 VOLUMES=1 INFO=1 POST=0`). `docker.sock` is **never** mounted into the
  collector or any container of the default compose file.

  ```bash
  docker compose -f docker-compose.yml -f docker-compose.docker-mode.yml up -d --build
  ```

  Containers appear in the *Unassigned* project unless labelled `crms.project=<name>`. Verified against a real Docker
  host (containers, networks, volumes, CPU/memory from `stats`, demultiplexed logs).

## DBMS concept → where to look

| Concept | File |
|---|---|
| Normal forms, deliberate denormalization | [`docs/normalization.md`](docs/normalization.md) |
| ER diagram (Mermaid) | [`docs/er-diagram.md`](docs/er-diagram.md) |
| Constraints: PK, FK, UNIQUE, CHECK | `db/migrations/002–005`, tested in `db/tests/t_constraints.sql` |
| Temporal integrity: `EXCLUDE USING gist` + range types | `004_pricing_billing.sql` (pricing, allocations, cycles) |
| Supertype/subtype, disjoint + total | `003_…` (composite FK), `007_triggers.sql` (`fn_resource_total`) |
| Weak entity, frozen price | `invoice_line_items` in `004_…`; `t_billing.sql` |
| Ternary relationship, role hierarchy | `project_members`, `roles.parent_role_id` |
| Declarative partitioning, retention, rollup | `005_…`, `008_…` (`fn_ensure_partitions`), `010_…` (`sp_rollup_and_retention`) |
| Indexes: btree, partial, BRIN, GIN (jsonb + full-text) | `006_indexes.sql`, `db/demo/explain_before_after.sql` |
| Triggers: audit (generic), immutable log, `updated_at`, state machine, allocation close, alerts | `007_triggers.sql`, `t_triggers.sql` |
| Stored procedures, quotas, savepoints | `009_provisioning.sql`, `010_billing_ingest.sql` |
| Concurrency: race condition vs `SELECT … FOR UPDATE` | `sp_provision_vm` / `sp_provision_vm_unsafe`, `db/demo/race_condition_a.sql`, `_b.sql`, `run_race.sh` |
| Recursive CTEs, window functions, percentiles, FILTER, anti-joins | `db/queries/*.sql` (shown in DB Lab) |
| Views, `security_invoker`, materialized view + `REFRESH CONCURRENTLY` | `011_views_jobs.sql` |
| `pg_cron` scheduling | `011_views_jobs.sql` (hourly refresh), nightly retention |
| LISTEN / NOTIFY → SSE | `fn_metric_alert` in `007_…`, `api/src/stream.ts`, `db/tests/notify_test.sh` |
| Row-level security, roles, least privilege, `SECURITY DEFINER` | `012_rls_grants.sql`, `t_security.sql` |
| pgcrypto password hashing | `sp_login` in `009_…`, seed `00/01_…` |
| `pg_stat_statements` | `v_stat_statements`, DB Lab |
| SQLSTATE → HTTP, serialization retry | `api/src/errors.ts`, `api/src/db.ts` |

## Repository layout

```
db/migrations/      001…012 numbered SQL, applied in order by db/migrate.sh
db/seed/            00 reference data · 01 users/projects · 02 inventory · 03 metrics+logs · 04 billing
db/tests/           t_*.sql (rolled back), run.sh, race_test.sh, notify_test.sh
db/demo/            race_condition_a/b.sql, run_race.sh, explain_before_after.sql, fire_alert.sql
db/queries/         ten named showcase queries
api/                Express API (registry.ts maps names → SQL + roles), vitest tests
web/                React app
collector/          mock + docker collectors, unit tests
deploy/             docker-compose.vps.yml, bootstrap.sql, VPS_DEPLOY.md (instructions only)
docs/               er-diagram.md, normalization.md, viva-notes.md
```

## How it is built (short)

- **Migrations** are plain SQL, tracked in `schema_migrations`, each in one transaction.
  `make clean && make up && make migrate && make seed && make test` works from a clean checkout.
- **Authorization** is in the database. The API logs in with `sp_login`, then wraps every request in
  `BEGIN; SELECT set_config('crms.user_id', $id, true); …; COMMIT`. RLS filters rows; procedures call
  `fn_assert_permission`; the API's registry only adds a coarse role gate.
- **Error mapping**: `P0001` (RAISE) → 400 with the message untouched; `23505/23514/23P01` → 409 with a field error;
  `42501` → 403; `40001`/`40P01` retried up to 3×.
- **DB Lab** runs the named queries as `crms_readonly` in a `READ ONLY` transaction (admin users only) and returns
  the SQL text, rows and `EXPLAIN (ANALYZE, FORMAT JSON)`.

More: design decisions in [`DECISIONS.md`](DECISIONS.md), production deployment in
[`deploy/VPS_DEPLOY.md`](deploy/VPS_DEPLOY.md).

## Troubleshooting

| Problem | Fix |
|---|---|
| `make seed` says "already seeded" | expected on re-run; use `make reset` for a fresh database |
| Port in use | set `DB_PORT`, `API_PORT`, `WEB_PORT` in `.env`, then `make down && make up` |
| Login fails right after `make up` | run `make migrate seed` first (users are created by the seed) |
| Empty charts | the seed ends at the moment it ran; `make reset` refreshes it, and the collector keeps it live |
| API/Web tests can't connect | `make up` first; API tests use `127.0.0.1:55432` (`ADMIN_DATABASE_URL` overrides the cleanup connection) |
