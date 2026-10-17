-- Applied live to DB1 as owner_access_null_denial_fix_v1.
-- private.user_role() correctly returns NULL when the caller has no owner membership.
-- But PL/pgSQL IF NOT(NULL) does not enter the guarded branch, so SECURITY DEFINER RPCs
-- using IF NOT private.is_owner_access(...) could accidentally continue for a non-owner.
-- Normalize this helper to a strict non-null boolean: no owner membership => false.

CREATE OR REPLACE FUNCTION private.is_owner_access(target_org uuid)
RETURNS boolean
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT COALESCE(private.user_role(target_org) = 'owner', false)
$function$;

-- Rollback-wrapped negative tests with a synthetic non-owner identity verified rejection
-- across 7 existing RPCs: create_enrollment, admin_recent_alerts, queue_command,
-- admin_delete_rental, add_account_time, create_rental_account,
-- and create_rental_account_on_device.
