#!/usr/bin/env bash
# trg_metric_alert must pg_notify('alerts', json) on fire and on resolve. NOTIFY is only delivered
# at commit to other sessions, so this needs a real listener session (cannot run in a rolled-back test).
set -uo pipefail
PSQL=(psql -U postgres -d crms -v ON_ERROR_STOP=1 -qtA)
out="$(mktemp)"
# Listener: LISTEN, wait, then a trivial query so psql prints pending notifications.
( { echo "LISTEN alerts;"; echo "SELECT pg_sleep(4);"; echo "SELECT 1;"; } | psql -U postgres -d crms -qtA >"$out" 2>&1 ) &
lp=$!
sleep 1
RID="$("${PSQL[@]}" -c "SELECT resource_id FROM resources WHERE name = 'worker-1'")"
"${PSQL[@]}" <<SQL
INSERT INTO usage_metrics VALUES ($RID, now() + interval '20 days', 'cpu_percent', 99);       -- fires (rule: avg > 85)
INSERT INTO usage_metrics VALUES ($RID, now() + interval '20 days' + interval '10 minutes', 'cpu_percent', 1);  -- resolves
SQL
wait $lp
status=0
grep -q '"type" : "fired"' "$out" || { echo "FAIL notify: no 'fired' notification"; status=1; }
grep -q '"type" : "resolved"' "$out" || { echo "FAIL notify: no 'resolved' notification"; status=1; }
# clean up the rows this test committed
"${PSQL[@]}" <<SQL
DELETE FROM alert_events WHERE resource_id = $RID AND fired_at > now() + interval '19 days';
DELETE FROM usage_metrics WHERE resource_id = $RID AND ts > now() + interval '19 days';
SQL
[ $status -eq 0 ] && echo "PASS notify (alerts channel delivered fired + resolved)"
rm -f "$out"
exit $status
