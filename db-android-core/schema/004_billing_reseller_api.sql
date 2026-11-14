-- ANI GAMES READY DB ANDROID — Billing/Reseller local authentication and rental API
-- Source: Supabase Primary DB1 live routine definitions, read-only audit 2026-11-14.
-- Scope: Billing Control (SUPER_ADMIN account family) and RESELLER_ADMIN custom-token family.
-- This does NOT port Supabase Auth for the Admin APK. Admin accounts are a separate identity family.
-- No real user rows, usernames, password hashes, tokens or secrets are included.
-- Apply only to fresh staging after 000, 002, and 003 migrations.
-- Security: all passwords are verified with pgcrypto crypt; only SHA-256(session token) is stored;
-- sessions expire after 12 hours and can be revoked; reseller operations are hard-scoped to account org.
-- The HTTP API must enforce rate-limit consume on username+client IP before calling billing_login,
-- and clear those buckets only on successful authentication (same transaction boundary as deployed Edge wrapper).
BEGIN;

-- Local API runtime uses the local schema; function execution grants are added in the API adapter migration.
CREATE OR REPLACE FUNCTION api.admin_login_rate_limit_clear(p_key_hashes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_deleted integer := 0;
BEGIN
  IF p_key_hashes IS NULL OR cardinality(p_key_hashes) < 1 OR cardinality(p_key_hashes) > 4
     OR EXISTS (
       SELECT 1 FROM unnest(p_key_hashes) AS x(k)
       WHERE x.k IS NULL OR x.k !~ '^[0-9a-f]{64}$'
     ) THEN
    RAISE EXCEPTION 'RATE_LIMIT_KEYS_INVALID';
  END IF;

  DELETE FROM public.admin_login_rate_limits
  WHERE key_hash = ANY(p_key_hashes);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;

  RETURN jsonb_build_object('ok', true, 'cleared', v_deleted);
END
$function$;

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

  SELECT * INTO v
  FROM public.admin_login_rate_limits
  WHERE key_hash = p_key_hash
  FOR UPDATE;

  IF v.locked_until IS NOT NULL AND v.locked_until > now() THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'retry_after_seconds', greatest(1, ceil(extract(epoch FROM (v.locked_until - now())))::integer)
    );
  END IF;

  IF v.window_started_at <= now() - interval '15 minutes'
     OR (v.locked_until IS NOT NULL AND v.locked_until <= now()) THEN
    UPDATE public.admin_login_rate_limits
    SET attempt_count = 1,
        window_started_at = now(),
        locked_until = NULL,
        updated_at = now()
    WHERE key_hash = p_key_hash;

    RETURN jsonb_build_object('allowed', true, 'remaining_attempts', 4);
  END IF;

  v_next := least(5, v.attempt_count + 1);
  v_locked_until := CASE WHEN v_next >= 5 THEN now() + interval '15 minutes' ELSE NULL END;

  UPDATE public.admin_login_rate_limits
  SET attempt_count = v_next,
      locked_until = v_locked_until,
      updated_at = now()
  WHERE key_hash = p_key_hash;

  -- The fifth request is still allowed to authenticate. If it fails, the next
  -- attempt is blocked; a successful login clears the corresponding buckets.
  RETURN jsonb_build_object(
    'allowed', true,
    'remaining_attempts', greatest(0, 5 - v_next)
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.billing_change_password(p_session_token text, p_current_password text, p_new_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.billing_control_accounts%rowtype;
begin
 a:=private.billing_account_by_token(p_session_token);
 if a.password_hash is null or extensions.crypt(p_current_password,a.password_hash)<>a.password_hash then raise exception 'CURRENT_PASSWORD_INVALID'; end if;
 if length(coalesce(p_new_password,''))<8 then raise exception 'PASSWORD_TOO_SHORT'; end if;
 update public.billing_control_accounts set password_hash=extensions.crypt(p_new_password,extensions.gen_salt('bf')),must_change_password=false,failed_attempts=0,locked_until=null,updated_at=now() where id=a.id;
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
 values(a.org_id,null,'billing_self_password_changed','billing_control_account',a.id,jsonb_build_object('username',a.username));
 return jsonb_build_object('ok',true);
end $function$;

CREATE OR REPLACE FUNCTION api.billing_context(p_session_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.billing_control_accounts%rowtype; o jsonb;
begin
 a:=private.billing_account_by_token(p_session_token);
 select coalesce(jsonb_agg(jsonb_build_object('id',x.id,'name',x.name,'slug',x.slug) order by x.name),'[]'::jsonb) into o
 from public.organizations x where x.id=a.org_id and x.status='active';
 return jsonb_build_object('id',a.id,'username',a.username,'role',a.role,'org_id',a.org_id,'must_change_password',a.must_change_password,'orgs',o);
end $function$;

CREATE OR REPLACE FUNCTION api.billing_login(p_username text, p_password text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.billing_control_accounts%rowtype; raw_token text; th text; sid uuid;
begin
 select * into a from public.billing_control_accounts where lower(username)=lower(trim(p_username)) for update;
 if not found then raise exception 'INVALID_CREDENTIALS'; end if;
 if a.status<>'active' then raise exception 'INVALID_CREDENTIALS'; end if;
 if a.locked_until is not null and a.locked_until>now() then raise exception 'INVALID_CREDENTIALS'; end if;
 if a.password_hash is null or extensions.crypt(p_password,a.password_hash)<>a.password_hash then
   update public.billing_control_accounts
   set failed_attempts=failed_attempts+1,
       locked_until=case when failed_attempts+1>=5 then now()+interval '10 minutes' else locked_until end,
       updated_at=now()
   where id=a.id;
   raise exception 'INVALID_CREDENTIALS';
 end if;
 update public.billing_control_accounts set failed_attempts=0,locked_until=null,last_login_at=now(),updated_at=now() where id=a.id;
 raw_token:=encode(extensions.gen_random_bytes(32),'hex');
 th:=encode(extensions.digest(raw_token,'sha256'),'hex');
 insert into public.billing_control_sessions(billing_account_id,token_hash,expires_at) values(a.id,th,now()+interval '12 hours') returning id into sid;
 delete from public.billing_control_sessions where billing_account_id=a.id and (revoked_at is not null or expires_at<now());
 return jsonb_build_object('ok',true,'token',raw_token,'username',a.username,'role',a.role,'org_id',a.org_id,'must_change_password',a.must_change_password,'session_id',sid);
end $function$;

CREATE OR REPLACE FUNCTION api.billing_logout(p_session_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
 update public.billing_control_sessions set revoked_at=now()
 where token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') and revoked_at is null;
 return jsonb_build_object('ok',true);
end $function$;

CREATE OR REPLACE FUNCTION api.billing_reseller_create_rental_global(p_session_token text, p_org_id uuid, p_code text, p_category text DEFAULT 'reguler'::text, p_minutes bigint DEFAULT 60, p_client_label text DEFAULT NULL::text, p_expiry_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  c text := upper(trim(coalesce(p_code, '')));
  cat text := coalesce(nullif(trim(p_category), ''), 'reguler');
  secs bigint;
  tid uuid;
  rid uuid;
  expiry timestamptz := p_expiry_at;
BEGIN
  a := private.billing_account_by_token(p_session_token);

  IF a.role <> 'RESELLER_ADMIN' OR a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;

  IF c = '' OR length(c) > 120 OR c = '__TEST10__' THEN
    RAISE EXCEPTION 'RENTAL_CODE_INVALID';
  END IF;
  IF p_minutes IS NULL OR p_minutes < 1 OR p_minutes > 525600 THEN
    RAISE EXCEPTION 'RENTAL_MINUTES_INVALID';
  END IF;
  IF cat NOT IN ('reguler', 'mingguan', 'bulanan', 'hemat', 'sultan', 'mega hemat') THEN
    RAISE EXCEPTION 'RENTAL_CATEGORY_INVALID';
  END IF;
  IF expiry IS NOT NULL AND expiry <= now() THEN
    RAISE EXCEPTION 'EXPIRY_MUST_BE_FUTURE';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.organizations o
    WHERE o.id = p_org_id AND o.status = 'active'
  ) THEN
    RAISE EXCEPTION 'ORG_NOT_FOUND';
  END IF;

  secs := p_minutes * 60;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || c, 0));

  IF EXISTS (
    SELECT 1 FROM public.rental_accounts r
    WHERE r.org_id = p_org_id AND upper(trim(r.code)) = c
  ) THEN
    RAISE EXCEPTION 'CODE_ALREADY_EXISTS';
  END IF;

  SELECT o.theme_id INTO tid
  FROM public.organizations o
  WHERE o.id = p_org_id;

  INSERT INTO public.rental_accounts(
    org_id, device_id, code, category, remaining_seconds, expiry_at,
    status, client_label, theme_id, metadata
  )
  VALUES(
    p_org_id, NULL, c, cat, secs, expiry,
    'active', nullif(trim(p_client_label), ''), tid,
    jsonb_build_object('source', 'reseller-global-rental')
  )
  RETURNING id INTO rid;

  INSERT INTO public.billing_transactions(
    org_id, device_id, rental_account_id, theme_id, transaction_type,
    amount, duration_seconds, occurred_at, client_label, reference,
    data_class, metadata
  )
  VALUES(
    p_org_id, NULL, rid, tid, 'time_add',
    0, secs, now(), nullif(trim(p_client_label), ''),
    'reseller_global_create', 'transaction',
    jsonb_build_object(
      'source', 'reseller-global-rental',
      'billing_username', a.username,
      'device_independent', true
    )
  );

  INSERT INTO public.audit_logs(
    org_id, actor_user_id, action, target_type, target_id, payload
  )
  VALUES(
    p_org_id, a.auth_user_id, 'reseller_create_rental_global',
    'rental_account', rid::text,
    jsonb_build_object(
      'code', c, 'category', cat, 'minutes', p_minutes,
      'device_independent', true, 'billing_username', a.username
    )
  );

  RETURN jsonb_build_object(
    'ok', true, 'id', rid, 'org_id', p_org_id, 'code', c,
    'category', cat, 'remaining_seconds', secs,
    'expiry_at', expiry, 'device_id', NULL
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.billing_reseller_delete_rental_global(p_session_token text, p_org_id uuid, p_rental_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  cid uuid;
  v_lease_until timestamptz;
BEGIN
  -- The reseller token itself is the authentication proof. Reseller accounts
  -- intentionally have no auth.users UUID, so do not require a.auth_user_id.
  a := private.billing_account_by_token(p_session_token);

  IF a.role IS DISTINCT FROM 'RESELLER_ADMIN'
     OR a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;
  IF p_org_id IS NULL OR p_rental_id IS NULL THEN
    RAISE EXCEPTION 'RENTAL_ID_REQUIRED';
  END IF;

  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id = p_rental_id AND org_id = p_org_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RENTAL_NOT_FOUND';
  END IF;

  PERFORM pg_advisory_xact_lock(
    hashtextextended(p_org_id::text || ':' || upper(trim(r.code)), 0)
  );

  -- Preserve the existing safety rules: do not delete while a session is
  -- active/paused, or while a valid offline lease is still outstanding.
  IF EXISTS (
    SELECT 1
    FROM public.rental_sessions s
    WHERE s.org_id = p_org_id
      AND s.status IN ('active', 'paused')
      AND (
        s.rental_account_id = r.id
        OR upper(trim(s.code)) = upper(trim(r.code))
      )
  ) THEN
    RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED';
  END IF;

  IF to_regclass('public.rental_offline_leases') IS NOT NULL THEN
    EXECUTE $sql$
      SELECT l.lease_until
      FROM public.rental_offline_leases l
      WHERE l.rental_account_id = $1
        AND l.lease_until > now()
      ORDER BY l.lease_until DESC
      LIMIT 1
      FOR UPDATE
    $sql$ INTO v_lease_until USING r.id;

    IF v_lease_until IS NOT NULL THEN
      RAISE EXCEPTION 'RENTAL_ACTIVE_OFFLINE_LEASE';
    END IF;
  END IF;

  -- Keep PC synchronization best-effort; deleting the shared database row
  -- does not depend on the PC being online. created_by is nullable for
  -- reseller accounts authenticated by their own billing token.
  IF r.device_id IS NOT NULL THEN
    INSERT INTO public.device_commands(
      org_id, device_id, command, payload, status, created_by
    )
    VALUES (
      p_org_id,
      r.device_id,
      'delete_rental',
      jsonb_build_object(
        'code', r.code,
        'source', 'reseller-global-delete'
      ),
      'queued',
      a.auth_user_id
    )
    RETURNING id INTO cid;

    INSERT INTO public.device_command_logs(
      command_id, org_id, device_id, status, result
    )
    VALUES (
      cid,
      p_org_id,
      r.device_id,
      'queued',
      jsonb_build_object(
        'source', 'reseller-global-delete',
        'rental_account_id', r.id,
        'code', r.code,
        'billing_account_id', a.id,
        'billing_username', a.username
      )
    );
  END IF;

  INSERT INTO public.audit_logs(
    org_id, actor_user_id, action, target_type, target_id, payload
  )
  VALUES (
    p_org_id,
    a.auth_user_id,
    'reseller_delete_rental_global',
    'rental_account',
    r.id::text,
    jsonb_build_object(
      'code', r.code,
      'device_id', r.device_id,
      'command_id', cid,
      'billing_account_id', a.id,
      'billing_username', a.username,
      'history_preserved', true,
      'deleted_from_global_rental_list', true
    )
  );

  DELETE FROM public.rental_accounts
  WHERE id = r.id AND org_id = p_org_id;

  RETURN jsonb_build_object(
    'ok', true,
    'id', r.id,
    'org_id', p_org_id,
    'code', r.code,
    'device_id', r.device_id,
    'command_id', cid,
    'history_preserved', true
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.billing_reseller_edit_rental_global(p_session_token text, p_org_id uuid, p_rental_id uuid, p_category text, p_minutes bigint, p_client_label text, p_expiry_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  cat text := coalesce(nullif(trim(p_category), ''), 'reguler');
  secs bigint;
  expiry timestamptz := p_expiry_at;
  cid uuid;
  next_status text;
BEGIN
  a := private.billing_account_by_token(p_session_token);

  IF a.role <> 'RESELLER_ADMIN' OR a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;
  IF p_rental_id IS NULL THEN
    RAISE EXCEPTION 'RENTAL_ID_REQUIRED';
  END IF;
  IF p_minutes IS NULL OR p_minutes < 0 OR p_minutes > 525600 THEN
    RAISE EXCEPTION 'RENTAL_MINUTES_INVALID';
  END IF;
  IF cat NOT IN ('reguler', 'mingguan', 'bulanan', 'hemat', 'sultan', 'mega hemat') THEN
    RAISE EXCEPTION 'RENTAL_CATEGORY_INVALID';
  END IF;
  IF expiry IS NOT NULL AND expiry <= now() THEN
    RAISE EXCEPTION 'EXPIRY_MUST_BE_FUTURE';
  END IF;

  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id = p_rental_id AND org_id = p_org_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RENTAL_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rental_sessions s
    WHERE s.rental_account_id = r.id AND s.status IN ('active', 'paused')
  ) THEN
    RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED';
  END IF;

  secs := p_minutes * 60;
  next_status := CASE
    WHEN secs = 0 AND r.status = 'active' THEN 'expired'
    ELSE r.status
  END;

  UPDATE public.rental_accounts
  SET category = cat,
      remaining_seconds = secs,
      expiry_at = expiry,
      client_label = nullif(trim(p_client_label), ''),
      status = next_status,
      updated_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb)
        || jsonb_build_object('source', 'reseller-global-edit')
  WHERE id = r.id;

  -- Best-effort delivery for accounts previously assigned to a PC.
  -- The database update succeeds independently of PC online/heartbeat state.
  IF r.device_id IS NOT NULL THEN
    INSERT INTO public.device_commands(
      org_id, device_id, command, payload, status, created_by
    )
    VALUES(
      p_org_id, r.device_id, 'upsert_rental',
      jsonb_build_object(
        'code', r.code,
        'category', cat,
        'remainingSeconds', secs,
        'expiryDate', expiry,
        'clientLabel', nullif(trim(p_client_label), ''),
        'source', 'reseller-global-edit'
      ),
      'queued', a.auth_user_id
    )
    RETURNING id INTO cid;

    INSERT INTO public.device_command_logs(
      command_id, org_id, device_id, status, result
    )
    VALUES(
      cid, p_org_id, r.device_id, 'queued',
      jsonb_build_object(
        'source', 'reseller-global-edit',
        'rental_account_id', r.id
      )
    );
  END IF;

  INSERT INTO public.audit_logs(
    org_id, actor_user_id, action, target_type, target_id, payload
  )
  VALUES(
    p_org_id, a.auth_user_id, 'reseller_edit_rental_global',
    'rental_account', r.id::text,
    jsonb_build_object(
      'code', r.code, 'device_id', r.device_id,
      'old_minutes', floor(r.remaining_seconds / 60.0),
      'new_minutes', p_minutes, 'command_id', cid,
      'billing_username', a.username
    )
  );

  RETURN jsonb_build_object(
    'ok', true, 'id', r.id, 'org_id', p_org_id, 'code', r.code,
    'category', cat, 'remaining_seconds', secs,
    'expiry_at', expiry, 'status', next_status,
    'device_id', r.device_id, 'command_id', cid
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.billing_reseller_edit_rental_global(p_session_token text, p_org_id uuid, p_rental_id uuid, p_category text, p_minutes bigint, p_client_label text, p_status text, p_expiry_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  cat text := coalesce(nullif(trim(p_category), ''), 'reguler');
  status_value text := lower(coalesce(nullif(trim(p_status), ''), ''));
  secs bigint;
  expiry timestamptz := p_expiry_at;
  cid uuid;
BEGIN
  a := private.billing_account_by_token(p_session_token);

  IF a.role <> 'RESELLER_ADMIN' OR a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;
  IF p_rental_id IS NULL THEN
    RAISE EXCEPTION 'RENTAL_ID_REQUIRED';
  END IF;
  IF p_minutes IS NULL OR p_minutes < 0 OR p_minutes > 525600 THEN
    RAISE EXCEPTION 'RENTAL_MINUTES_INVALID';
  END IF;
  IF status_value NOT IN ('active', 'disabled', 'expired') THEN
    RAISE EXCEPTION 'RENTAL_STATUS_INVALID';
  END IF;
  IF status_value = 'active' AND p_minutes < 1 THEN
    RAISE EXCEPTION 'ACTIVE_RENTAL_MINUTES_REQUIRED';
  END IF;
  IF cat NOT IN ('reguler', 'mingguan', 'bulanan', 'hemat', 'sultan', 'mega hemat') THEN
    RAISE EXCEPTION 'RENTAL_CATEGORY_INVALID';
  END IF;
  IF status_value = 'active' AND expiry IS NOT NULL AND expiry <= now() THEN
    RAISE EXCEPTION 'EXPIRY_MUST_BE_FUTURE';
  END IF;

  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id = p_rental_id AND org_id = p_org_id
  FOR UPDATE;
  IF NOT FOUND THEN
    RAISE EXCEPTION 'RENTAL_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rental_sessions s
    WHERE s.rental_account_id = r.id AND s.status IN ('active', 'paused')
  ) THEN
    RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED';
  END IF;

  secs := p_minutes * 60;

  UPDATE public.rental_accounts
  SET category = cat,
      remaining_seconds = secs,
      expiry_at = expiry,
      client_label = nullif(trim(p_client_label), ''),
      status = status_value,
      updated_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb)
        || jsonb_build_object('source', 'reseller-global-edit', 'edited_status', status_value)
  WHERE id = r.id;

  -- Best-effort delivery for accounts previously assigned to a PC.
  -- Database update succeeds independently of PC online/heartbeat state.
  IF r.device_id IS NOT NULL THEN
    INSERT INTO public.device_commands(
      org_id, device_id, command, payload, status, created_by
    )
    VALUES(
      p_org_id, r.device_id, 'upsert_rental',
      jsonb_build_object(
        'code', r.code,
        'category', cat,
        'remainingSeconds', secs,
        'expiryDate', expiry,
        'clientLabel', nullif(trim(p_client_label), ''),
        'status', status_value,
        'source', 'reseller-global-edit'
      ),
      'queued', a.auth_user_id
    )
    RETURNING id INTO cid;

    INSERT INTO public.device_command_logs(
      command_id, org_id, device_id, status, result
    )
    VALUES(
      cid, p_org_id, r.device_id, 'queued',
      jsonb_build_object(
        'source', 'reseller-global-edit',
        'rental_account_id', r.id,
        'status', status_value
      )
    );
  END IF;

  INSERT INTO public.audit_logs(
    org_id, actor_user_id, action, target_type, target_id, payload
  )
  VALUES(
    p_org_id, a.auth_user_id, 'reseller_edit_rental_global',
    'rental_account', r.id::text,
    jsonb_build_object(
      'code', r.code,
      'device_id', r.device_id,
      'old_status', r.status,
      'new_status', status_value,
      'old_minutes', floor(r.remaining_seconds / 60.0),
      'new_minutes', p_minutes,
      'command_id', cid,
      'billing_username', a.username
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'id', r.id,
    'org_id', p_org_id,
    'code', r.code,
    'category', cat,
    'remaining_seconds', secs,
    'expiry_at', expiry,
    'status', status_value,
    'device_id', r.device_id,
    'command_id', cid
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.billing_reseller_rental_accounts_global(p_session_token text, p_org_id uuid)
 RETURNS SETOF rental_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
BEGIN
  a := private.billing_account_by_token(p_session_token);

  IF a.role <> 'RESELLER_ADMIN' OR a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;

  RETURN QUERY
    SELECT r.*
    FROM public.rental_accounts r
    WHERE r.org_id = p_org_id
      AND upper(trim(r.code)) <> '__TEST10__'
    ORDER BY r.code;
END
$function$;

CREATE OR REPLACE FUNCTION private.billing_account_by_token(p_token text)
 RETURNS billing_control_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.billing_control_accounts%rowtype; sid public.billing_control_sessions%rowtype;
begin
 if nullif(trim(p_token),'') is null then raise exception 'BILLING_NOT_AUTHENTICATED'; end if;
 select * into sid from public.billing_control_sessions
 where token_hash=encode(extensions.digest(p_token,'sha256'),'hex')
   and revoked_at is null and expires_at>now()
 for update;
 if not found then raise exception 'BILLING_SESSION_EXPIRED'; end if;
 select * into a from public.billing_control_accounts where id=sid.billing_account_id and status='active';
 if not found then raise exception 'BILLING_ACCOUNT_DISABLED'; end if;
 update public.billing_control_sessions set last_seen_at=now() where id=sid.id;
 return a;
end $function$;
COMMIT;
