# Tasks

## 1 Scaffold
- [x] Repo skeleton, compose (db, api, web, collector), Makefile, .env.example, migrate runner
## 2 Schema migrations
- [ ] 002 identity + access tables
- [ ] 003 organisation + inventory tables (supertype/subtypes)
- [ ] 004 pricing, allocations, billing tables
- [ ] 005 partitioned usage_metrics + log_entries, observability tables
- [ ] 006 indexes
## 3 Constraints, triggers, procedures, views
- [ ] 007 triggers (audit, immutable audit, touch, state machine, allocation close, IP in CIDR, payment status)
- [ ] 008 functions (permissions, IP, cost, partitions)
- [ ] 009 provisioning procedures (safe/unsafe VM, volume, network, terminate)
- [ ] 010 billing, ingest, rollup procedures + metric alert trigger
- [ ] 011 views, materialized view, pg_cron jobs
- [ ] 012 RLS + grants
## 4 Seed, tests, demos
- [ ] seed script (users, roles, projects, pricing, resources, 30 days metrics, logs)
- [ ] SQL test runner + tests for constraints/triggers/functions/billing/RLS/grants
- [ ] race test (shell, concurrent sessions) + demo-race
- [ ] db/queries named showcase queries + explain_before_after demo
## 5 Collector
- [ ] mock mode
- [ ] docker mode + Dockerfile
## 6 API
- [ ] scaffold, db helper (request tx, retry), auth
- [ ] registry (views, procedures, queries), routes, SSE
- [ ] API tests (vitest + supertest)
## 7 Web UI
- [ ] scaffold, auth, layout, dark mode, generic components
- [ ] Dashboard, Resources, Resource detail, Launch wizard
- [ ] Monitoring, Logs, Alerts, Billing, Access, Audit, DB Lab
## 8 Docs
- [ ] README, ER diagram, normalization, viva notes, VPS_DEPLOY + compose.vps
## 9 Final verification
- [ ] clean-clone verification, .done
