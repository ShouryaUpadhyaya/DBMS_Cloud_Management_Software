# Viva notes

Short, honest answers with the file to open. Everything below is real code in this repository.

## 1. The one-minute pitch

CRMS is a Cloud Resource Management System. PostgreSQL holds the rules: constraints, triggers, stored procedures,
views, row-level security. The Node API and React UI are thin shells: the API maps names to SQL and never
re-implements a rule. It monitors real Docker containers (docker mode) and runs fully on a laptop with a simulated
collector (mock mode).

**Why database-first?** A rule in the database holds for *every* client: the API, a psql session, a migration, a
future mobile app. A rule in the API holds only while every writer goes through the API. Example: the quota rule
lives in `sp_provision_vm`, so even a hand-written `psql` call cannot exceed it.

## 2. Likely questions

### Design and normalization
- **Why is `invoice_line_items.unit_price` stored when it can be looked up?** An invoice is a historical document;
  prices change. It is a deliberate, tested denormalization → `docs/normalization.md`, `db/tests/t_billing.sql`.
- **How did you model inheritance (compute/storage/network)?** Supertype `resources` + subtype tables. Disjoint via
  composite FK `(resource_id, type_id)`; total via a deferred constraint trigger → `003_organisation_inventory.sql`,
  `007_triggers.sql` (`fn_resource_total`).
- **What is a weak entity here?** `invoice_line_items`: identified by `(invoice_id, line_no)`, deleted with its
  invoice (`ON DELETE CASCADE`).
- **Ternary relationship?** `project_members(project_id, user_id, role_id)`.
- **How do you stop two prices applying at once?** `EXCLUDE USING gist (type_id WITH =, tstzrange(...) WITH &&)`
  → `004_pricing_billing.sql`. Same idea for allocations and billing cycles.

### Transactions, concurrency, locking
- **Show me a race condition.** `make demo-race`. Two sessions call `sp_provision_vm_unsafe` for a project whose
  quota is 1: both read "0 used", both insert, 2 VMs exist. With `sp_provision_vm` the quota row is locked by
  `SELECT … FOR UPDATE`; the second session waits, then sees 1 used and gets `Quota exceeded: 1 of 1 VMs used`
  → `009_provisioning.sql`, `db/demo/run_race.sh`, `db/tests/race_test.sh`.
- **Which isolation level and why does that not save you?** Default READ COMMITTED: each statement sees only
  committed data, so two concurrent check-then-insert sequences both pass. Fixes: lock the parent row (what we do),
  SERIALIZABLE with retry, or a constraint. A lock is cheapest here because the contention is per project.
- **What if the lock causes a deadlock?** Every procedure takes locks in the same order (quota row, then the network
  row), so cycles cannot form. The API additionally retries `40001` and `40P01` up to 3 times (`api/src/db.ts`,
  unit-tested in `api/test/errors.test.ts`).
- **SAVEPOINT in `sp_generate_invoices`?** A plpgsql `BEGIN … EXCEPTION` block is an implicit savepoint: one
  project's failure rolls back only that project's invoice and lines, is logged to `billing_failures`, and the loop
  continues → `010_billing_ingest.sql`; proven in `t_billing.sql`.
- **ACID, concretely?** Atomicity: provisioning inserts resource + subtype + address + allocation or nothing.
  Consistency: constraints/triggers. Isolation: MVCC + row locks. Durability: WAL (Postgres default).
- **What is MVCC?** Readers never block writers: an UPDATE writes a new row version; old versions are visible to
  older snapshots and cleaned up by VACUUM. That is why dashboards can read while the collector inserts.

### Triggers, procedures, security
- **Triggers vs constraints?** Use a constraint whenever it can express the rule (`CHECK`, `UNIQUE`, `EXCLUDE`, FK).
  Triggers are for rules that need other tables or side effects: state machine, IP-in-CIDR, audit, alerts.
- **One generic audit function for five tables?** `fn_audit()` uses `to_jsonb(OLD/NEW)` and takes the key columns
  as trigger arguments; the actor comes from `current_setting('crms.user_id', true)`. The log is append-only:
  `trg_audit_immutable` rejects UPDATE/DELETE/TRUNCATE, even for the owner.
- **How does the database know who the user is?** The API runs each request as
  `BEGIN; SELECT set_config('crms.user_id', $1, true); …; COMMIT`. The setting is transaction-local, so a pooled
  connection cannot leak identity between requests.
- **Explain RLS here.** Policies on `resources`, `invoices`, `usage_metrics`, `log_entries` (and the child tables)
  say: visible if the user is a member of the row's project, or an admin. Views use `security_invoker`, so the
  caller's policies apply through the view. The `SECURITY DEFINER` procedures run as the owner and bypass RLS, which is
  why each starts with `fn_assert_permission` → `012_rls_grants.sql`, `t_security.sql`.
