-- ANI GAMES READY DB ANDROID — local Admin identity, sessions and token-bound Admin RPCs.
-- DB1 source audited 2026-11-14. This replaces Supabase Auth at the local server boundary.
-- Existing Admin business RPC bodies are retained and receive auth.uid() from a transaction-local
-- actor context set only after a valid opaque local session token is checked.
-- Passwords are stored only as bcrypt/crypt hashes. Session tokens are returned once; only SHA-256
-- hashes are stored. Bootstrap token hash is provisioned by the local server from a protected .env.
-- Do not apply to Supabase DB1/DB2 or any live production database.
BEGIN;

ALTER TABLE public.admin_accounts
  ADD COLUMN IF NOT EXISTS password_hash text;

CREATE TABLE IF NOT EXISTS public.admin_local_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  admin_account_id uuid NOT NULL REFERENCES public.admin_accounts(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz,
  refresh_token_hash text UNIQUE CHECK (refresh_token_hash IS NULL OR refresh_token_hash ~ '^[0-9a-f]{64}

CREATE INDEX IF NOT EXISTS idx_admin_local_sessions_account_active
  ON public.admin_local_sessions(admin_account_id, expires_at)
  WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS private.admin_bootstrap_control (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Compatibility shim: local API wrappers set this GUC only after validating a local session.
-- No client receives SQL access or a direct way to impersonate this context.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog'
AS $function$
  SELECT NULLIF(current_setting('ani.admin_actor_id', true), '')::uuid;
$function$;

CREATE OR REPLACE FUNCTION private.admin_account_by_token(p_session_token text)
RETURNS public.admin_accounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_session public.admin_local_sessions%ROWTYPE;
  v_account public.admin_accounts%ROWTYPE;
BEGIN
  IF NULLIF(BTRIM(p_session_token), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_NOT_AUTHENTICATED';
  END IF;
  SELECT * INTO v_session
  FROM public.admin_local_sessions
  WHERE token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
    AND revoked_at IS NULL
    AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_SESSION_EXPIRED'; END IF;

  SELECT * INTO v_account
  FROM public.admin_accounts
  WHERE id = v_session.admin_account_id AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_DISABLED'; END IF;

  UPDATE public.admin_local_sessions SET last_seen_at = now() WHERE id = v_session.id;
  RETURN v_account;
END;
$function$;

CREATE OR REPLACE FUNCTION private.set_admin_actor(p_session_token text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
BEGIN
  v_account := private.admin_account_by_token(p_session_token);
  PERFORM set_config('ani.admin_actor_id', v_account.auth_user_id::text, true);
  RETURN v_account.auth_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_bootstrap_owner(
  p_bootstrap_token text,
  p_username text,
  p_password text,
  p_org_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  v_control private.admin_bootstrap_control%ROWTYPE;
  v_user_id uuid := gen_random_uuid();
  v_org_id uuid := gen_random_uuid();
  v_account_id uuid;
  v_email text;
  v_slug text;
BEGIN
  SELECT * INTO v_control FROM private.admin_bootstrap_control
  WHERE singleton = true AND consumed_at IS NULL FOR UPDATE;
  IF NOT FOUND OR NULLIF(p_bootstrap_token, '') IS NULL
     OR v_control.token_hash <> encode(extensions.digest(p_bootstrap_token, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_DENIED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin_accounts WHERE role = 'SUPER_ADMIN' AND status = 'active') THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_ALREADY_CONFIGURED';
  END IF;
  IF length(btrim(coalesce(p_username,''))) NOT BETWEEN 3 AND 120
     OR length(coalesce(p_password,'')) < 12
     OR length(btrim(coalesce(p_org_name,''))) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_INPUT_INVALID';
  END IF;

  v_email := CASE WHEN position('@' in btrim(p_username)) > 1
    THEN lower(btrim(p_username))
    ELSE lower(btrim(p_username)) || '@local.anigamesready'
  END;
  v_slug := 'ani-' || replace(v_org_id::text, '-', '');

  INSERT INTO public.organizations(id, name, slug, kind, status)
  VALUES (v_org_id, btrim(p_org_name), v_slug, 'owner', 'active');

  INSERT INTO auth.users(id, email, created_at, updated_at)
  VALUES (v_user_id, v_email, now(), now());

  INSERT INTO public.admin_accounts(auth_user_id, username, role, org_id, status,
                                    display_name, must_change_password, password_hash)
  VALUES (v_user_id, btrim(p_username), 'SUPER_ADMIN', v_org_id, 'active',
          btrim(p_username), false, extensions.crypt(p_password, extensions.gen_salt('bf')))
  RETURNING id INTO v_account_id;

  INSERT INTO public.org_members(org_id, auth_user_id, role)
  VALUES (v_org_id, v_user_id, 'owner');

  UPDATE private.admin_bootstrap_control SET consumed_at = now() WHERE singleton = true;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (v_org_id, v_user_id, 'admin_bootstrap_owner', 'admin_account', v_account_id::text,
          jsonb_build_object('username', btrim(p_username), 'source', 'local-bootstrap'));

  RETURN jsonb_build_object('ok', true, 'admin_account_id', v_account_id,
                            'org_id', v_org_id, 'username', btrim(p_username),
                            'role', 'SUPER_ADMIN', 'bootstrap_consumed', true);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_login(
  p_username text,
  p_password text,
  p_rate_key_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
  v_rate jsonb;
  v_token text;
  v_refresh_token text;
  v_session_id uuid;
BEGIN
  IF length(coalesce(p_password,'')) < 1 OR NULLIF(BTRIM(p_username),'') IS NULL
     OR coalesce(p_rate_key_hash,'') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'INVALID_CREDENTIALS';
  END IF;

  v_rate := api.admin_login_rate_limit_consume(p_rate_key_hash);
  IF coalesce((v_rate->>'allowed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_LOGIN_RATE_LIMITED';
  END IF;

  SELECT a.* INTO v_account
  FROM public.admin_accounts a
  LEFT JOIN auth.users u ON u.id = a.auth_user_id
  WHERE lower(a.username) = lower(btrim(p_username))
     OR lower(coalesce(u.email,'')) = lower(btrim(p_username))
  ORDER BY CASE WHEN lower(a.username)=lower(btrim(p_username)) THEN 0 ELSE 1 END
  LIMIT 1;

  IF NOT FOUND OR v_account.status <> 'active'
     OR v_account.password_hash IS NULL
     OR extensions.crypt(p_password, v_account.password_hash) <> v_account.password_hash THEN
    RAISE EXCEPTION 'INVALID_CREDENTIALS';
  END IF;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  v_refresh_token := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.admin_local_sessions(admin_account_id, token_hash, expires_at, refresh_token_hash, refresh_expires_at)
  VALUES (v_account.id, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '12 hours',
          encode(extensions.digest(v_refresh_token, 'sha256'), 'hex'), now() + interval '30 days')
  RETURNING id INTO v_session_id;

  UPDATE public.admin_accounts SET last_login_at=now(), updated_at=now() WHERE id=v_account.id;
  PERFORM api.admin_login_rate_limit_clear(ARRAY[p_rate_key_hash]);

  RETURN jsonb_build_object(
    'ok', true, 'token', v_token, 'refresh_token', v_refresh_token, 'session_id', v_session_id,
    'expires_at', now() + interval '12 hours',
    'id', v_account.id, 'auth_user_id', v_account.auth_user_id, 'username', v_account.username, 'role', v_account.role,
    'org_id', v_account.org_id, 'must_change_password', v_account.must_change_password
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_refresh_session(p_refresh_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','extensions','pg_catalog'
AS $function$
DECLARE
  v_session public.admin_local_sessions%ROWTYPE;
  v_account public.admin_accounts%ROWTYPE;
  v_access text;
  v_refresh text;
BEGIN
  IF NULLIF(BTRIM(p_refresh_token),'') IS NULL THEN RAISE EXCEPTION 'ADMIN_REFRESH_EXPIRED'; END IF;
  SELECT * INTO v_session
  FROM public.admin_local_sessions
  WHERE refresh_token_hash=encode(extensions.digest(p_refresh_token,'sha256'),'hex')
    AND revoked_at IS NULL AND refresh_expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_REFRESH_EXPIRED'; END IF;
  SELECT * INTO v_account FROM public.admin_accounts
  WHERE id=v_session.admin_account_id AND status='active';
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_DISABLED'; END IF;

  v_access := encode(extensions.gen_random_bytes(32),'hex');
  v_refresh := encode(extensions.gen_random_bytes(32),'hex');
  UPDATE public.admin_local_sessions
  SET token_hash=encode(extensions.digest(v_access,'sha256'),'hex'),
      expires_at=now()+interval '12 hours',
      refresh_token_hash=encode(extensions.digest(v_refresh,'sha256'),'hex'),
      refresh_expires_at=now()+interval '30 days',
      last_seen_at=now()
  WHERE id=v_session.id;

  RETURN jsonb_build_object(
    'ok',true,'token',v_access,'refresh_token',v_refresh,
    'expires_at',now()+interval '12 hours',
    'id',v_account.id,'auth_user_id',v_account.auth_user_id,
    'username',v_account.username,'role',v_account.role,
    'org_id',v_account.org_id,'must_change_password',v_account.must_change_password
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_get_user(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
  v_email text;
BEGIN
  v_account := private.admin_account_by_token(p_session_token);
  SELECT email INTO v_email FROM auth.users WHERE id=v_account.auth_user_id;
  RETURN jsonb_build_object(
    'id',v_account.auth_user_id,'email',v_email,
    'role',v_account.role,'org_id',v_account.org_id,
    'user_metadata',jsonb_build_object('username',v_account.username)
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_logout(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
DECLARE v_count integer;
BEGIN
  UPDATE public.admin_local_sessions
  SET revoked_at=coalesce(revoked_at,now())
  WHERE token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex')
    AND revoked_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'revoked', v_count > 0);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_change_password(
  p_session_token text,
  p_current_password text,
  p_new_password text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
  v_hash text := encode(extensions.digest(p_session_token,'sha256'),'hex');
BEGIN
  v_account := private.admin_account_by_token(p_session_token);
  IF v_account.password_hash IS NULL
     OR extensions.crypt(p_current_password, v_account.password_hash) <> v_account.password_hash THEN
    RAISE EXCEPTION 'CURRENT_PASSWORD_INVALID';
  END IF;
  IF length(coalesce(p_new_password,'')) < 12 THEN RAISE EXCEPTION 'PASSWORD_TOO_SHORT'; END IF;

  UPDATE public.admin_accounts
  SET password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf')),
      must_change_password=false, updated_at=now()
  WHERE id=v_account.id;

  UPDATE public.admin_local_sessions
  SET revoked_at=now()
  WHERE admin_account_id=v_account.id AND token_hash<>v_hash AND revoked_at IS NULL;

  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(v_account.org_id,v_account.auth_user_id,'admin_password_changed','admin_account',
         v_account.id::text,jsonb_build_object('source','local-admin-api'));

  RETURN jsonb_build_object('ok',true,'other_sessions_revoked',true);
END;
$function$;

-- Token-bound wrappers. They preserve DB1 RPC business rules but bind auth.uid() to
-- the account verified by private.admin_account_by_token() for this transaction only.
CREATE OR REPLACE FUNCTION api.admin_context_v2(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_context_v2();
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_context(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_context();
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_rental_accounts_global(p_session_token text,p_org_id uuid)
RETURNS SETOF public.rental_accounts LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN QUERY SELECT * FROM api.admin_rental_accounts_global(p_org_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_create_rental_global(
  p_session_token text,p_org_id uuid,p_code text,p_category text DEFAULT 'reguler',
  p_minutes bigint DEFAULT 60,p_client_label text DEFAULT NULL,p_expiry_at timestamptz DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_create_rental_global(p_org_id,p_code,p_category,p_minutes,p_client_label,p_expiry_at);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_update_rental_global(
  p_session_token text,p_org_id uuid,p_rental_id uuid,p_code text,p_category text,
  p_minutes bigint,p_client_label text,p_expiry_at timestamptz,p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_update_rental_global(p_org_id,p_rental_id,p_code,p_category,p_minutes,p_client_label,p_expiry_at,p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_disable_rental_global(p_session_token text,p_org_id uuid,p_rental_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_disable_rental_global(p_org_id,p_rental_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_delete_rental_global(p_session_token text,p_org_id uuid,p_rental_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_delete_rental_global(p_org_id,p_rental_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_recent_alerts(
  p_session_token text,p_org_id uuid,p_since timestamptz DEFAULT now()-interval '2 minutes'
)
RETURNS TABLE(id uuid,device_id uuid,device_name text,client_id text,source_event_id text,
              event_type text,message text,payload jsonb,occurred_at timestamptz,created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN QUERY SELECT * FROM api.admin_recent_alerts(p_org_id,p_since);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_selected_sessions(p_session_token text,p_org_id uuid,p_device_id uuid)
RETURNS SETOF public.rental_sessions LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN QUERY SELECT * FROM api.admin_selected_sessions(p_org_id,p_device_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_command(
  p_session_token text,p_org_id uuid,p_device_id uuid,p_command text,p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_command(p_org_id,p_device_id,p_command,p_payload);
END;
$function$;

CREATE OR REPLACE FUNCTION api.create_device_recovery_enrollment(
  p_session_token text,p_device_id uuid,p_minutes bigint DEFAULT 30
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.create_device_recovery_enrollment(p_device_id,p_minutes);
END;
$function$;

CREATE OR REPLACE FUNCTION api.report_rental_period_breakdown(
  p_session_token text,p_org_id uuid,p_from timestamptz,p_to timestamptz
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.report_rental_period_breakdown(p_org_id,p_from,p_to);
END;
$function$;

-- The local API runtime can execute only explicitly token-bound API entry points.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api FROM ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_bootstrap_owner(text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_refresh_session(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_get_user(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_logout(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_change_password(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_context_v2(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_context(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_rental_accounts_global(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_create_rental_global(text,uuid,text,text,bigint,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_global(text,uuid,uuid,text,text,bigint,text,timestamptz,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_disable_rental_global(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_delete_rental_global(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_recent_alerts(text,uuid,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_selected_sessions(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_command(text,uuid,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.create_device_recovery_enrollment(text,uuid,bigint) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.report_rental_period_breakdown(text,uuid,timestamptz,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_consume(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_clear(text[]) TO ani_api_runtime;

-- Keep the already-tested device and Reseller token entry points available after
-- tightening the broad grants inherited from migration 005.
GRANT EXECUTE ON FUNCTION api.device_pairing_rate_limit_consume(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_pairing_rate_limit_clear(text[]) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.redeem_device(text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_heartbeat(text,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_disconnect(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_watchdog_poll(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_ack(text,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_finalize_trial(text,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_sync(text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_pull_sync(text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_sync_cursor(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_rentals_snapshot(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_free_test_policy(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_rental_lookup(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_start_rental_session(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_end_rental_session(text,text,bigint,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_release_rental_lease(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_emit_admin_alert(text,text,text,text,jsonb,timestamptz) TO ani_api_runtime;

GRANT EXECUTE ON FUNCTION api.billing_login(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_context(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_logout(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_change_password(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_rental_accounts_global(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_create_rental_global(text,uuid,text,text,bigint,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_edit_rental_global(text,uuid,uuid,text,bigint,text,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_delete_rental_global(text,uuid,uuid) TO ani_api_runtime;

REVOKE EXECUTE ON FUNCTION auth.uid() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auth.uid() FROM ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.admin_account_by_token(text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.set_admin_actor(text) FROM PUBLIC,ani_api_runtime;

COMMIT;
),
  refresh_expires_at timestamptz
);

CREATE INDEX IF NOT EXISTS idx_admin_local_sessions_account_active
  ON public.admin_local_sessions(admin_account_id, expires_at)
  WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS private.admin_bootstrap_control (
  singleton boolean PRIMARY KEY DEFAULT true CHECK (singleton),
  token_hash text NOT NULL CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  consumed_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now()
);

-- Compatibility shim: local API wrappers set this GUC only after validating a local session.
-- No client receives SQL access or a direct way to impersonate this context.
CREATE OR REPLACE FUNCTION auth.uid()
RETURNS uuid
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'pg_catalog'
AS $function$
  SELECT NULLIF(current_setting('ani.admin_actor_id', true), '')::uuid;
$function$;

CREATE OR REPLACE FUNCTION private.admin_account_by_token(p_session_token text)
RETURNS public.admin_accounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_session public.admin_local_sessions%ROWTYPE;
  v_account public.admin_accounts%ROWTYPE;
BEGIN
  IF NULLIF(BTRIM(p_session_token), '') IS NULL THEN
    RAISE EXCEPTION 'ADMIN_NOT_AUTHENTICATED';
  END IF;
  SELECT * INTO v_session
  FROM public.admin_local_sessions
  WHERE token_hash = encode(extensions.digest(p_session_token, 'sha256'), 'hex')
    AND revoked_at IS NULL
    AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_SESSION_EXPIRED'; END IF;

  SELECT * INTO v_account
  FROM public.admin_accounts
  WHERE id = v_session.admin_account_id AND status = 'active';
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_DISABLED'; END IF;

  UPDATE public.admin_local_sessions SET last_seen_at = now() WHERE id = v_session.id;
  RETURN v_account;
END;
$function$;

CREATE OR REPLACE FUNCTION private.set_admin_actor(p_session_token text)
RETURNS uuid
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
BEGIN
  v_account := private.admin_account_by_token(p_session_token);
  PERFORM set_config('ani.admin_actor_id', v_account.auth_user_id::text, true);
  RETURN v_account.auth_user_id;
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_bootstrap_owner(
  p_bootstrap_token text,
  p_username text,
  p_password text,
  p_org_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  v_control private.admin_bootstrap_control%ROWTYPE;
  v_user_id uuid := gen_random_uuid();
  v_org_id uuid := gen_random_uuid();
  v_account_id uuid;
  v_email text;
  v_slug text;
BEGIN
  SELECT * INTO v_control FROM private.admin_bootstrap_control
  WHERE singleton = true AND consumed_at IS NULL FOR UPDATE;
  IF NOT FOUND OR NULLIF(p_bootstrap_token, '') IS NULL
     OR v_control.token_hash <> encode(extensions.digest(p_bootstrap_token, 'sha256'), 'hex') THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_DENIED';
  END IF;
  IF EXISTS (SELECT 1 FROM public.admin_accounts WHERE role = 'SUPER_ADMIN' AND status = 'active') THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_ALREADY_CONFIGURED';
  END IF;
  IF length(btrim(coalesce(p_username,''))) NOT BETWEEN 3 AND 120
     OR length(coalesce(p_password,'')) < 12
     OR length(btrim(coalesce(p_org_name,''))) NOT BETWEEN 2 AND 120 THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_INPUT_INVALID';
  END IF;

  v_email := CASE WHEN position('@' in btrim(p_username)) > 1
    THEN lower(btrim(p_username))
    ELSE lower(btrim(p_username)) || '@local.anigamesready'
  END;
  v_slug := 'ani-' || replace(v_org_id::text, '-', '');

  INSERT INTO public.organizations(id, name, slug, kind, status)
  VALUES (v_org_id, btrim(p_org_name), v_slug, 'owner', 'active');

  INSERT INTO auth.users(id, email, created_at, updated_at)
  VALUES (v_user_id, v_email, now(), now());

  INSERT INTO public.admin_accounts(auth_user_id, username, role, org_id, status,
                                    display_name, must_change_password, password_hash)
  VALUES (v_user_id, btrim(p_username), 'SUPER_ADMIN', v_org_id, 'active',
          btrim(p_username), false, extensions.crypt(p_password, extensions.gen_salt('bf')))
  RETURNING id INTO v_account_id;

  INSERT INTO public.org_members(org_id, auth_user_id, role)
  VALUES (v_org_id, v_user_id, 'owner');

  UPDATE private.admin_bootstrap_control SET consumed_at = now() WHERE singleton = true;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (v_org_id, v_user_id, 'admin_bootstrap_owner', 'admin_account', v_account_id::text,
          jsonb_build_object('username', btrim(p_username), 'source', 'local-bootstrap'));

  RETURN jsonb_build_object('ok', true, 'admin_account_id', v_account_id,
                            'org_id', v_org_id, 'username', btrim(p_username),
                            'role', 'SUPER_ADMIN', 'bootstrap_consumed', true);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_login(
  p_username text,
  p_password text,
  p_rate_key_hash text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
  v_rate jsonb;
  v_token text;
  v_session_id uuid;
BEGIN
  IF length(coalesce(p_password,'')) < 1 OR NULLIF(BTRIM(p_username),'') IS NULL
     OR coalesce(p_rate_key_hash,'') !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'INVALID_CREDENTIALS';
  END IF;

  v_rate := api.admin_login_rate_limit_consume(p_rate_key_hash);
  IF coalesce((v_rate->>'allowed')::boolean, false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_LOGIN_RATE_LIMITED';
  END IF;

  SELECT a.* INTO v_account
  FROM public.admin_accounts a
  LEFT JOIN auth.users u ON u.id = a.auth_user_id
  WHERE lower(a.username) = lower(btrim(p_username))
     OR lower(coalesce(u.email,'')) = lower(btrim(p_username))
  ORDER BY CASE WHEN lower(a.username)=lower(btrim(p_username)) THEN 0 ELSE 1 END
  LIMIT 1;

  IF NOT FOUND OR v_account.status <> 'active'
     OR v_account.password_hash IS NULL
     OR extensions.crypt(p_password, v_account.password_hash) <> v_account.password_hash THEN
    RAISE EXCEPTION 'INVALID_CREDENTIALS';
  END IF;

  v_token := encode(extensions.gen_random_bytes(32), 'hex');
  INSERT INTO public.admin_local_sessions(admin_account_id, token_hash, expires_at)
  VALUES (v_account.id, encode(extensions.digest(v_token, 'sha256'), 'hex'), now() + interval '12 hours')
  RETURNING id INTO v_session_id;

  UPDATE public.admin_accounts SET last_login_at=now(), updated_at=now() WHERE id=v_account.id;
  PERFORM api.admin_login_rate_limit_clear(ARRAY[p_rate_key_hash]);

  RETURN jsonb_build_object(
    'ok', true, 'token', v_token, 'session_id', v_session_id,
    'expires_at', now() + interval '12 hours',
    'id', v_account.id, 'username', v_account.username, 'role', v_account.role,
    'org_id', v_account.org_id, 'must_change_password', v_account.must_change_password
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_logout(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
DECLARE v_count integer;
BEGIN
  UPDATE public.admin_local_sessions
  SET revoked_at=coalesce(revoked_at,now())
  WHERE token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex')
    AND revoked_at IS NULL;
  GET DIAGNOSTICS v_count = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'revoked', v_count > 0);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_change_password(
  p_session_token text,
  p_current_password text,
  p_new_password text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  v_account public.admin_accounts%ROWTYPE;
  v_hash text := encode(extensions.digest(p_session_token,'sha256'),'hex');
BEGIN
  v_account := private.admin_account_by_token(p_session_token);
  IF v_account.password_hash IS NULL
     OR extensions.crypt(p_current_password, v_account.password_hash) <> v_account.password_hash THEN
    RAISE EXCEPTION 'CURRENT_PASSWORD_INVALID';
  END IF;
  IF length(coalesce(p_new_password,'')) < 12 THEN RAISE EXCEPTION 'PASSWORD_TOO_SHORT'; END IF;

  UPDATE public.admin_accounts
  SET password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf')),
      must_change_password=false, updated_at=now()
  WHERE id=v_account.id;

  UPDATE public.admin_local_sessions
  SET revoked_at=now()
  WHERE admin_account_id=v_account.id AND token_hash<>v_hash AND revoked_at IS NULL;

  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(v_account.org_id,v_account.auth_user_id,'admin_password_changed','admin_account',
         v_account.id::text,jsonb_build_object('source','local-admin-api'));

  RETURN jsonb_build_object('ok',true,'other_sessions_revoked',true);
END;
$function$;

-- Token-bound wrappers. They preserve DB1 RPC business rules but bind auth.uid() to
-- the account verified by private.admin_account_by_token() for this transaction only.
CREATE OR REPLACE FUNCTION api.admin_context_v2(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_context_v2();
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_context(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_context();
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_rental_accounts_global(p_session_token text,p_org_id uuid)
RETURNS SETOF public.rental_accounts LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN QUERY SELECT * FROM api.admin_rental_accounts_global(p_org_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_create_rental_global(
  p_session_token text,p_org_id uuid,p_code text,p_category text DEFAULT 'reguler',
  p_minutes bigint DEFAULT 60,p_client_label text DEFAULT NULL,p_expiry_at timestamptz DEFAULT NULL
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_create_rental_global(p_org_id,p_code,p_category,p_minutes,p_client_label,p_expiry_at);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_update_rental_global(
  p_session_token text,p_org_id uuid,p_rental_id uuid,p_code text,p_category text,
  p_minutes bigint,p_client_label text,p_expiry_at timestamptz,p_status text
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_update_rental_global(p_org_id,p_rental_id,p_code,p_category,p_minutes,p_client_label,p_expiry_at,p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_disable_rental_global(p_session_token text,p_org_id uuid,p_rental_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_disable_rental_global(p_org_id,p_rental_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_delete_rental_global(p_session_token text,p_org_id uuid,p_rental_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_delete_rental_global(p_org_id,p_rental_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_recent_alerts(
  p_session_token text,p_org_id uuid,p_since timestamptz DEFAULT now()-interval '2 minutes'
)
RETURNS TABLE(id uuid,device_id uuid,device_name text,client_id text,source_event_id text,
              event_type text,message text,payload jsonb,occurred_at timestamptz,created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN QUERY SELECT * FROM api.admin_recent_alerts(p_org_id,p_since);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_selected_sessions(p_session_token text,p_org_id uuid,p_device_id uuid)
RETURNS SETOF public.rental_sessions LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN QUERY SELECT * FROM api.admin_selected_sessions(p_org_id,p_device_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_command(
  p_session_token text,p_org_id uuid,p_device_id uuid,p_command text,p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.admin_command(p_org_id,p_device_id,p_command,p_payload);
END;
$function$;

CREATE OR REPLACE FUNCTION api.create_device_recovery_enrollment(
  p_session_token text,p_device_id uuid,p_minutes bigint DEFAULT 30
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.create_device_recovery_enrollment(p_device_id,p_minutes);
END;
$function$;

CREATE OR REPLACE FUNCTION api.report_rental_period_breakdown(
  p_session_token text,p_org_id uuid,p_from timestamptz,p_to timestamptz
)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  RETURN api.report_rental_period_breakdown(p_org_id,p_from,p_to);
END;
$function$;

-- The local API runtime can execute only explicitly token-bound API entry points.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api FROM ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_bootstrap_owner(text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_logout(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_change_password(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_context_v2(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_context(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_rental_accounts_global(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_create_rental_global(text,uuid,text,text,bigint,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_global(text,uuid,uuid,text,text,bigint,text,timestamptz,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_disable_rental_global(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_delete_rental_global(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_recent_alerts(text,uuid,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_selected_sessions(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_command(text,uuid,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.create_device_recovery_enrollment(text,uuid,bigint) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.report_rental_period_breakdown(text,uuid,timestamptz,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_consume(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_clear(text[]) TO ani_api_runtime;

-- Keep the already-tested device and Reseller token entry points available after
-- tightening the broad grants inherited from migration 005.
GRANT EXECUTE ON FUNCTION api.device_pairing_rate_limit_consume(text,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_pairing_rate_limit_clear(text[]) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.redeem_device(text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_heartbeat(text,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_disconnect(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_watchdog_poll(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_ack(text,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_finalize_trial(text,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_sync(text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_pull_sync(text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_sync_cursor(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_rentals_snapshot(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_free_test_policy(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_rental_lookup(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_start_rental_session(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_end_rental_session(text,text,bigint,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_release_rental_lease(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.device_emit_admin_alert(text,text,text,text,jsonb,timestamptz) TO ani_api_runtime;

GRANT EXECUTE ON FUNCTION api.billing_login(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_context(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_logout(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_change_password(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_rental_accounts_global(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_create_rental_global(text,uuid,text,text,bigint,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_edit_rental_global(text,uuid,uuid,text,bigint,text,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_reseller_delete_rental_global(text,uuid,uuid) TO ani_api_runtime;

REVOKE EXECUTE ON FUNCTION auth.uid() FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION auth.uid() FROM ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.admin_account_by_token(text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.set_admin_actor(text) FROM PUBLIC,ani_api_runtime;

COMMIT;
