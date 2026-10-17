-- DB1 live-hardening SQL snapshot, captured 2026-10-18.
-- These objects/migrations have already been applied to DB1. Review before re-running.

-- 1) Idempotent PC disconnect: a revoked token replay is a no-op.
CREATE OR REPLACE FUNCTION api.device_disconnect(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  revoked_count integer := 0;
  token_digest text;
  token_was_revoked timestamptz;
BEGIN
  IF coalesce(trim(p_token), '') = '' THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  token_digest := encode(extensions.digest(p_token, 'sha256'), 'hex');
  SELECT t.device_id, t.revoked_at INTO did, token_was_revoked
  FROM public.device_tokens t
  WHERE t.token_hash = token_digest
  ORDER BY t.created_at DESC LIMIT 1 FOR UPDATE;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  IF token_was_revoked IS NOT NULL THEN
    RETURN jsonb_build_object('ok', true, 'device_id', did,
      'revoked_tokens', 0, 'already_disconnected', true);
  END IF;

  SELECT d.org_id INTO oid FROM public.devices d WHERE d.id = did;
  UPDATE public.device_tokens SET revoked_at = now()
  WHERE device_id = did AND token_hash = token_digest AND revoked_at IS NULL;
  GET DIAGNOSTICS revoked_count = ROW_COUNT;
  IF revoked_count = 0 THEN
    RETURN jsonb_build_object('ok', true, 'device_id', did,
      'revoked_tokens', 0, 'already_disconnected', true);
  END IF;

  UPDATE public.devices
  SET status = 'offline',
      power_state = 'unknown',
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('pairingDisconnectedAt', now())
  WHERE id = did;

  INSERT INTO public.audit_logs(org_id, actor_device_id, action, target_type, target_id, payload)
  VALUES (oid, did, 'device_pairing_disconnected', 'device', did::text,
    jsonb_build_object('revoked_tokens', revoked_count, 'source', 'pc-client-disconnect'));

  RETURN jsonb_build_object('ok', true, 'device_id', did,
    'revoked_tokens', revoked_count, 'already_disconnected', false);
END
$function$;

-- 2) Active-only admin username lookup. Transitional: still returns email, so
-- keep it until the APK adopts admin-login, then revoke anonymous execution.
CREATE OR REPLACE FUNCTION api.resolve_admin_username(p_username text)
RETURNS TABLE(email text, role text, status text)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'auth'
AS $function$
  SELECT u.email, a.role, a.status
  FROM public.admin_accounts a
  JOIN auth.users u ON u.id = a.auth_user_id
  WHERE p_username IS NOT NULL
    AND length(trim(p_username)) BETWEEN 1 AND 80
    AND lower(a.username) = lower(trim(p_username))
    AND a.status = 'active'
  LIMIT 1;
$function$;

CREATE UNIQUE INDEX IF NOT EXISTS admin_accounts_username_lower_key
ON public.admin_accounts (lower(trim(username)));

-- 3) Drop the exact duplicate heartbeat history index. Retain
-- idx_device_heartbeats_device_received, the equivalent index with workload scans.
DROP INDEX IF EXISTS public.device_heartbeats_device_received_at_idx;

-- 4) Index the route-control FK column.
CREATE INDEX IF NOT EXISTS idx_db_route_control_updated_by
ON public.db_route_control(updated_by);

-- 5) Persistent login-gateway rate-limit buckets. Only server_role can access.
CREATE TABLE IF NOT EXISTS public.admin_login_rate_limits (
  key_hash text PRIMARY KEY CHECK (key_hash ~ '^[0-9a-f]{64}$'),
  attempt_count integer NOT NULL DEFAULT 0 CHECK (attempt_count >= 0 AND attempt_count <= 5),
  window_started_at timestamptz NOT NULL DEFAULT now(),
  locked_until timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);
