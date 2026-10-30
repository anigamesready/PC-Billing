-- GLOBAL_RENTAL_ACCOUNTS_AND_OFFLINE_LEASES_V1
-- Release-candidate migration. Apply separately to DB1 and DB2 only after review.
-- This migration is intentionally additive and fails closed if existing account/session data conflicts.

BEGIN;

CREATE TABLE IF NOT EXISTS public.rental_offline_leases (
  rental_account_id uuid PRIMARY KEY REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  lease_until timestamptz NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS rental_offline_leases_device_until_idx
  ON public.rental_offline_leases(device_id, lease_until);
REVOKE ALL ON TABLE public.rental_offline_leases FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.rental_offline_leases TO service_role;

CREATE TABLE IF NOT EXISTS public.rental_sync_conflicts (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  code text NOT NULL,
  source_event_id text NOT NULL,
  reason text NOT NULL,
  event_payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now(),
  resolved_at timestamptz,
  UNIQUE(org_id, source_event_id)
);
REVOKE ALL ON TABLE public.rental_sync_conflicts FROM PUBLIC, anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.rental_sync_conflicts TO service_role;

DO $$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.rental_accounts
    GROUP BY org_id, upper(trim(code)) HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'GLOBAL_RENTAL_MIGRATION_BLOCKED_DUPLICATE_NORMALIZED_CODES';
  END IF;
  IF EXISTS (
    SELECT 1 FROM public.rental_sessions
    WHERE rental_account_id IS NOT NULL AND status IN ('active','paused')
    GROUP BY rental_account_id HAVING count(*) > 1
  ) THEN
    RAISE EXCEPTION 'GLOBAL_RENTAL_MIGRATION_BLOCKED_DUPLICATE_OPEN_ACCOUNT_SESSIONS';
  END IF;
END $$;

CREATE UNIQUE INDEX IF NOT EXISTS rental_accounts_org_upper_code_key
  ON public.rental_accounts(org_id, upper(trim(code)));
CREATE UNIQUE INDEX IF NOT EXISTS rental_sessions_one_open_per_rental_account
  ON public.rental_sessions(rental_account_id)
  WHERE rental_account_id IS NOT NULL AND status IN ('active','paused');

CREATE OR REPLACE FUNCTION api.admin_rental_accounts_global(p_org_id uuid)
RETURNS SETOF public.rental_accounts
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE uid uuid := auth.uid();
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (
       SELECT 1 FROM public.org_members m
       WHERE m.org_id=p_org_id AND m.auth_user_id=uid AND m.role='reseller_admin'
     ) THEN
    RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED';
  END IF;
  RETURN QUERY
    SELECT r.* FROM public.rental_accounts r
    WHERE r.org_id=p_org_id AND upper(r.code) <> '__TEST10__'
    ORDER BY r.code;
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_create_rental_global(
  p_org_id uuid, p_code text, p_category text DEFAULT 'reguler',
  p_minutes bigint DEFAULT 60, p_client_label text DEFAULT NULL,
  p_expiry_at timestamptz DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  uid uuid := auth.uid();
  c text := upper(trim(coalesce(p_code,'')));
  cat text := coalesce(nullif(trim(p_category),''),'reguler');
  secs bigint;
  tid uuid;
  rid uuid;
  expiry timestamptz := p_expiry_at;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (SELECT 1 FROM public.org_members m
       WHERE m.org_id=p_org_id AND m.auth_user_id=uid AND m.role='reseller_admin') THEN
    RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED';
  END IF;
  IF c='' OR length(c)>120 OR c='__TEST10__' THEN RAISE EXCEPTION 'RENTAL_CODE_INVALID'; END IF;
  IF p_minutes IS NULL OR p_minutes<1 OR p_minutes>525600 THEN RAISE EXCEPTION 'RENTAL_MINUTES_INVALID'; END IF;
  IF cat NOT IN ('reguler','mingguan','bulanan','hemat','sultan','mega hemat') THEN
    RAISE EXCEPTION 'RENTAL_CATEGORY_INVALID';
  END IF;
  IF expiry IS NOT NULL AND expiry<=now() THEN RAISE EXCEPTION 'EXPIRY_MUST_BE_FUTURE'; END IF;
  secs := p_minutes*60;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_org_id::text||':'||c,0));
  IF EXISTS (SELECT 1 FROM public.rental_accounts r WHERE r.org_id=p_org_id AND upper(trim(r.code))=c) THEN
    RAISE EXCEPTION 'CODE_ALREADY_EXISTS';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM public.organizations WHERE id=p_org_id) THEN RAISE EXCEPTION 'ORG_NOT_FOUND'; END IF;
  SELECT theme_id INTO tid FROM public.organizations WHERE id=p_org_id;
  INSERT INTO public.rental_accounts(org_id,device_id,code,category,remaining_seconds,expiry_at,status,client_label,theme_id,metadata)
  VALUES(p_org_id,NULL,c,cat,secs,expiry,'active',nullif(trim(p_client_label),''),tid,jsonb_build_object('source','admin-global-rental'))
  RETURNING id INTO rid;
  INSERT INTO public.billing_transactions(org_id,device_id,rental_account_id,theme_id,transaction_type,amount,duration_seconds,
    occurred_at,client_label,reference,data_class,metadata)
  VALUES(p_org_id,NULL,rid,tid,'time_add',0,secs,now(),nullif(trim(p_client_label),''),'admin_global_create','transaction',
    jsonb_build_object('source','admin-global-rental','actor_user_id',uid));
  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(p_org_id,uid,'admin_create_rental_global','rental_account',rid,
    jsonb_build_object('code',c,'minutes',p_minutes,'device_independent',true));
  RETURN jsonb_build_object('ok',true,'id',rid,'org_id',p_org_id,'code',c,'category',cat,
    'remaining_seconds',secs,'expiry_at',expiry,'device_id',NULL);
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_update_rental_global(
  p_org_id uuid, p_rental_id uuid, p_code text, p_category text,
  p_minutes bigint, p_client_label text, p_expiry_at timestamptz, p_status text
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  uid uuid := auth.uid();
  r public.rental_accounts%ROWTYPE;
  c text := upper(trim(coalesce(p_code,'')));
  cat text := coalesce(nullif(trim(p_category),''),'reguler');
  st text := coalesce(p_status,'');
  secs bigint;
  expiry timestamptz := p_expiry_at;
  active_row boolean;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (SELECT 1 FROM public.org_members m
       WHERE m.org_id=p_org_id AND m.auth_user_id=uid AND m.role='reseller_admin') THEN
    RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED';
  END IF;
  IF p_rental_id IS NULL OR c='' OR length(c)>120 OR c='__TEST10__' THEN RAISE EXCEPTION 'RENTAL_FIELDS_INVALID'; END IF;
  IF p_minutes IS NULL OR p_minutes<0 OR p_minutes>525600 THEN RAISE EXCEPTION 'RENTAL_MINUTES_INVALID'; END IF;
  IF cat NOT IN ('reguler','mingguan','bulanan','hemat','sultan','mega hemat') THEN RAISE EXCEPTION 'RENTAL_CATEGORY_INVALID'; END IF;
  IF st NOT IN ('active','expired','disabled') THEN RAISE EXCEPTION 'RENTAL_STATUS_INVALID'; END IF;
  IF expiry IS NOT NULL AND expiry<=now() THEN RAISE EXCEPTION 'EXPIRY_MUST_BE_FUTURE'; END IF;
  secs := p_minutes*60;
  IF secs=0 AND st='active' THEN st:='expired'; END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE id=p_rental_id AND org_id=p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_org_id::text||':'||c,0));
  IF EXISTS (SELECT 1 FROM public.rental_accounts x WHERE x.org_id=p_org_id AND upper(trim(x.code))=c AND x.id<>r.id) THEN
    RAISE EXCEPTION 'CODE_ALREADY_EXISTS';
  END IF;
  active_row := EXISTS(SELECT 1 FROM public.rental_sessions s
    WHERE s.rental_account_id=r.id AND s.status IN ('active','paused'));
  IF active_row AND (c<>upper(trim(r.code)) OR secs<>r.remaining_seconds OR expiry IS DISTINCT FROM r.expiry_at OR st<>'active') THEN
    RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.rental_offline_leases l WHERE l.rental_account_id=r.id AND l.lease_until>now())
     AND (c<>upper(trim(r.code)) OR secs<>r.remaining_seconds OR expiry IS DISTINCT FROM r.expiry_at OR st<>'active') THEN
    RAISE EXCEPTION 'RENTAL_HAS_OFFLINE_LEASE';
  END IF;
  UPDATE public.rental_accounts
  SET code=c, category=cat, remaining_seconds=secs, expiry_at=expiry,
      client_label=nullif(trim(p_client_label),''), status=st, updated_at=now(),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('source','admin-global-edit')
  WHERE id=r.id;
  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(p_org_id,uid,'admin_update_rental_global','rental_account',r.id,
    jsonb_build_object('old_code',r.code,'new_code',c,'old_minutes',floor(r.remaining_seconds/60.0),
      'new_minutes',p_minutes,'old_status',r.status,'new_status',st));
  RETURN jsonb_build_object('ok',true,'id',r.id,'org_id',p_org_id,'code',c,'category',cat,
    'remaining_seconds',secs,'expiry_at',expiry,'status',st,'device_id',r.device_id);
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_disable_rental_global(p_org_id uuid, p_rental_id uuid)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE uid uuid := auth.uid(); r public.rental_accounts%ROWTYPE;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (SELECT 1 FROM public.org_members m
       WHERE m.org_id=p_org_id AND m.auth_user_id=uid AND m.role='reseller_admin') THEN
    RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED';
  END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE id=p_rental_id AND org_id=p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF EXISTS(SELECT 1 FROM public.rental_sessions s WHERE s.rental_account_id=r.id AND s.status IN ('active','paused')) THEN
    RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.rental_offline_leases l WHERE l.rental_account_id=r.id AND l.lease_until>now()) THEN
    RAISE EXCEPTION 'RENTAL_HAS_OFFLINE_LEASE';
  END IF;
  UPDATE public.rental_accounts SET status='disabled',updated_at=now() WHERE id=r.id;
  DELETE FROM public.rental_offline_leases WHERE rental_account_id=r.id;
  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(p_org_id,uid,'admin_disable_rental_global','rental_account',r.id,jsonb_build_object('code',r.code));
  RETURN jsonb_build_object('ok',true,'id',r.id,'code',r.code,'status','disabled');
