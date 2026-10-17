-- Applied on DB1 as admin_update_rental_identity_rpc_v1.
-- The live narrow rental_accounts(code,status) UPDATE column grant remains temporarily
-- for backward compatibility with already-installed Admin APK v12.1.8 and earlier.
-- After users install v12.1.9+ and its API path has been verified, revoke that column grant.
CREATE OR REPLACE FUNCTION api.admin_update_rental_identity(p_org_id uuid, p_device_id uuid, p_rental_id uuid, p_code text, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  uid uuid := auth.uid();
  r public.rental_accounts%ROWTYPE;
  normalized_code text := upper(trim(coalesce(p_code, '')));
  normalized_status text := coalesce(p_status, '');
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED';
  END IF;

  IF p_org_id IS NULL OR p_device_id IS NULL OR p_rental_id IS NULL THEN
    RAISE EXCEPTION 'RENTAL_IDENTITY_FIELDS_REQUIRED';
  END IF;

  IF NOT private.is_owner_access(p_org_id) THEN
    RAISE EXCEPTION 'OWNER_ONLY';
  END IF;

  IF normalized_code = '' OR length(normalized_code) > 120 THEN
    RAISE EXCEPTION 'RENTAL_CODE_INVALID';
  END IF;

  IF normalized_status NOT IN ('active', 'expired', 'disabled') THEN
    RAISE EXCEPTION 'RENTAL_STATUS_INVALID';
  END IF;

  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id = p_rental_id
    AND org_id = p_org_id
    AND device_id = p_device_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RENTAL_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.rental_accounts other
    WHERE other.org_id = p_org_id
      AND other.code = normalized_code
      AND other.id <> p_rental_id
  ) THEN
    RAISE EXCEPTION 'CODE_ALREADY_EXISTS';
  END IF;

  UPDATE public.rental_accounts
  SET code = normalized_code,
      status = normalized_status,
      updated_at = now()
  WHERE id = p_rental_id
    AND org_id = p_org_id
    AND device_id = p_device_id;

  RETURN jsonb_build_object(
    'ok', true,
    'id', p_rental_id,
    'org_id', p_org_id,
    'device_id', p_device_id,
    'code', normalized_code,
    'status', normalized_status,
    'updated_at', now()
  );
END
$function$;

REVOKE ALL PRIVILEGES ON FUNCTION api.admin_update_rental_identity(uuid,uuid,uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_identity(uuid,uuid,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_identity(uuid,uuid,uuid,text,text) TO service_role;

-- Rollback-wrapped SQL test verified: valid owner update normalizes code, updates status,
-- writes exactly one audit row, duplicate code rejected, no test rows remain.