ALTER TABLE public.admin_login_rate_limits ENABLE ROW LEVEL SECURITY;
REVOKE ALL PRIVILEGES ON TABLE public.admin_login_rate_limits FROM PUBLIC, anon, authenticated;
GRANT ALL PRIVILEGES ON TABLE public.admin_login_rate_limits TO service_role;

CREATE OR REPLACE FUNCTION api.admin_login_rate_limit_consume(p_key_hash text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v public.admin_login_rate_limits%ROWTYPE;
  v_next integer;
  v_locked_until timestamptz;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'RATE_LIMIT_KEY_INVALID';
  END IF;
  INSERT INTO public.admin_login_rate_limits(key_hash, attempt_count, window_started_at, updated_at)
  VALUES (p_key_hash, 0, now(), now())
  ON CONFLICT (key_hash) DO NOTHING;
  SELECT * INTO v FROM public.admin_login_rate_limits WHERE key_hash = p_key_hash FOR UPDATE;

  IF v.locked_until IS NOT NULL AND v.locked_until > now() THEN
    RETURN jsonb_build_object('allowed', false,
      'retry_after_seconds', greatest(1, ceil(extract(epoch FROM (v.locked_until - now())))::integer);
  END IF;

  IF v.window_started_at <= now() - interval '15 minutes'
     OR (v.locked_until IS NOT NULL AND v.locked_until <= now()) THEN
    UPDATE public.admin_login_rate_limits
    SET attempt_count = 1, window_started_at = now(), locked_until = NULL, updated_at = now()
    WHERE key_hash = p_key_hash;
    RETURN jsonb_build_object('allowed', true, 'remaining_attempts', 4);
  END IF;

  v_next := least(5, v.attempt_count + 1);
  v_locked_until := CASE WHEN v_next >= 5 THEN now() + interval '15 minutes' ELSE NULL END;
  UPDATE public.admin_login_rate_limits
  SET attempt_count = v_next, locked_until = v_locked_until, updated_at = now()
  WHERE key_hash = p_key_hash;
  RETURN jsonb_build_object('allowed', true, 'remaining_attempts', greatest(0, 5 - v_next));
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_login_rate_limit_clear(p_key_hashes text[])
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE v_deleted integer := 0;
BEGIN
  IF p_key_hashes IS NULL OR cardinality(p_key_hashes) < 1 OR cardinality(p_key_hashes) > 4
     OR EXISTS (SELECT 1 FROM unnest(p_key_hashes) AS x(k)
                WHERE x.k IS NULL OR x.k !~ '^[0-9a-f]{64}$') THEN
    RAISE EXCEPTION 'RATE_LIMIT_KEYS_INVALID';
  END IF;
  DELETE FROM public.admin_login_rate_limits WHERE key_hash = ANY(p_key_hashes);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'cleared', v_deleted);
END
$function$;

REVOKE ALL PRIVILEGES ON FUNCTION api.admin_login_rate_limit_consume(text) FROM PUBLIC, anon, authenticated;
REVOKE ALL PRIVILEGES ON FUNCTION api.admin_login_rate_limit_clear(text[]) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_consume(text) TO service_role;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_clear(text[]) TO service_role;

-- 6) Keep telemetry/storage growth bounded. Both jobs are active in DB1.
DO $cron$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'device-heartbeats-retention-30d') THEN
    PERFORM cron.schedule('device-heartbeats-retention-30d', '17 18 * * *',
      'DELETE FROM public.device_heartbeats WHERE received_at < now() - interval ''30 days'';');
  END IF;
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname = 'admin-login-rate-limit-cleanup') THEN
    PERFORM cron.schedule('admin-login-rate-limit-cleanup', '43 18 * * *',
      'DELETE FROM public.admin_login_rate_limits WHERE updated_at < now() - interval ''7 days'';');
  END IF;
END
$cron$;

-- NOTE: the attempted pg_net ACL REVOKEs are intentionally omitted: checks showed
-- they did not change Supabase-owned grants. Do not treat pg_net ACL as resolved.