END
$function$;

CREATE OR REPLACE FUNCTION api.device_rental_lookup(p_token text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,'')));
  r public.rental_accounts%ROWTYPE; l public.rental_offline_leases%ROWTYPE;
  s public.rental_sessions%ROWTYPE; remaining bigint; until_at timestamptz;
BEGIN
  SELECT d.id,d.org_id INTO did,oid
  FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF c='' OR c='__TEST10__' THEN RAISE EXCEPTION 'RENTAL_CODE_INVALID'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(oid::text||':'||c,0));
  SELECT * INTO r FROM public.rental_accounts
  WHERE org_id=oid AND upper(trim(code))=c FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF r.status<>'active' THEN RAISE EXCEPTION 'RENTAL_NOT_ACTIVE'; END IF;
  IF r.expiry_at IS NOT NULL AND r.expiry_at<=now() THEN RAISE EXCEPTION 'RENTAL_EXPIRED'; END IF;
  IF r.remaining_seconds<=0 THEN RAISE EXCEPTION 'RENTAL_TIME_EXHAUSTED'; END IF;
  SELECT * INTO s FROM public.rental_sessions
   WHERE rental_account_id=r.id AND status IN ('active','paused')
   ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND s.status='active' AND s.deadline_at IS NOT NULL AND s.deadline_at<=now() THEN
    UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=s.id;
    UPDATE public.rental_accounts SET remaining_seconds=0,status='expired',updated_at=now() WHERE id=r.id;
    DELETE FROM public.rental_offline_leases WHERE rental_account_id=r.id;
    RETURN jsonb_build_object('ok',false,'error','RENTAL_TIME_EXHAUSTED');
  END IF;
  IF FOUND AND s.device_id<>did THEN RAISE EXCEPTION 'RENTAL_ACTIVE_ON_OTHER_PC'; END IF;
  SELECT * INTO l FROM public.rental_offline_leases WHERE rental_account_id=r.id FOR UPDATE;
  IF FOUND AND l.lease_until>now() AND l.device_id<>did THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  IF FOUND AND l.lease_until>now() AND l.device_id=did THEN
    IF s.status='active' AND s.deadline_at IS NOT NULL THEN until_at:=greatest(l.lease_until,s.deadline_at+make_interval(secs=>1800));
    ELSIF s.status='paused' THEN until_at:=now()+make_interval(secs=>greatest(0,coalesce(s.last_client_remaining_seconds,r.remaining_seconds))+1800);
    ELSE until_at:=now()+make_interval(secs=>greatest(0,r.remaining_seconds)+1800); END IF;
  ELSE
    remaining:=CASE WHEN s.status='active' AND s.deadline_at IS NOT NULL
      THEN greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint)
      WHEN s.status='paused' THEN greatest(0,coalesce(s.last_client_remaining_seconds,r.remaining_seconds))
      ELSE greatest(0,r.remaining_seconds) END;
    until_at:=now()+make_interval(secs=>remaining + 1800);
  END IF;
  IF until_at<=now() THEN RAISE EXCEPTION 'RENTAL_TIME_EXHAUSTED'; END IF;
  INSERT INTO public.rental_offline_leases(rental_account_id,org_id,device_id,lease_until,created_at,updated_at)
  VALUES(r.id,oid,did,until_at,now(),now())
  ON CONFLICT(rental_account_id) DO UPDATE
   SET org_id=EXCLUDED.org_id,device_id=EXCLUDED.device_id,lease_until=EXCLUDED.lease_until,updated_at=now()
   WHERE public.rental_offline_leases.device_id=did OR public.rental_offline_leases.lease_until<=now();
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  RETURN jsonb_build_object('ok',true,'id',r.id,'org_id',oid,'device_id',did,'code',r.code,
    'category',r.category,'remaining_seconds',CASE WHEN s.status='active' AND s.deadline_at IS NOT NULL
      THEN greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint)
      WHEN s.status='paused' THEN greatest(0,coalesce(s.last_client_remaining_seconds,r.remaining_seconds)) ELSE r.remaining_seconds END,
    'expiry_at',r.expiry_at,'status',r.status,'client_label',r.client_label,
    'updated_at',r.updated_at,'offline_lease_until',until_at,'session_id',s.id);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_start_rental_session(p_token text, p_code text, p_source_event_id text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,'')));
  r public.rental_accounts%ROWTYPE; s public.rental_sessions%ROWTYPE;
  lease public.rental_offline_leases%ROWTYPE; sid uuid; tid uuid; deadline timestamptz;
