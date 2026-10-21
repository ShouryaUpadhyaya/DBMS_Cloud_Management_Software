#!/usr/bin/env bash
# Quota race demo, run inside the db container (make demo-race).
#   run_race.sh            narrated demo
#   run_race.sh --assert   same scenario, exits non-zero unless the unsafe version over-allocates
#                          and the safe version does not (used by `make test-race`)
set -uo pipefail
ASSERT=0; [ "${1:-}" = "--assert" ] && ASSERT=1
DEMO_DIR="$(dirname "$0")"
PSQL=(psql -U postgres -d crms -v ON_ERROR_STOP=1 -qtA)
fail=0

setup() {  # fresh project with a compute quota of exactly 1 and one network
  "${PSQL[@]}" <<'SQL'
DO $$
DECLARE v_p integer;
BEGIN
  SELECT project_id INTO v_p FROM projects WHERE name = 'Race Demo';
  IF v_p IS NOT NULL THEN
    DELETE FROM resources WHERE project_id = v_p AND type_id = 1;
    DELETE FROM resources WHERE project_id = v_p;
    DELETE FROM quotas WHERE project_id = v_p;
    DELETE FROM projects WHERE project_id = v_p;
  END IF;
  INSERT INTO projects (name, owner_id) VALUES ('Race Demo', (SELECT user_id FROM users WHERE email = 'admin@crms.test'))
    RETURNING project_id INTO v_p;
  INSERT INTO quotas VALUES (v_p, 1, 1), (v_p, 2, 10), (v_p, 3, 1);
  PERFORM sp_create_network(v_p, 'race-net', '10.77.0.0/24');
END $$;
SQL
  PID="$("${PSQL[@]}" -c "SELECT project_id FROM projects WHERE name = 'Race Demo'")"
  NID="$("${PSQL[@]}" -c "SELECT resource_id FROM resources WHERE project_id = $PID AND type_id = 3")"
  UID_="$("${PSQL[@]}" -c "SELECT user_id FROM users WHERE email = 'admin@crms.test'")"
}

live_vms() {
  "${PSQL[@]}" -c "SELECT count(*) FROM resources WHERE project_id = $PID AND type_id = 1 AND state <> 'terminated'"
}

run_mode() {
  local mode="$1"
  setup
  echo "---- mode: $mode  (compute quota = 1, VMs in use = $(live_vms)) ----"
  local outA outB
  outA="$(mktemp)"; outB="$(mktemp)"
  psql -q -U postgres -d crms -v mode="$mode" -v pid="$PID" -v nid="$NID" -v uid="$UID_" -f "$DEMO_DIR/race_condition_a.sql" >"$outA" 2>&1 &
  local pa=$!
  psql -q -U postgres -d crms -v mode="$mode" -v pid="$PID" -v nid="$NID" -v uid="$UID_" -f "$DEMO_DIR/race_condition_b.sql" >"$outB" 2>&1 &
  local pb=$!
  wait $pa $pb
  cat "$outA" "$outB" | grep -v -E '^$|^(BEGIN|COMMIT|ROLLBACK)$|^Output format|^Tuples only' | sed 's/^psql:[^ ]* //'
  LAST_COUNT="$(live_vms)"; LAST_B="$(cat "$outB")"
  echo "VMs now in use: $LAST_COUNT (quota: 1)"
  rm -f "$outA" "$outB"
}

echo "== 1. UNSAFE: no lock between the quota check and the insert =="
run_mode unsafe
if [ "$LAST_COUNT" -gt 1 ]; then
  echo "RESULT: over-allocated ($LAST_COUNT VMs for a quota of 1) -- the race condition is real."
else
  echo "UNEXPECTED: unsafe version did not over-allocate"; fail=1
fi
echo
echo "== 2. SAFE: quota row locked with SELECT ... FOR UPDATE =="
run_mode safe
if [ "$LAST_COUNT" -eq 1 ] && echo "$LAST_B" | grep -q 'Quota exceeded: 1 of 1 VMs used'; then
  echo "RESULT: exactly one VM; the second session waited, then was refused with 'Quota exceeded'."
else
  echo "UNEXPECTED: safe version allowed $LAST_COUNT VMs"; fail=1
fi

# leave nothing behind
"${PSQL[@]}" -c "DELETE FROM resources WHERE project_id = $PID AND type_id = 1; DELETE FROM resources WHERE project_id = $PID; DELETE FROM quotas WHERE project_id = $PID; DELETE FROM projects WHERE project_id = $PID;" >/dev/null
[ $ASSERT -eq 1 ] && exit $fail
exit 0
