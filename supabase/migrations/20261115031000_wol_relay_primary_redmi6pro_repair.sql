-- Restore the intended Redmi 6 Pro v1.0.4 Android WoL relay as the primary gateway.
-- This is isolated to the dedicated Android WoL relay backend; Android DB routing is untouched.
DO $migration$
DECLARE
  v_org_id uuid;
  v_relay_id constant uuid := '5d6b5a0d-3465-4f86-bb10-18b52ea71691';
BEGIN
  SELECT org_id
    INTO v_org_id
    FROM public.wol_relay_devices
   WHERE id = v_relay_id
     AND revoked_at IS NULL
     AND lower(btrim(model)) = 'redmi 6 pro'
     AND app_version = '1.0.4'
     AND status = 'online'
     AND last_seen_at > now() - interval '90 seconds'
   FOR UPDATE;

  IF v_org_id IS NULL THEN
    RAISE EXCEPTION 'EXPECTED_REDDMI6PRO_RELAY_V104_NOT_ONLINE';
  END IF;

  -- Clear the old primary first to respect the one-primary-per-organization index.
  UPDATE public.wol_relay_devices
     SET is_primary = false,
         updated_at = now()
   WHERE org_id = v_org_id
     AND is_primary = true;

  UPDATE public.wol_relay_devices
     SET is_primary = true,
         updated_at = now()
   WHERE id = v_relay_id
     AND org_id = v_org_id
     AND revoked_at IS NULL;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'REDDI6PRO_PRIMARY_UPDATE_FAILED';
  END IF;
END
$migration$;
