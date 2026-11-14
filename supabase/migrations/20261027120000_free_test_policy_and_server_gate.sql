-- AniGames Ready V12.3.0: server-authoritative FREE TEST 10-minute policy.
-- Additive only. Does not edit rental data, PC pairing/token rows, route flags, or DB cutover settings.
-- Apply to DB1 and DB2; setting defaults OFF on a DB where no policy row exists.

CREATE TABLE IF NOT EXISTS private.admin_feature_settings (
  feature_key text PRIMARY KEY CHECK (feature_key IN ('free_test_10m_enabled')),
  enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);

ALTER TABLE private.admin_feature_settings ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE private.admin_feature_settings FROM PUBLIC, anon, authenticated, service_role;

INSERT INTO private.admin_feature_settings(feature_key, enabled)
VALUES ('free_test_10m_enabled', false)
ON CONFLICT (feature_key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.is_free_test_10m_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path = private, pg_catalog
AS $policy$
  SELECT COALESCE((
    SELECT s.enabled
    FROM admin_feature_settings AS s
    WHERE s.feature_key = 'free_test_10m_enabled'
    LIMIT 1
  ), false);
$policy$;

REVOKE ALL ON FUNCTION private.is_free_test_10m_enabled() FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION private.is_free_test_10m_enabled() TO service_role;

-- Block every server-side entry point that creates a trial request, even if a legacy client skips preflight.
CREATE OR REPLACE FUNCTION private.guard_free_test_10m_trial_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_catalog
AS $guard_trial$
BEGIN
  IF NOT private.is_free_test_10m_enabled() THEN
    RAISE EXCEPTION 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
  END IF;
  RETURN NEW;
END;
$guard_trial$;

REVOKE ALL ON FUNCTION private.guard_free_test_10m_trial_request() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS guard_free_test_10m_trial_request ON public.device_trial_requests;
CREATE TRIGGER guard_free_test_10m_trial_request
BEFORE INSERT ON public.device_trial_requests
FOR EACH ROW EXECUTE FUNCTION private.guard_free_test_10m_trial_request();

-- Defense-in-depth: disallow a disabled PC/app from opening or re-opening the test rental session.
-- Existing active test sessions are allowed to update/finish after the owner turns the gate OFF.
CREATE OR REPLACE FUNCTION private.guard_free_test_10m_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_catalog
AS $guard_session$
BEGIN
  IF NEW.code = '__TEST10__' AND NEW.status IN ('active', 'paused') THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT private.is_free_test_10m_enabled() THEN
        RAISE EXCEPTION 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
      END IF;
    ELSE
      IF (OLD.code IS DISTINCT FROM '__TEST10__' OR OLD.status NOT IN ('active', 'paused'))
         AND NOT private.is_free_test_10m_enabled() THEN
        RAISE EXCEPTION 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$guard_session$;

REVOKE ALL ON FUNCTION private.guard_free_test_10m_session() FROM PUBLIC, anon, authenticated, service_role;
DROP TRIGGER IF EXISTS guard_free_test_10m_session ON public.rental_sessions;
CREATE TRIGGER guard_free_test_10m_session
BEFORE INSERT OR UPDATE OF code, status ON public.rental_sessions
FOR EACH ROW EXECUTE FUNCTION private.guard_free_test_10m_session();

-- Main Admin UI authenticates through api.admin_context(), which defines Owner by org_members.role='owner'.
CREATE OR REPLACE FUNCTION api.admin_get_free_test_policy()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_catalog
AS $get_policy$
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
  WHERE feature_key = 'free_test_10m_enabled';

  RETURN jsonb_build_object(
    'enabled', COALESCE(setting_row.enabled, false),
    'contact_phone', '082298316902',
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
END;
$get_policy$;

CREATE OR REPLACE FUNCTION api.admin_set_free_test_policy(p_enabled boolean)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_catalog
AS $set_policy$
DECLARE
  setting_row private.admin_feature_settings%ROWTYPE;
  audit_org_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF p_enabled IS NULL THEN RAISE EXCEPTION 'INVALID_FREE_TEST_SETTING'; END IF;

  SELECT m.org_id INTO audit_org_id
  FROM public.org_members m
  WHERE m.auth_user_id = auth.uid() AND m.role = 'owner'
  ORDER BY m.org_id
  LIMIT 1;
  IF audit_org_id IS NULL THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;

  INSERT INTO private.admin_feature_settings(feature_key, enabled, updated_at, updated_by)
  VALUES ('free_test_10m_enabled', p_enabled, now(), auth.uid())
  ON CONFLICT (feature_key) DO UPDATE
    SET enabled = EXCLUDED.enabled,
        updated_at = now(),
        updated_by = auth.uid()
  RETURNING * INTO setting_row;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (
    audit_org_id, auth.uid(), 'free_test_policy_changed', 'feature', 'free_test_10m_enabled',
    jsonb_build_object('enabled', setting_row.enabled, 'updated_at', setting_row.updated_at)
  );

  RETURN jsonb_build_object(
    'enabled', setting_row.enabled,
    'contact_phone', '082298316902',
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
END;
$set_policy$;

CREATE OR REPLACE FUNCTION api.device_free_test_policy(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, private, pg_catalog
AS $device_policy$
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

  is_enabled := private.is_free_test_10m_enabled();
  RETURN jsonb_build_object(
    'ok', true,
    'enabled', is_enabled,
    'contact_phone', '082298316902',
    'message', CASE
      WHEN is_enabled THEN 'FREE_TEST_ALLOWED'
      ELSE 'Silahkan hubungi admin untuk melakukan tes 082298316902'
    END
  );
END;
$device_policy$;

REVOKE ALL ON FUNCTION api.admin_get_free_test_policy() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION api.admin_set_free_test_policy(boolean) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION api.device_free_test_policy(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.admin_get_free_test_policy() TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.admin_set_free_test_policy(boolean) TO authenticated, service_role;
GRANT EXECUTE ON FUNCTION api.device_free_test_policy(text) TO anon, authenticated, service_role;
