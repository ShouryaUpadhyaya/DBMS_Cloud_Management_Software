# Decisions

- Ports: db 127.0.0.1:55432, api 4000, web 8088 (host ports 5432/5433/3001 were taken). Overridable in .env.
- `sp_*` are plpgsql FUNCTIONS (not CREATE PROCEDURE) so the API can `SELECT * FROM sp_x(...)` and get results; SECURITY DEFINER with pinned search_path.
- The "SAVEPOINT per project" in sp_generate_invoices is a plpgsql BEGIN..EXCEPTION block (an implicit subtransaction/savepoint).
- `make down` keeps the volume; `make clean` removes it (`make down -v` would be parsed by make as its own -v flag).
- Migration runner is db/migrate.sh with a schema_migrations table; role passwords arrive as psql variables.
- users gets a `password_hash` column (spec requires crypt() passwords but lists no column).
- Subtype disjointness: subtype tables carry a constant type_id with a composite FK to resources(resource_id, type_id); totality via deferred constraint trigger.
- Collector docker mode uses docker-compose.docker-mode.yml (socket proxy mounted read-only in the proxy only); default compose has no docker.sock mount.
- Views use security_invoker so RLS on base tables applies to the calling user.
- Usage older than retention is rolled up to usage_rollup_daily before partitions are dropped.