BEGIN
  SELECT d.id,d.org_id INTO did,oid
  FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF c='' OR c='__TEST10__' THEN RAISE EXCEPTION 'RENTAL_CODE_INVALID'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(oid::text||':'||c,0));
  IF nullif(trim(p_source_event_id),'') IS NOT NULL THEN
    SELECT * INTO s FROM public.rental_sessions WHERE org_id=oid AND source_event_id=p_source_event_id LIMIT 1;
    IF FOUND THEN RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',s.status,'idempotent',true,
      'remaining_seconds',greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint),'deadline_at',s.deadline_at); END IF;
  END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE org_id=oid AND upper(trim(code))=c FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF r.status<>'active' THEN RAISE EXCEPTION 'RENTAL_NOT_ACTIVE'; END IF;
  IF r.expiry_at IS NOT NULL AND r.expiry_at<=now() THEN RAISE EXCEPTION 'RENTAL_EXPIRED'; END IF;
  IF r.remaining_seconds<=0 THEN RAISE EXCEPTION 'RENTAL_TIME_EXHAUSTED'; END IF;
  SELECT * INTO s FROM public.rental_sessions
  WHERE rental_account_id=r.id AND status IN ('active','paused') ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF s.device_id<>did THEN RAISE EXCEPTION 'RENTAL_ACTIVE_ON_OTHER_PC'; END IF;
    IF s.deadline_at IS NOT NULL AND s.deadline_at<=now() THEN
      UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=s.id;
      UPDATE public.rental_accounts SET remaining_seconds=0,status='expired',updated_at=now() WHERE id=r.id;
      DELETE FROM public.rental_offline_leases WHERE rental_account_id=r.id;
      RETURN jsonb_build_object('ok',false,'error','RENTAL_TIME_EXHAUSTED');
    END IF;
    RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',s.status,'idempotent',true,
      'remaining_seconds',greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint),'deadline_at',s.deadline_at);
  END IF;
  SELECT * INTO lease FROM public.rental_offline_leases WHERE rental_account_id=r.id FOR UPDATE;
  IF FOUND AND lease.lease_until>now() AND lease.device_id<>did THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  SELECT * INTO s FROM public.rental_sessions
   WHERE device_id=did AND status IN ('active','paused') ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND s.code<>c AND (s.deadline_at IS NULL OR s.deadline_at>now()) THEN RAISE EXCEPTION 'ACTIVE_SESSION_EXISTS'; END IF;
  IF FOUND AND s.status='active' AND s.deadline_at IS NOT NULL AND s.deadline_at<=now() THEN
    UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=s.id;
  END IF;
  SELECT theme_id INTO tid FROM public.organizations WHERE id=oid;
  deadline:=now()+make_interval(secs=>r.remaining_seconds);
  INSERT INTO public.rental_sessions(org_id,device_id,rental_account_id,code,session_type,started_at,deadline_at,status,last_client_at,
    last_client_remaining_seconds,source_event_id,theme_id,metadata)
  VALUES(oid,did,r.id,c,'rental',now(),deadline,'active',now(),r.remaining_seconds,nullif(trim(p_source_event_id),''),coalesce(r.theme_id,tid),
    jsonb_build_object('source','global-rental-api')) RETURNING id INTO sid;
  INSERT INTO public.rental_offline_leases(rental_account_id,org_id,device_id,lease_until,created_at,updated_at)
  VALUES(r.id,oid,did,deadline+make_interval(secs=>1800),now(),now())
  ON CONFLICT(rental_account_id) DO UPDATE SET org_id=EXCLUDED.org_id,device_id=EXCLUDED.device_id,
    lease_until=EXCLUDED.lease_until,updated_at=now()
  WHERE public.rental_offline_leases.device_id=did OR public.rental_offline_leases.lease_until<=now();
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  RETURN jsonb_build_object('ok',true,'session_id',sid,'rental_account_id',r.id,'code',c,
    'remaining_seconds',r.remaining_seconds,'deadline_at',deadline,'status','active','idempotent',false);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_end_rental_session(
  p_token text, p_code text, p_remaining_seconds bigint, p_source_event_id text DEFAULT NULL
) RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,''))); s public.rental_sessions%ROWTYPE;
  secs bigint:=greatest(0,coalesce(p_remaining_seconds,0)); rid uuid;
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF nullif(trim(p_source_event_id),'') IS NOT NULL AND EXISTS(
    SELECT 1 FROM public.rental_sessions WHERE org_id=oid AND source_event_id=p_source_event_id
  ) THEN RETURN jsonb_build_object('ok',true,'idempotent',true); END IF;
  SELECT * INTO s FROM public.rental_sessions WHERE org_id=oid AND device_id=did AND code=c
    AND status IN ('active','paused') ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    SELECT id INTO rid FROM public.rental_accounts WHERE org_id=oid AND upper(trim(code))=c
      AND (device_id=did OR (metadata->>'source'='pc-sync' AND metadata->>'originDeviceId'=did::text)) FOR UPDATE;
    IF rid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.rental_sessions WHERE rental_account_id=rid AND status IN ('active','paused')) THEN
      UPDATE public.rental_accounts SET remaining_seconds=secs,status=CASE WHEN secs=0 THEN 'expired' ELSE status END,updated_at=now() WHERE id=rid;
      DELETE FROM public.rental_offline_leases WHERE rental_account_id=rid AND device_id=did;
    END IF;
    RETURN jsonb_build_object('ok',true,'idempotent',true,'no_session',true);
  END IF;
  rid:=s.rental_account_id;
  IF rid IS NOT NULL THEN
    UPDATE public.rental_accounts SET remaining_seconds=secs,
      status=CASE WHEN secs=0 THEN 'expired' ELSE status END,updated_at=now()
    WHERE id=rid AND org_id=oid;
    DELETE FROM public.rental_offline_leases WHERE rental_account_id=rid AND device_id=did;
  END IF;
  UPDATE public.rental_sessions SET status='ended',ended_at=now(),last_client_at=now(),
    last_client_remaining_seconds=secs,source_event_id=coalesce(nullif(trim(p_source_event_id),''),source_event_id)
  WHERE id=s.id;
  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(oid,NULL,'device_end_rental_session','rental_session',s.id,jsonb_build_object('code',c,'remaining_seconds',secs,'device_id',did));
  RETURN jsonb_build_object('ok',true,'session_id',s.id,'rental_account_id',rid,'remaining_seconds',secs,'status','ended');
