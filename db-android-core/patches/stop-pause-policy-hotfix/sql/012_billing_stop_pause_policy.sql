-- Ani Games Ready DB Android: Owner-controlled PAUSE / STOP access for PC Billing.
-- Additive and safe for an existing DB Android database. Does not touch rental rows,
-- active sessions, device tokens, pairing, WOL, or the separate relay service.
BEGIN;

INSERT INTO private.admin_feature_settings(feature_key, enabled)
VALUES ('billing_stop_pause_enabled', false)
ON CONFLICT (feature_key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.is_billing_stop_pause_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'pg_catalog'
AS $function$
  SELECT COALESCE((
    SELECT s.enabled
    FROM private.admin_feature_settings AS s
    WHERE s.feature_key = 'billing_stop_pause_enabled'
    LIMIT 1
  ), false);
$function$;

REVOKE ALL ON FUNCTION private.is_billing_stop_pause_enabled() FROM PUBLIC;

CREATE OR REPLACE FUNCTION api.admin_get_billing_stop_pause_policy()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_catalog'
AS $function$
DECLARE
  setting_row private.admin_feature_settings%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.org_members m
    WHERE m.auth_user_id = auth.uid() AND m.role = 'owner'
  ) THEN
    RAISE EXCEPTION 'OWNER_ONLY';
  END IF;

  SELECT * INTO setting_row
  FROM private.admin_feature_settings
  WHERE feature_key = 'billing_stop_pause_enabled';

  RETURN jsonb_build_object(
    'enabled', COALESCE(setting_row.enabled, false),
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_set_billing_stop_pause_policy(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_catalog'
AS $function$
DECLARE
  setting_row private.admin_feature_settings%ROWTYPE;
  audit_org_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'INVALID_BILLING_CONTROL_SETTING'; END IF;

  SELECT m.org_id INTO audit_org_id
  FROM public.org_members m
  WHERE m.auth_user_id = auth.uid() AND m.role = 'owner'
  ORDER BY m.org_id
  LIMIT 1;
  IF audit_org_id IS NULL THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;

  INSERT INTO private.admin_feature_settings(feature_key, enabled, updated_at, updated_by)
  VALUES ('billing_stop_pause_enabled', p_enabled, now(), auth.uid())
  ON CONFLICT (feature_key) DO UPDATE
    SET enabled = EXCLUDED.enabled,
        updated_at = now(),
        updated_by = auth.uid()
  RETURNING * INTO setting_row;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (
    audit_org_id,
    auth.uid(),
    'billing_stop_pause_policy_changed',
    'feature',
    'billing_stop_pause_enabled',
    jsonb_build_object('enabled', setting_row.enabled, 'updated_at', setting_row.updated_at)
  );

  RETURN jsonb_build_object(
    'enabled', setting_row.enabled,
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
END;
$function$;

-- Token-bound Admin RPC wrappers. The local API runtime never receives auth.uid()
-- directly; the existing Admin session-token validator sets the actor per transaction.
CREATE OR REPLACE FUNCTION api.admin_get_billing_stop_pause_policy(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_get_billing_stop_pause_policy();
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_set_billing_stop_pause_policy(p_session_token text, p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_set_billing_stop_pause_policy(p_enabled);
END;
$function$;

-- Device endpoint used by PC Billing only when the renter clicks PAUSE / STOP.
-- The setting is read on demand, so there is no periodic policy polling.
CREATE OR REPLACE FUNCTION api.device_session_control_policy(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_catalog'
AS $function$
DECLARE
  token_device_id uuid;
  is_enabled boolean;
BEGIN
  IF COALESCE(btrim(p_token), '') = '' THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  SELECT t.device_id INTO token_device_id
  FROM public.device_tokens t
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;

  IF token_device_id IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  is_enabled := private.is_billing_stop_pause_enabled();
  RETURN jsonb_build_object(
    'ok', true,
    'enabled', is_enabled,
    'allow_stop_pause', is_enabled,
    'message', CASE
      WHEN is_enabled THEN 'BILLING_STOP_PAUSE_ALLOWED'
      ELSE 'BILLING_STOP_PAUSE_LOCKED'
    END
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.admin_get_billing_stop_pause_policy() FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_set_billing_stop_pause_policy(boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_get_billing_stop_pause_policy(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_set_billing_stop_pause_policy(text, boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.device_session_control_policy(text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.admin_get_billing_stop_pause_policy(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_set_billing_stop_pause_policy(text, boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_session_control_policy(text) TO ani_api_runtime;

COMMIT;
