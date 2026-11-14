-- ANI GAMES READY DB ANDROID — Billing Control/Reseller refresh sessions and device read APIs.
-- Access tokens are short-lived (12h); optional remember-login uses a rotating, revocable
-- 30-day refresh token. Only SHA-256 hashes are stored in PostgreSQL.
BEGIN;

ALTER TABLE public.billing_control_sessions
  ADD COLUMN IF NOT EXISTS refresh_token_hash text UNIQUE,
  ADD COLUMN IF NOT EXISTS refresh_expires_at timestamptz;
ALTER TABLE public.billing_control_sessions
  ADD CONSTRAINT billing_control_sessions_refresh_hash_length
  CHECK (refresh_token_hash IS NULL OR length(refresh_token_hash)=64);

CREATE OR REPLACE FUNCTION api.billing_login(p_username text,p_password text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_catalog'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  raw_token text;
  raw_refresh text;
  sid uuid;
BEGIN
  SELECT * INTO a FROM public.billing_control_accounts
  WHERE lower(username)=lower(trim(p_username)) FOR UPDATE;
  IF NOT FOUND OR a.status<>'active' THEN RAISE EXCEPTION 'INVALID_CREDENTIALS'; END IF;
  IF a.locked_until IS NOT NULL AND a.locked_until>now() THEN RAISE EXCEPTION 'INVALID_CREDENTIALS'; END IF;
  IF a.password_hash IS NULL OR extensions.crypt(p_password,a.password_hash)<>a.password_hash THEN
    UPDATE public.billing_control_accounts
    SET failed_attempts=failed_attempts+1,
        locked_until=CASE WHEN failed_attempts+1>=5 THEN now()+interval '10 minutes' ELSE locked_until END,
        updated_at=now()
    WHERE id=a.id;
    RAISE EXCEPTION 'INVALID_CREDENTIALS';
  END IF;

  UPDATE public.billing_control_accounts
  SET failed_attempts=0,locked_until=NULL,last_login_at=now(),updated_at=now()
  WHERE id=a.id;

  raw_token:=encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh:=encode(extensions.gen_random_bytes(32),'hex');
  INSERT INTO public.billing_control_sessions(
    billing_account_id,token_hash,expires_at,refresh_token_hash,refresh_expires_at
  )
  VALUES(
    a.id,encode(extensions.digest(raw_token,'sha256'),'hex'),now()+interval '12 hours',
    encode(extensions.digest(raw_refresh,'sha256'),'hex'),now()+interval '30 days'
  ) RETURNING id INTO sid;

  DELETE FROM public.billing_control_sessions
  WHERE billing_account_id=a.id AND (revoked_at IS NOT NULL OR expires_at<now());
  RETURN jsonb_build_object(
    'ok',true,'token',raw_token,'refresh_token',raw_refresh,
    'expires_at',now()+interval '12 hours','refresh_expires_at',now()+interval '30 days',
    'username',a.username,'role',a.role,'org_id',a.org_id,
    'must_change_password',a.must_change_password,'session_id',sid
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.billing_refresh_session(p_refresh_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_catalog'
AS $function$
DECLARE
  s public.billing_control_sessions%ROWTYPE;
  a public.billing_control_accounts%ROWTYPE;
  raw_token text;
  raw_refresh text;
BEGIN
  IF NULLIF(BTRIM(p_refresh_token),'') IS NULL THEN RAISE EXCEPTION 'BILLING_SESSION_EXPIRED'; END IF;
  SELECT * INTO s
  FROM public.billing_control_sessions
  WHERE refresh_token_hash=encode(extensions.digest(p_refresh_token,'sha256'),'hex')
    AND revoked_at IS NULL AND refresh_expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'BILLING_SESSION_EXPIRED'; END IF;

  SELECT * INTO a FROM public.billing_control_accounts
  WHERE id=s.billing_account_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'BILLING_ACCOUNT_DISABLED'; END IF;

  raw_token:=encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh:=encode(extensions.gen_random_bytes(32),'hex');
  UPDATE public.billing_control_sessions
  SET token_hash=encode(extensions.digest(raw_token,'sha256'),'hex'),
      expires_at=now()+interval '12 hours',
      refresh_token_hash=encode(extensions.digest(raw_refresh,'sha256'),'hex'),
      refresh_expires_at=now()+interval '30 days',
      last_seen_at=now()
  WHERE id=s.id;

  RETURN jsonb_build_object(
    'ok',true,'token',raw_token,'refresh_token',raw_refresh,
    'expires_at',now()+interval '12 hours','refresh_expires_at',now()+interval '30 days',
    'username',a.username,'role',a.role,'org_id',a.org_id,
    'must_change_password',a.must_change_password,'session_id',s.id
  );
END;
$function$;

-- Exact DB1 token-scoped device and active-session list routines used by Reseller V1.0.6.
CREATE OR REPLACE FUNCTION api.billing_devices(p_session_token text,p_org_id uuid)
RETURNS SETOF public.devices
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE a public.billing_control_accounts%ROWTYPE;
BEGIN
  a:=private.billing_account_by_token(p_session_token);
  IF a.role<>'SUPER_ADMIN' AND a.org_id IS DISTINCT FROM p_org_id THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
  UPDATE public.devices
  SET status='offline',power_state=CASE WHEN power_state='online' THEN 'unknown' ELSE power_state END
  WHERE org_id=p_org_id AND status='online'
    AND (coalesce(last_heartbeat_at,last_seen_at) IS NULL OR coalesce(last_heartbeat_at,last_seen_at)<now()-interval '45 seconds');
  RETURN QUERY SELECT d.* FROM public.devices d WHERE d.org_id=p_org_id ORDER BY d.device_name,d.client_id;
END;
$function$;

CREATE OR REPLACE FUNCTION api.billing_active_sessions(p_session_token text,p_org_id uuid)
RETURNS SETOF public.rental_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE a public.billing_control_accounts%ROWTYPE;
BEGIN
  a:=private.billing_account_by_token(p_session_token);
  IF a.role<>'SUPER_ADMIN' AND a.org_id IS DISTINCT FROM p_org_id THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
  RETURN QUERY SELECT s.* FROM public.rental_sessions s
  WHERE s.org_id=p_org_id AND s.status IN ('active','paused')
  ORDER BY s.started_at DESC;
END;
$function$;

REVOKE EXECUTE ON FUNCTION api.billing_refresh_session(text) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_devices(text,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_active_sessions(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.billing_refresh_session(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_devices(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_active_sessions(text,uuid) TO ani_api_runtime;

COMMIT;