END
$function$;

CREATE OR REPLACE FUNCTION api.device_release_rental_lease(p_token text, p_code text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,''))); rid uuid; removed integer;
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  SELECT id INTO rid FROM public.rental_accounts WHERE org_id=oid AND upper(trim(code))=c;
  IF rid IS NULL THEN RETURN jsonb_build_object('ok',true,'released',false); END IF;
  IF EXISTS(SELECT 1 FROM public.rental_sessions WHERE rental_account_id=rid AND status IN ('active','paused')) THEN
    RETURN jsonb_build_object('ok',true,'released',false,'active_session',true);
  END IF;
  DELETE FROM public.rental_offline_leases WHERE rental_account_id=rid AND device_id=did;
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN jsonb_build_object('ok',true,'released',removed>0);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_sync_cursor(p_token text)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE did uuid; oid uuid; ts timestamptz:=now();
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  RETURN jsonb_build_object('ok',true,'deviceId',did,'orgId',oid,'cursor',ts,'serverTime',ts);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_pull_sync(p_token text, p_cursor timestamptz DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE did uuid; oid uuid; rows jsonb; ts timestamptz:=now();
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.updated_at,r.id),'[]'::jsonb)
  INTO rows FROM public.rental_accounts r
  WHERE p_cursor IS NOT NULL AND r.org_id=oid AND upper(r.code)<>'__TEST10__'
    AND r.updated_at>=p_cursor;
  RETURN jsonb_build_object('serverTime',ts,'deviceId',did,'rentalAccounts',coalesce(rows,'[]'::jsonb),'cursor',ts,
    'fullSnapshot',false,'scope','organization-delta');