- **Why `SECURITY DEFINER` and what are the risks?** It lets `crms_app` change data only through vetted code, with
  no table write grants. Risk: privilege escalation through `search_path` tricks, so every definer function pins
  `SET search_path = public, pg_temp`.
- **How are roles separated?** `crms_app` (EXECUTE procedures, SELECT views), `crms_collector` (only `sp_ingest_*`),
  `crms_readonly` (SELECT; used for the DB Lab). `t_security.sql` tries every forbidden action and expects `42501`.
- **A bug you found by testing?** The totality constraint trigger fires at COMMIT, after the definer procedure
  returned, with the *collector's* privileges, so it failed with "permission denied". Fixed by making it
  `SECURITY DEFINER`; found by running docker mode against a real Docker, now covered in `t_security.sql`.
- **How is the password stored?** `crypt(password, gen_salt('bf'))` (bcrypt via pgcrypto), verified in `sp_login`
  inside the database; the API never sees a hash.

### Indexing and performance
- **Which indexes and why?** `make demo-explain` prints before/after plans on 1M+ rows:
  btree `(resource_id, metric, ts DESC)` for one resource's series (seq scan 42 ms → 0.2 ms);
  BRIN on `ts` (tiny, works because data arrives in time order); partial index on live resources;
  GIN on `attrs` for `@>`; GIN on `to_tsvector(message)` for full-text.
- **Why partition `usage_metrics`?** Time-range queries touch one or two monthly partitions (partition pruning
  is shown in the demo), and retention is `DROP TABLE` of a partition: instant, no bloat, unlike `DELETE`. The
  primary key must include the partition key `ts`.
- **What does the materialized view buy you?** `mv_daily_usage` pre-aggregates ~1M rows. `REFRESH … CONCURRENTLY`
  (needs the unique index) rebuilds it hourly via `pg_cron` without blocking readers.
- **What does retention do?** `sp_rollup_and_retention(days)` first writes daily aggregates into
  `usage_rollup_daily`, then drops raw partitions wholly older than the cutoff, and pre-creates next month's.

### SQL techniques (DB Lab; each is a file in `db/queries/`)
| Query | Technique |
|---|---|
| `top3_costliest_projects` | `RANK() OVER` |
| `mom_cost_change` | `LAG() OVER (PARTITION BY … ORDER BY …)` |
| `idle_resources` | `GROUP BY … HAVING avg(...) < 5` |
| `mem_percentiles` | `percentile_cont(...) WITHIN GROUP` |
| `inherited_permissions` | recursive CTE over the role hierarchy |
| `project_tree_cost` | recursive CTE closure + aggregation |
| `missed_heartbeats` | anti-join with `NOT EXISTS` + `LATERAL` |
| `cpu_anomalies` | window `avg/stddev_samp`, 3-sigma filter |
| `errors_per_hour` | aggregate `FILTER (WHERE …)` |
| `projects_without_invoice` | `LEFT JOIN … IS NULL` |

### Architecture
- **Why raw SQL and no ORM?** The point of the project is the SQL. The registry (`api/src/registry.ts`) maps a name to
  a statement and a minimum role; Zod validates inputs; every value is a bind parameter (the test suite includes an
  injection attempt).
- **How do alerts reach the browser?** `trg_metric_alert` → `pg_notify('alerts', json)` → the API `LISTEN`s and
  forwards over Server-Sent Events, filtered to projects the user can see.
- **Why does docker mode not mount `docker.sock`?** The socket is root-equivalent. The collector talks to a
  `docker-socket-proxy` allowing only `GET` on containers, networks, volumes and info (`POST=0`), and the socket
  is mounted read-only into the proxy alone (`docker-compose.docker-mode.yml`, `deploy/docker-compose.vps.yml`).

## 3. Suggested demo (10 minutes)

1. `make reset && make test`: clean database, every constraint/trigger/procedure/RLS test, race test (≈1 min).
2. `make demo-race`: the over-allocation, then the fix.
3. `make demo-explain`: index before/after.
4. Open the UI (`http://127.0.0.1:8088`):
   - sign in as **carol** (viewer): only Web Platform rows (RLS); Launch is not in the menu;
   - sign in as **alice** (manager): Launch a VM → `Quota exceeded: 6 of 6 VMs used`;
   - sign in as **dave** (Data Lab manager): launch a VM, watch it appear, terminate it, check the **Audit log** diff;
   - sign in as **admin**: **DB Lab** → run `cpu_anomalies`, open the *Plan* tab; **Billing** → generate invoices for a cycle
     that is already invoiced to see per-project savepoint isolation (`failed` rows, nothing half-written).
5. `make demo-alert` while on **Dashboard/Alerts**: the toast appears live (trigger → NOTIFY → SSE).
6. `psql`: `UPDATE audit_log SET op='x';` → rejected; `SELECT * FROM users;` as `crms_app` → password hash hidden.
