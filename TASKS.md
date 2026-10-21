# Tasks

## 1 Scaffold
- [x] Repo skeleton, compose (db, api, web, collector), Makefile, .env.example, migrate runner
## 2 Schema migrations
- [x] 002 identity + access tables
- [x] 003 organisation + inventory tables (supertype/subtypes)
- [x] 004 pricing, allocations, billing tables
- [x] 005 partitioned usage_metrics + log_entries, observability tables
- [x] 006 indexes
## 3 Constraints, triggers, procedures, views
- [x] 007 triggers (audit, immutable audit, touch, state machine, allocation close, IP in CIDR, payment status)
- [x] 008 functions (permissions, IP, cost, partitions)
- [x] 009 provisioning procedures (safe/unsafe VM, volume, network, terminate)
- [x] 010 billing, ingest, rollup procedures + metric alert trigger
- [x] 011 views, materialized view, pg_cron jobs
- [x] 012 RLS + grants
## 4 Seed, tests, demos
- [x] seed script (users, roles, projects, pricing, resources, 30 days metrics, logs)
- [x] SQL test runner + tests for constraints/triggers/functions/billing/RLS/grants
- [x] race test (shell, concurrent sessions) + demo-race
- [x] db/queries named showcase queries + explain_before_after demo
## 5 Collector
- [x] mock mode
- [x] docker mode + Dockerfile
## 6 API
- [x] scaffold, db helper (request tx, retry), auth
- [x] registry (views, procedures, queries), routes, SSE
- [x] API tests (vitest + supertest)
## 7 Web UI
- [x] scaffold, auth, layout, dark mode, generic components
- [x] Dashboard, Resources, Resource detail, Launch wizard
- [x] Monitoring, Logs, Alerts, Billing, Access, Audit, DB Lab
## 8 Docs
- [ ] README, ER diagram, normalization, viva notes, VPS_DEPLOY + compose.vps
## 9 Final verification
- [ ] clean-clone verification, .done
