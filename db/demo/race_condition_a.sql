-- Session A of the quota race demo. Variables: mode (unsafe|safe), pid, nid, uid.
-- A starts first and (in safe mode) keeps its transaction open for 3 s so B has to wait on the quota lock.
\set ON_ERROR_STOP off
\pset format unaligned
\pset tuples_only on
SELECT set_config('crms.user_id', :'uid', false) \gset
\echo [A] provisioning in mode :mode
BEGIN;
SELECT CASE WHEN :'mode' = 'unsafe'
            THEN sp_provision_vm_unsafe(:pid, 'race-a', 1, 512, :nid, 3)   -- pauses 3 s between check and insert
            ELSE sp_provision_vm(:pid, 'race-a', 1, 512, :nid)
       END AS vm_id \gset
\if :{?vm_id}
\echo [A] got VM :vm_id (holding the transaction open)
\else
\echo [A] refused (see error above)
\endif
SELECT pg_sleep(CASE WHEN :'mode' = 'safe' THEN 3 ELSE 0 END);
COMMIT;
\echo [A] transaction finished
