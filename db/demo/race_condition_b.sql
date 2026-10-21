-- Session B of the quota race demo: starts 1 s after A, while A is still inside its critical section.
\set ON_ERROR_STOP off
\pset format unaligned
\pset tuples_only on
SELECT set_config('crms.user_id', :'uid', false) \gset
SELECT pg_sleep(1);
\echo [B] provisioning in mode :mode
BEGIN;
SELECT CASE WHEN :'mode' = 'unsafe'
            THEN sp_provision_vm_unsafe(:pid, 'race-b', 1, 512, :nid, 3)
            ELSE sp_provision_vm(:pid, 'race-b', 1, 512, :nid)
       END AS vm_id \gset
\if :{?vm_id}
\echo [B] got VM :vm_id
\else
\echo [B] refused (see error above)
\endif
COMMIT;
\echo [B] transaction finished