END
$function$;

-- Conflicted offline-created codes are stored as an outbox conflict, not silently accepted
-- or overwritten against a shared account. The client moves these events out of the
-- retry queue while retaining their complete payload in local conflict storage.
DO $syncpatch$
DECLARE def text; changed text;
BEGIN
  def := pg_get_functiondef('api.device_sync(text,jsonb)'::regprocedure);
  changed := replace(def,
    '  accepted jsonb := ''[]''::jsonb;',
    '  accepted jsonb := ''[]''::jsonb;'||E'\n  conflicts jsonb := ''[]''::jsonb;');
  changed := replace(changed,
    '  existing_updated timestamptz;',
    '  existing_updated timestamptz;'||E'\n  existing_source text;'||E'\n  existing_source_event text;'||E'\n  existing_source_device text;');
  changed := replace(changed,
    'SELECT id, theme_id, device_id, updated_at'||E'\n      INTO rid, tid, existing_device_id, existing_updated',
    'SELECT id, theme_id, device_id, updated_at, metadata->>''source'', metadata->>''sourceEventId'', metadata->>''originDeviceId'''||E'\n      INTO rid, tid, existing_device_id, existing_updated, existing_source, existing_source_event, existing_source_device');
  changed := replace(changed,
    'jsonb_build_object(''source'', ''pc-sync'')',
    'jsonb_build_object(''source'', ''pc-sync'', ''sourceEventId'', sid, ''originDeviceId'', did)');
  changed := replace(changed,
    '            client_label = coalesce(nullif(item->>''clientLabel'', ''''), client_label),'||E'\n            updated_at = now()',
    '            client_label = coalesce(nullif(item->>''clientLabel'', ''''), client_label),'||E'\n            metadata = coalesce(metadata, ''{}''::jsonb) || jsonb_build_object(''sourceEventId'', sid, ''originDeviceId'', did),'||E'\n            updated_at = now()');
  changed := replace(changed,
    '          oid, did, c,',
    '          oid, NULL, c,');
  changed := replace(changed,
    'WHERE org_id = oid AND code = c',
    'WHERE org_id = oid AND upper(trim(code)) = c');
  changed := replace(changed,
    '      IF base_updated IS NOT NULL AND existing_updated IS NOT NULL'||E'\n         AND existing_updated > base_updated THEN'||E'\n        accepted := accepted || jsonb_build_array(sid);'||E'\n        CONTINUE;'||E'\n      END IF;',
    '      IF base_updated IS NOT NULL AND existing_updated IS NOT NULL AND existing_updated > base_updated AND existing_source_event IS DISTINCT FROM sid THEN'||E'\n        INSERT INTO public.rental_sync_conflicts(org_id,device_id,code,source_event_id,reason,event_payload)'||E'\n        VALUES(oid,did,c,sid,''CLOUD_ROW_CHANGED_SINCE_LOCAL_BASE'',item)'||E'\n        ON CONFLICT(org_id,source_event_id) DO NOTHING;'||E'\n        conflicts := conflicts || jsonb_build_array(sid);'||E'\n        CONTINUE;'||E'\n      END IF;');
  changed := replace(changed,
    '      -- Never reassign an account owned by another PC/device. Mark the event'||E'\n      -- accepted so a client retry cannot jam the whole sync batch forever.'||E'\n      IF rid IS NOT NULL AND existing_device_id IS NOT NULL'||E'\n         AND existing_device_id <> did THEN'||E'\n        accepted := accepted || jsonb_build_array(sid);'||E'\n        CONTINUE;'||E'\n      END IF;',
    '      -- Existing cloud accounts are authoritative. Only retry an account created'||E'\n      -- by this same PC sync path; never overwrite an admin/global row or another PC row.'||E'\n      IF rid IS NOT NULL AND NOT (coalesce(existing_source_device, existing_device_id::text) = did::text AND existing_source = ''pc-sync'' AND (base_updated IS NOT NULL OR existing_source_event = sid)) THEN'||E'\n        INSERT INTO public.rental_sync_conflicts(org_id,device_id,code,source_event_id,reason,event_payload)'||E'\n        VALUES(oid,did,c,sid,''CODE_ALREADY_EXISTS_IN_SHARED_DB'',item)'||E'\n        ON CONFLICT(org_id,source_event_id) DO NOTHING;'||E'\n        conflicts := conflicts || jsonb_build_array(sid);'||E'\n        CONTINUE;'||E'\n      END IF;');
  changed := replace(changed,
    '''acceptedSourceEventIds'', accepted,'||E'\n    ''inserted'', inserted_count,',
    '''acceptedSourceEventIds'', accepted,'||E'\n    ''conflictSourceEventIds'', conflicts,'||E'\n    ''inserted'', inserted_count,');
  IF changed = def
     OR position('conflictSourceEventIds' in changed)=0
     OR position('existing_source text' in changed)=0
     OR position('existing_source_event text' in changed)=0
     OR position('existing_source_device text' in changed)=0
     OR position('originDeviceId' in changed)=0
     OR position('sourceEventId' in changed)=0
     OR position('oid, NULL, c,' in changed)=0
     OR position('oid, did, c,' in changed)>0
     OR position('coalesce(existing_source_device, existing_device_id::text)' in changed)=0
     OR position('CODE_ALREADY_EXISTS_IN_SHARED_DB' in changed)=0 THEN
    RAISE EXCEPTION 'GLOBAL_RENTAL_DEVICE_SYNC_PATCH_ANCHOR_MISMATCH';
  END IF;
  EXECUTE changed;
END
$syncpatch$;

-- Existing heartbeat remains responsible for liveness/commands. It must lookup a shared
-- code globally, never reassign the account to the current PC, and return at most one account.
DO $patch$
DECLARE def text; changed text;
BEGIN
  def := pg_get_functiondef('api.device_heartbeat(text,text,jsonb)'::regprocedure);
  changed := replace(def,
    'AND (ra.device_id IS NULL OR ra.device_id = d.id)',
    '');
  changed := replace(changed,
    'ORDER BY CASE WHEN ra.device_id = d.id THEN 0 ELSE 1 END, ra.created_at DESC',
    'ORDER BY ra.created_at DESC');
  -- A device may update timer balance only for its active DB session or its own
  -- valid offline lease. Never copy stale category/expiry/status/label back over Admin edits.
  changed := replace(changed,
    'UPDATE public.rental_accounts'||E'\n        SET device_id = d.id,'||E'\n            category = target_category,'||E'\n            remaining_seconds = target_remaining,'||E'\n            expiry_at = target_expiry,'||E'\n            status = CASE WHEN target_remaining > 0 THEN ''active'' ELSE status END,'||E'\n            client_label = coalesce(target_label, client_label),'||E'\n            updated_at = now()'||E'\n        WHERE id = rid'||E'\n          AND ('||E'\n            device_id IS DISTINCT FROM d.id'||E'\n            OR category IS DISTINCT FROM target_category'||E'\n            OR expiry_at IS DISTINCT FROM target_expiry'||E'\n            OR (target_label IS NOT NULL AND client_label IS DISTINCT FROM target_label)'||E'\n            OR status IS DISTINCT FROM (CASE WHEN target_remaining > 0 THEN ''active'' ELSE status END)'||E'\n            OR ('||E'\n              remaining_seconds IS DISTINCT FROM target_remaining'||E'\n              AND ('||E'\n                abs(coalesce(remaining_seconds,0)-target_remaining) >= 30'||E'\n                OR target_remaining <= 30'||E'\n                OR coalesce(remaining_seconds,0) <= 30'||E'\n              )'||E'\n            )'||E'\n          );',
    'UPDATE public.rental_accounts'||E'\n        SET remaining_seconds = target_remaining, updated_at = now()'||E'\n        WHERE id = rid'||E'\n          AND ((open_sid IS NOT NULL AND open_code = target_code AND open_account_id = rid)'||E'\n            OR EXISTS (SELECT 1 FROM public.rental_offline_leases l WHERE l.rental_account_id = rid AND l.device_id = d.id AND l.lease_until > now()))'||E'\n          AND remaining_seconds IS DISTINCT FROM target_remaining'||E'\n          AND (abs(coalesce(remaining_seconds,0)-target_remaining) >= 30 OR target_remaining <= 30 OR coalesce(remaining_seconds,0) <= 30);');
  changed := replace(changed,
    $old$IF NOT free_test_blocked THEN$old$,
    $new$IF NOT free_test_blocked AND (coalesce(p_metadata->>'localPendingActiveCode','') = '' OR p_metadata->>'localPendingActiveCode' IS DISTINCT FROM target_code) AND NOT EXISTS (
    SELECT 1 FROM public.rental_accounts ra
    JOIN public.rental_offline_leases l ON l.rental_account_id = ra.id
    WHERE ra.org_id = d.org_id AND upper(trim(ra.code)) = target_code
      AND l.device_id <> d.id AND l.lease_until > now()
  ) THEN$new$);
  changed := replace(changed,
    'WHERE r.org_id = d.org_id'||E'\n    AND r.device_id = d.id'||E'\n    AND upper(r.code) <> ''__TEST10__'';',
    'WHERE r.org_id = d.org_id'||E'\n    AND r.code = target_code'||E'\n    AND upper(r.code) <> ''__TEST10__'';');
  IF changed = def
     OR position('ra.device_id IS NULL OR ra.device_id = d.id' in changed)>0
     OR position('SET device_id = d.id' in changed)>0
     OR position('AND r.device_id = d.id' in changed)>0 THEN
    RAISE EXCEPTION 'GLOBAL_RENTAL_HEARTBEAT_PATCH_ANCHOR_MISMATCH';
  END IF;
  EXECUTE changed;
END
$patch$;

REVOKE ALL ON FUNCTION api.admin_rental_accounts_global(uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api.admin_rental_accounts_global(uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION api.admin_create_rental_global(uuid,text,text,bigint,text,timestamptz) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api.admin_create_rental_global(uuid,text,text,bigint,text,timestamptz) TO authenticated, service_role;
REVOKE ALL ON FUNCTION api.admin_update_rental_global(uuid,uuid,text,text,bigint,text,timestamptz,text) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_global(uuid,uuid,text,text,bigint,text,timestamptz,text) TO authenticated, service_role;
REVOKE ALL ON FUNCTION api.admin_disable_rental_global(uuid,uuid) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION api.admin_disable_rental_global(uuid,uuid) TO authenticated, service_role;
REVOKE ALL ON FUNCTION api.device_rental_lookup(text,text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION api.device_rental_lookup(text,text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION api.device_start_rental_session(text,text,text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION api.device_start_rental_session(text,text,text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION api.device_end_rental_session(text,text,bigint,text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION api.device_end_rental_session(text,text,bigint,text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION api.device_release_rental_lease(text,text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION api.device_release_rental_lease(text,text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION api.device_sync_cursor(text) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION api.device_sync_cursor(text) TO anon, authenticated, service_role;
REVOKE ALL ON FUNCTION api.device_pull_sync(text,timestamptz) FROM PUBLIC, authenticated;
GRANT EXECUTE ON FUNCTION api.device_pull_sync(text,timestamptz) TO anon, authenticated, service_role;

COMMIT;
