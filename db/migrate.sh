#!/usr/bin/env bash
# Applies db/migrations/*.sql in order, once each, tracked in schema_migrations.
# Runs inside the db container (see Makefile) as the postgres superuser.
set -euo pipefail
DIR="${MIGRATIONS_DIR:-/db/migrations}"
PSQL=(psql -U postgres -d crms -v ON_ERROR_STOP=1 -q
  -v app_pw="${CRMS_APP_PASSWORD:-crms_app_dev}"
  -v collector_pw="${CRMS_COLLECTOR_PASSWORD:-crms_collector_dev}"
  -v readonly_pw="${CRMS_READONLY_PASSWORD:-crms_readonly_dev}")

"${PSQL[@]}" -c "CREATE TABLE IF NOT EXISTS schema_migrations (
  filename text PRIMARY KEY, applied_at timestamptz NOT NULL DEFAULT now())"

for f in "$DIR"/*.sql; do
  name="$(basename "$f")"
  done_already="$("${PSQL[@]}" -tAc "SELECT 1 FROM schema_migrations WHERE filename = '$name'")"
  if [ -n "$done_already" ]; then continue; fi
  echo "applying $name"
  "${PSQL[@]}" --single-transaction -f "$f"
  "${PSQL[@]}" -c "INSERT INTO schema_migrations(filename) VALUES ('$name')"
done
echo "migrations up to date"
