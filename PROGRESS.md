# Progress

## Blocked
(none)

## Log
- Phases 1-4 done: migrations 001-012, seed (1.05M metric rows), 8 SQL test files + 10 named query checks, race + notify tests, explain demo. `make reset` wipes/migrates/seeds; `make test` runs all DB tests.
- Notes for next iterations: crms_app logs in via sp_login (no direct users read); API must `SET LOCAL crms.user_id`; role gate for DB Lab queries = admin only; mock collector must emit the same external_ids as the seed (`mock-<name>`), node hostname `crms-local`, project names in payload.
