#!/usr/bin/env bash
# Runs every db/tests/t_*.sql inside one rolled-back transaction each. Needs the seeded database.
set -uo pipefail
DIR="$(dirname "$0")"
fail=0
for f in "$DIR"/t_*.sql; do
  name="$(basename "$f")"
  out="$( { echo 'BEGIN;'; cat "$DIR/_helpers.sql" "$f"; echo 'ROLLBACK;'; } \
          | psql -U postgres -d crms -v ON_ERROR_STOP=1 -q 2>&1 )"
  if [ $? -eq 0 ]; then
    echo "PASS $name"
  else
    echo "FAIL $name"; echo "$out" | sed 's/^/    /'; fail=1
  fi
done
# Every named showcase query must run (as the read-only role, admin context) and return rows.
for f in "$DIR"/../queries/*.sql; do
  name="$(basename "$f" .sql)"
  out="$( { echo "BEGIN READ ONLY; SET LOCAL ROLE crms_readonly;"
            echo "SELECT set_config('crms.user_id', (SELECT user_id::text FROM users WHERE email = 'admin@crms.test'), true);"
            cat "$f"; echo "ROLLBACK;"; } | psql -U postgres -d crms -v ON_ERROR_STOP=1 -tA 2>&1 )"
  rows="$(echo "$out" | grep -c '|')"
  if [ $? -ne 0 ] || echo "$out" | grep -q 'ERROR' || [ "$rows" -lt 1 ]; then
    echo "FAIL query:$name"; echo "$out" | head -5 | sed 's/^/    /'; fail=1
  else
    echo "PASS query:$name ($rows rows)"
  fi
done
[ $fail -eq 0 ] && echo "all SQL tests passed"
exit $fail
