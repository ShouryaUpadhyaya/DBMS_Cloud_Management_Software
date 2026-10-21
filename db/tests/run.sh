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
[ $fail -eq 0 ] && echo "all SQL tests passed"
exit $fail
