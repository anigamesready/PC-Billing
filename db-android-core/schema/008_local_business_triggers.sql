-- Local equivalents for the DB1 business triggers that are not tied to DB1/DB2 routing.
-- Deliberately excludes capture_db_sync_before_image, write-quiesce, Telegram outbox and
-- shutdown-scheduler triggers. Rental identity normalization/audit is retained.
BEGIN;

CREATE OR REPLACE FUNCTION private.audit_normalize_rental_identity_update_local()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','private'
AS $function$
DECLARE
  v_actor uuid;
BEGIN
  BEGIN
    v_actor := NULLIF(current_setting('ani.admin_actor_id', true), '')::uuid;
  EXCEPTION WHEN invalid_text_representation THEN
    v_actor := NULL;
  END;

  -- Preserve DB1 behavior: normalize only when the rental code itself changes.
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    NEW.code := upper(trim(coalesce(NEW.code,'')));
    IF NEW.code='' THEN RAISE EXCEPTION 'RENTAL_CODE_REQUIRED'; END IF;
  END IF;

  IF NEW.code IS DISTINCT FROM OLD.code OR NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.updated_at := now();
    IF v_actor IS NOT NULL THEN
      INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
      VALUES(NEW.org_id,v_actor,'rental_identity_updated','rental_account',NEW.id::text,
        jsonb_build_object(
          'old_code',OLD.code,'new_code',NEW.code,
          'old_status',OLD.status,'new_status',NEW.status,
          'source','rental_accounts-code-status-trigger-local'
        ));
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS rental_accounts_audit_identity_update ON public.rental_accounts;
CREATE TRIGGER rental_accounts_audit_identity_update
BEFORE UPDATE OF code,status ON public.rental_accounts
FOR EACH ROW EXECUTE FUNCTION private.audit_normalize_rental_identity_update_local();

REVOKE EXECUTE ON FUNCTION private.audit_normalize_rental_identity_update_local() FROM PUBLIC,ani_api_runtime;

COMMIT;
