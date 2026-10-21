#!/usr/bin/env bash
# Loads db/seed/*.sql in order. Skips when the database already holds users (use `make clean`
# to start over: the audit trail is append-only, so seed data is never truncated).
set -euo pipefail
PSQL=(psql -U postgres -d crms -v ON_ERROR_STOP=1 -q)
if [ -n "$("${PSQL[@]}" -tAc 'SELECT 1 FROM users LIMIT 1')" ]; then
  echo "database already seeded; run 'make clean && make up && make migrate && make seed' for a fresh start"
  exit 0
fi
for f in "$(dirname "$0")"/[0-9]*.sql; do
  echo "seeding $(basename "$f")"
  "${PSQL[@]}" -f "$f"
done
"${PSQL[@]}" -c "ANALYZE" 
echo "seed complete"
