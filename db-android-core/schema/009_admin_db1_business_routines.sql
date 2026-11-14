-- ANI GAMES READY DB ANDROID — DB1 Admin business routines and local token wrappers.
-- Exact DB1 business routine bodies captured from primary DB1 on 2026-11-14.
-- Private helper dependencies are ordered first (user_role precedes is_owner_access).
-- The local auth.uid() shim in migration 006 resolves only after a valid local Admin token
-- is bound by the token wrappers below.
-- Legacy per-device rental create/edit/delete RPCs are excluded; use global CRUD with lease guards.
BEGIN;

CREATE OR REPLACE FUNCTION private.user_role(target_org uuid)
 RETURNS text
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare uid uuid:=auth.uid(); cur uuid:=target_org; r text;
begin
 if uid is null or target_org is null then return null; end if;
 loop
  select om.role into r from public.org_members om where om.org_id=cur and om.auth_user_id=uid order by case when om.role='owner' then 0 else 1 end,om.created_at limit 1;
  if r is not null then return r; end if;
  select o.parent_org_id into cur from public.organizations o where o.id=cur;
  exit when cur is null;
 end loop;
 return null;
end $function$;

CREATE OR REPLACE FUNCTION private.admin_can_access_device(p_device_id uuid, p_org_id uuid DEFAULT NULL::uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
 select exists(select 1 from public.devices d join public.admin_accounts a on a.auth_user_id=auth.uid() and a.status='active' where d.id=p_device_id and (p_org_id is null or d.org_id=p_org_id) and (a.role='SUPER_ADMIN' or (a.org_id=d.org_id and exists(select 1 from public.admin_pc_access x where x.admin_account_id=a.id and x.device_id=d.id))));
$function$;

CREATE OR REPLACE FUNCTION private.is_owner_access(target_org uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT COALESCE(private.user_role(target_org) = 'owner', false)
$function$;

CREATE OR REPLACE FUNCTION private.is_reseller_admin(target_org uuid)
 RETURNS boolean
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$ select exists(select 1 from public.org_members where org_id=target_org and auth_user_id=auth.uid() and role='reseller_admin') $function$;

CREATE OR REPLACE FUNCTION private.user_has_org_access(target_org uuid)
 RETURNS boolean
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$
declare current_org uuid := target_org; allowed boolean;
begin
 if auth.uid() is null or target_org is null then return false; end if;
 loop
  select exists(select 1 from public.org_members m where m.org_id=current_org and m.auth_user_id=auth.uid()) into allowed;
  if allowed then return true; end if;
  select o.parent_org_id into current_org from public.organizations o where o.id=current_org;
  exit when current_org is null;
 end loop;
 return false;
end $function$;

CREATE OR REPLACE FUNCTION api.admin_active_sessions(p_org_id uuid)
 RETURNS SETOF rental_sessions
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
 select s.* from public.rental_sessions s where s.org_id=p_org_id and s.status in ('active','paused') and private.admin_can_access_device(s.device_id,p_org_id) order by s.started_at desc;
$function$;

CREATE OR REPLACE FUNCTION api.admin_activity(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer DEFAULT 100)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare result jsonb;
begin
  if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
  if not (private.is_owner_access(p_org_id) or private.is_reseller_admin(p_org_id)) then raise exception 'ORG_ACCESS_DENIED'; end if;
  select jsonb_build_object(
    'accounts',coalesce((select jsonb_agg(x order by x.created_at desc) from (
      select id,code,category,remaining_seconds,expiry_at,status,client_label,theme_id,device_id,updated_at,created_at
      from public.rental_accounts where org_id=p_org_id
      order by created_at desc limit greatest(1,least(coalesce(p_limit,100),500))
    ) x),'[]'::jsonb),
    'sessions',coalesce((select jsonb_agg(x order by x.started_at desc) from (
      select id,code,session_type,status,started_at,ended_at,last_client_at,last_client_remaining_seconds,recovery_reason,rental_account_id,theme_id,device_id
      from public.rental_sessions where org_id=p_org_id and started_at>=p_from and started_at<p_to
      order by started_at desc limit greatest(1,least(coalesce(p_limit,100),500))
    ) x),'[]'::jsonb),
    'transactions',coalesce((select jsonb_agg(x order by x.occurred_at desc) from (
      select id,transaction_type,amount,duration_seconds,category,occurred_at,client_label,reference,rental_account_id,theme_id,device_id
      from public.billing_transactions where org_id=p_org_id and occurred_at>=p_from and occurred_at<p_to
      order by occurred_at desc limit greatest(1,least(coalesce(p_limit,100),500))
    ) x),'[]'::jsonb)
  ) into result;
  return result;
end $function$;

CREATE OR REPLACE FUNCTION api.admin_command(p_org_id uuid, p_device_id uuid, p_command text, p_payload jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  s public.rental_sessions%ROWTYPE;
  target_device public.devices%ROWTYPE;
  cid uuid;
  sid uuid;
  target_device_id uuid;
  target_mac_hex text;
  command_payload jsonb := coalesce(p_payload, '{}'::jsonb);
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO a FROM public.admin_accounts
   WHERE auth_user_id = auth.uid() AND status = 'active' LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_NOT_CONFIGURED'; END IF;
  IF a.role <> 'SUPER_ADMIN' AND a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;

  SELECT * INTO d FROM public.devices
   WHERE id = p_device_id AND org_id = p_org_id LIMIT 1;
  IF NOT FOUND OR NOT private.admin_can_access_device(p_device_id, p_org_id) THEN
    RAISE EXCEPTION 'DEVICE_ACCESS_DENIED';
  END IF;
  IF d.status = 'disabled' THEN RAISE EXCEPTION 'DEVICE_DISABLED'; END IF;

  -- Preserve the existing DB1 rule: only Restart Billing may be queued while stale.
  IF p_command IS DISTINCT FROM 'restart_billing' AND (
    coalesce(d.last_heartbeat_at, d.last_seen_at) IS NULL
      OR coalesce(d.last_heartbeat_at, d.last_seen_at) < now() - interval '45 seconds'
      OR d.status <> 'online'
  ) THEN
    RAISE EXCEPTION 'PC_OFFLINE_COMMAND_BLOCKED';
  END IF;

  IF p_command NOT IN (
    'restart_billing','restart_pc','restart','logoff','logout','pause','resume',
    'stop','shutdown','refresh','wake','add_time','show_admin_message',
    'schedule_shutdown','cancel_shutdown_timer'
  ) THEN
    RAISE EXCEPTION 'COMMAND_NOT_ALLOWED';
  END IF;

  IF p_command = 'wake' THEN
    IF p_payload->>'mode' IS DISTINCT FROM 'wake_on_lan_relay'
       OR p_payload->>'relayDeviceId' IS DISTINCT FROM p_device_id::text THEN
      RAISE EXCEPTION 'INVALID_WAKE_RELAY_REQUEST';
    END IF;

    BEGIN
      target_device_id := nullif(btrim(coalesce(p_payload->>'targetDeviceId', '')), '')::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'INVALID_WAKE_TARGET_ID';
    END;
    IF target_device_id IS NULL OR target_device_id = p_device_id THEN
      RAISE EXCEPTION 'INVALID_WAKE_TARGET_ID';
    END IF;

    SELECT * INTO target_device
      FROM public.devices
     WHERE id = target_device_id AND org_id = p_org_id
     LIMIT 1;
    IF NOT FOUND OR NOT private.admin_can_access_device(target_device_id, p_org_id) THEN
      RAISE EXCEPTION 'WAKE_TARGET_ACCESS_DENIED';
    END IF;
    IF target_device.status = 'disabled' THEN
      RAISE EXCEPTION 'WAKE_TARGET_DISABLED';
    END IF;

    IF target_device.status = 'online'
       AND coalesce(target_device.last_heartbeat_at, target_device.last_seen_at) > now() - interval '45 seconds' THEN
      RAISE EXCEPTION 'WAKE_TARGET_ALREADY_ONLINE';
    END IF;

    target_mac_hex := upper(regexp_replace(
      coalesce(target_device.metadata->>'wolLanMac', ''),
      '[^0-9A-F]', '', 'g'
    ));
    IF target_mac_hex !~ '^[0-9A-F]{12}$'
       OR target_mac_hex IN ('000000000000', 'FFFFFFFFFFFF') THEN
      RAISE EXCEPTION 'WAKE_TARGET_MAC_NOT_REPORTED';
    END IF;

    IF EXISTS (
      SELECT 1
        FROM public.device_commands c
       WHERE c.device_id = p_device_id
         AND c.command = 'wake'
         AND c.status IN ('queued', 'acknowledged', 'completed')
         AND c.created_at > now() - interval '120 seconds'
         AND c.payload->>'targetDeviceId' = target_device_id::text
    ) THEN
      RAISE EXCEPTION 'WAKE_COMMAND_ALREADY_PENDING';
    END IF;

    command_payload := command_payload || jsonb_build_object(
      'mode', 'wake_on_lan_relay',
      'relayDeviceId', p_device_id::text,
      'targetDeviceId', target_device_id::text,
      'targetDeviceName', left(coalesce(target_device.device_name, target_device.client_id, 'PC target'), 100),
      'targetMac', substr(target_mac_hex,1,2)||':'||substr(target_mac_hex,3,2)||':'||
                   substr(target_mac_hex,5,2)||':'||substr(target_mac_hex,7,2)||':'||
                   substr(target_mac_hex,9,2)||':'||substr(target_mac_hex,11,2),
      'expiresAt', (now() + interval '90 seconds')::text,
      'source', 'admin-server-resolved-wol-v1'
    );
  END IF;

  IF p_command = 'schedule_shutdown' THEN
    IF coalesce((command_payload->>'scheduled')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_PAYLOAD';
    END IF;
    IF nullif(btrim(coalesce(command_payload->>'scheduleId','')), '') IS NULL
       OR nullif(btrim(coalesce(command_payload->>'deadlineAt','')), '') IS NULL
       OR command_payload->>'targetDeviceId' IS DISTINCT FROM p_device_id::text THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_TARGET';
    END IF;
  ELSIF p_command = 'cancel_shutdown_timer' THEN
    IF coalesce((command_payload->>'cancelScheduled')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_CANCEL_PAYLOAD';
    END IF;
    IF command_payload->>'targetDeviceId' IS DISTINCT FROM p_device_id::text THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_TARGET';
    END IF;
  END IF;

  IF p_command = 'show_admin_message'
     AND length(btrim(coalesce(command_payload->>'message',''))) NOT BETWEEN 1 AND 240 THEN
    RAISE EXCEPTION 'INVALID_ADMIN_MESSAGE';
  END IF;

  IF p_command IN ('pause','resume','stop') THEN
    IF nullif(command_payload->>'session_id','') IS NULL THEN
      RAISE EXCEPTION 'SESSION_ID_REQUIRED';
    END IF;
    sid := (command_payload->>'session_id')::uuid;
    SELECT * INTO s FROM public.rental_sessions
     WHERE id = sid AND org_id = p_org_id AND device_id = p_device_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SESSION_NOT_FOUND'; END IF;
    IF p_command = 'pause' AND s.status <> 'active' THEN RAISE EXCEPTION 'SESSION_NOT_ACTIVE'; END IF;
    IF p_command = 'resume' AND s.status <> 'paused' THEN RAISE EXCEPTION 'SESSION_NOT_PAUSED'; END IF;
    IF p_command = 'stop' AND s.status NOT IN ('active','paused') THEN RAISE EXCEPTION 'SESSION_NOT_OPEN'; END IF;
  END IF;

  INSERT INTO public.device_commands(org_id, device_id, command, payload, status, created_by)
  VALUES (p_org_id, p_device_id, p_command, command_payload, 'queued', auth.uid())
  RETURNING id INTO cid;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (
    p_org_id, auth.uid(), 'remote_command', 'device', p_device_id::text,
    jsonb_build_object('command',p_command,'command_id',cid,'payload',command_payload)
  );

  RETURN jsonb_build_object(
    'ok',true,
    'command_id',cid,
    'device_id',p_device_id,
    'command',p_command,
    'target_device_id',CASE WHEN p_command = 'wake' THEN target_device_id ELSE NULL END
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_context()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare uid uuid:=auth.uid(); role_name text; result jsonb;
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select case when exists(select 1 from public.org_members where auth_user_id=uid and role='owner') then 'owner' when exists(select 1 from public.org_members where auth_user_id=uid and role='reseller_admin') then 'reseller_admin' else null end into role_name;
 if role_name is null then raise exception 'ADMIN_ROLE_REQUIRED'; end if;
 if role_name='owner' then
  select jsonb_agg(to_jsonb(o) order by o.created_at) into result from public.organizations o where private.is_owner_access(o.id);
 else
  select jsonb_agg(to_jsonb(o) order by o.created_at) into result from public.organizations o where exists(select 1 from public.org_members m where m.org_id=o.id and m.auth_user_id=uid and m.role='reseller_admin');
 end if;
 return jsonb_build_object('role',role_name,'orgs',coalesce(result,'[]'::jsonb),'user_id',uid);
end $function$;

CREATE OR REPLACE FUNCTION api.admin_context_v2()
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ declare a public.admin_accounts%rowtype; orgs jsonb; begin if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if; select * into a from public.admin_accounts where auth_user_id=auth.uid() and status='active' limit 1; if not found then raise exception 'ADMIN_ACCOUNT_NOT_CONFIGURED'; end if; update public.admin_accounts set last_login_at=now(),updated_at=now() where id=a.id; if a.role='SUPER_ADMIN' then select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'slug',o.slug,'kind',o.kind) order by o.name),'[]'::jsonb) into orgs from public.organizations o where o.status='active'; else select coalesce(jsonb_agg(jsonb_build_object('id',o.id,'name',o.name,'slug',o.slug,'kind',o.kind) order by o.name),'[]'::jsonb) into orgs from public.organizations o where o.id=a.org_id and o.status='active'; end if; return jsonb_build_object('id',a.id,'username',a.username,'role',a.role,'org_id',a.org_id,'must_change_password',a.must_change_password,'orgs',orgs); end; $function$;

CREATE OR REPLACE FUNCTION api.admin_create_rental_global(p_org_id uuid, p_code text, p_category text DEFAULT 'reguler'::text, p_minutes bigint DEFAULT 60, p_client_label text DEFAULT NULL::text, p_expiry_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
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

CREATE OR REPLACE FUNCTION api.admin_delete_rental_global(p_org_id uuid, p_rental_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  uid uuid := auth.uid();
  r public.rental_accounts%ROWTYPE;
  cid uuid;
  v_lease_until timestamptz;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (
       SELECT 1 FROM public.org_members m
       WHERE m.org_id = p_org_id
         AND m.auth_user_id = uid
         AND m.role = 'reseller_admin'
     ) THEN RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED'; END IF;
  IF p_org_id IS NULL OR p_rental_id IS NULL THEN RAISE EXCEPTION 'RENTAL_ID_REQUIRED'; END IF;

  SELECT * INTO r FROM public.rental_accounts
  WHERE id = p_rental_id AND org_id = p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;

  PERFORM pg_advisory_xact_lock(hashtextextended(p_org_id::text || ':' || upper(trim(r.code)), 0));

  IF EXISTS (
    SELECT 1 FROM public.rental_sessions s
    WHERE s.org_id = p_org_id AND s.status IN ('active', 'paused')
      AND (s.rental_account_id = r.id OR upper(trim(s.code)) = upper(trim(r.code)))
  ) THEN RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED'; END IF;

  -- DB1 contains rental_offline_leases; DB2 does not yet have that table.
  IF to_regclass('public.rental_offline_leases') IS NOT NULL THEN
    EXECUTE $sql$
      SELECT l.lease_until FROM public.rental_offline_leases l
      WHERE l.rental_account_id = $1 AND l.lease_until > now()
      ORDER BY l.lease_until DESC LIMIT 1 FOR UPDATE
    $sql$ INTO v_lease_until USING r.id;
    IF v_lease_until IS NOT NULL THEN RAISE EXCEPTION 'RENTAL_ACTIVE_OFFLINE_LEASE'; END IF;
  END IF;

  IF r.device_id IS NOT NULL THEN
    INSERT INTO public.device_commands(org_id, device_id, command, payload, status, created_by)
    VALUES (p_org_id, r.device_id, 'delete_rental',
      jsonb_build_object('code', r.code, 'source', 'admin-global-delete'), 'queued', uid)
    RETURNING id INTO cid;
    INSERT INTO public.device_command_logs(command_id, org_id, device_id, status, result)
    VALUES (cid, p_org_id, r.device_id, 'queued',
      jsonb_build_object('source', 'admin-global-delete', 'rental_account_id', r.id, 'code', r.code));
  END IF;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (p_org_id, uid, 'admin_delete_rental_global', 'rental_account', r.id::text,
    jsonb_build_object('code', r.code, 'device_id', r.device_id, 'command_id', cid,
      'history_preserved', true, 'deleted_from_global_rental_list', true));

  DELETE FROM public.rental_accounts WHERE id = r.id AND org_id = p_org_id;
  RETURN jsonb_build_object('ok', true, 'id', r.id, 'org_id', p_org_id, 'code', r.code,
    'device_id', r.device_id, 'command_id', cid, 'history_preserved', true);
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_device_state(p_org_id uuid, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare d public.devices%rowtype; s public.rental_sessions%rowtype; online boolean; m jsonb;
begin
 if auth.uid() is null or not exists(select 1 from public.admin_accounts a where a.auth_user_id=auth.uid() and a.status='active' and (a.role='SUPER_ADMIN' or a.org_id=p_org_id)) then raise exception 'ADMIN_ACCESS_DENIED'; end if;
 select * into d from public.devices where id=p_device_id and org_id=p_org_id;
 if not found then raise exception 'DEVICE_NOT_FOUND'; end if;
 online:=d.status='online' and d.last_heartbeat_at is not null and d.last_heartbeat_at>=now()-interval '45 seconds';
 select * into s from public.rental_sessions where device_id=d.id and status in ('active','paused') order by started_at desc limit 1;
 m:=coalesce(d.metadata,'{}'::jsonb);
 return jsonb_build_object('online',online,'pairingConnected',online,'mode',
 case when not online then 'OFFLINE' when s.status='active' then 'RENTAL_ACTIVE' when s.status='paused' then 'RENTAL_PAUSED' else 'STANDBY' end,
 'session',case when s.id is null then null else jsonb_build_object('id',s.id,'code',s.code,'status',s.status,'session_type',s.session_type,'deadline_at',s.deadline_at,'remaining_seconds',greatest(0,extract(epoch from (s.deadline_at-now()))::bigint),'client_label',m->>'activeClientLabel','category',m->>'activeCategory','expiry_at',m->>'activeExpiryDate') end,
 'device',jsonb_build_object('id',d.id,'name',d.device_name,'client_id',d.client_id,'power_state',d.power_state,'last_heartbeat_at',d.last_heartbeat_at));
end $function$;

CREATE OR REPLACE FUNCTION api.admin_devices(p_org_id uuid)
 RETURNS SETOF devices
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
begin
 update public.devices set status='offline',power_state=case when power_state='online' then 'unknown' else power_state end
 where org_id=p_org_id and status='online' and (coalesce(last_heartbeat_at,last_seen_at) is null or coalesce(last_heartbeat_at,last_seen_at)<now()-interval '45 seconds');
 return query select d.* from public.devices d where d.org_id=p_org_id and private.admin_can_access_device(d.id,p_org_id) order by d.device_name,d.client_id;
end $function$;

CREATE OR REPLACE FUNCTION api.admin_disable_rental_global(p_org_id uuid, p_rental_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  uid uuid := auth.uid();
  r public.rental_accounts%ROWTYPE;
  v_lease_until timestamptz;
  v_lease_device_id uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (
       SELECT 1 FROM public.org_members m
       WHERE m.org_id=p_org_id AND m.auth_user_id=uid AND m.role='reseller_admin'
     ) THEN
    RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED';
  END IF;

  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id=p_rental_id AND org_id=p_org_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;

  IF EXISTS(
    SELECT 1 FROM public.rental_sessions s
    WHERE s.rental_account_id=r.id AND s.status IN ('active','paused')
  ) THEN
    RAISE EXCEPTION 'RENTAL_ACTIVE_TIMER_LOCKED';
  END IF;

  -- Keep a valid lease as a temporary anti-duplicate reservation. It must
  -- not prevent the admin from changing the master record's status.
  SELECT l.lease_until,l.device_id
    INTO v_lease_until,v_lease_device_id
  FROM public.rental_offline_leases l
  WHERE l.rental_account_id=r.id
  FOR UPDATE;

  UPDATE public.rental_accounts
  SET status='disabled',
      updated_at=now(),
      metadata=coalesce(metadata,'{}'::jsonb)
        || jsonb_build_object('source','admin-global-disable','adminEditedAt',now())
  WHERE id=r.id;

  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(
    p_org_id,uid,'admin_disable_rental_global','rental_account',r.id,
    jsonb_build_object(
      'code',r.code,
      'lease_preserved',v_lease_until>now(),
      'lease_until',v_lease_until,
      'lease_device_id',v_lease_device_id,
      'device_independent_edit',true
    )
  );

  RETURN jsonb_build_object(
    'ok',true,'id',r.id,'code',r.code,'status','disabled',
    'lease_preserved',v_lease_until>now(),
    'lease_until',v_lease_until,
    'lease_device_id',v_lease_device_id
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_disconnect_device(p_org_id uuid, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare n integer:=0;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 if not exists(select 1 from public.admin_accounts a where a.auth_user_id=auth.uid() and a.status='active' and (a.role='SUPER_ADMIN' or a.org_id=p_org_id)) then raise exception 'ADMIN_ACCESS_DENIED'; end if;
 if not exists(select 1 from public.devices where id=p_device_id and org_id=p_org_id) then raise exception 'DEVICE_NOT_FOUND'; end if;
 update public.device_tokens set revoked_at=now() where device_id=p_device_id and revoked_at is null;
 get diagnostics n=row_count;
 update public.devices set status='offline',power_state='unknown',metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('pairingDisconnectedAt',now()) where id=p_device_id and org_id=p_org_id;
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(p_org_id,auth.uid(),'device_pairing_disconnected','device',p_device_id::text,jsonb_build_object('revoked_tokens',n));
 return jsonb_build_object('ok',true,'device_id',p_device_id,'revoked_tokens',n);
end $function$;

CREATE OR REPLACE FUNCTION api.admin_get_free_test_policy()
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
  WHERE feature_key = 'free_test_10m_enabled';

  RETURN jsonb_build_object(
    'enabled', COALESCE(setting_row.enabled, false),
    'contact_phone', '082298316902',
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_recent_alerts(p_org_id uuid, p_since timestamp with time zone DEFAULT (now() - '00:02:00'::interval))
 RETURNS TABLE(id uuid, device_id uuid, device_name text, client_id text, source_event_id text, event_type text, message text, payload jsonb, occurred_at timestamp with time zone, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  uid uuid := auth.uid();
  since_at timestamptz := greatest(coalesce(p_since, now() - interval '2 minutes'), now() - interval '24 hours');
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_org_id IS NULL THEN RAISE EXCEPTION 'ORG_ID_REQUIRED'; END IF;
  IF NOT private.is_owner_access(p_org_id) THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;

  RETURN QUERY
    SELECT e.id, e.device_id, coalesce(d.device_name, d.client_id, 'PC')::text,
           d.client_id::text, e.source_event_id, e.event_type, e.message,
           e.payload, e.occurred_at, e.created_at
    FROM public.admin_alert_events e
    JOIN public.devices d ON d.id = e.device_id AND d.org_id = e.org_id
    WHERE e.org_id = p_org_id AND e.created_at >= since_at
    ORDER BY e.created_at ASC
    LIMIT 100;
END
$function$;

CREATE OR REPLACE FUNCTION api.admin_rename_device(p_org_id uuid, p_device_id uuid, p_device_name text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  a public.admin_accounts%rowtype;
  d public.devices%rowtype;
  nm text := trim(p_device_name);
begin
  select * into a
  from public.admin_accounts
  where auth_user_id = auth.uid() and status = 'active'
  limit 1;
  if not found then raise exception 'ADMIN_ACCOUNT_NOT_CONFIGURED'; end if;
  if a.role <> 'SUPER_ADMIN' and a.org_id is distinct from p_org_id then
    raise exception 'ORG_ACCESS_DENIED';
  end if;
  if nm = '' then raise exception 'DEVICE_NAME_REQUIRED'; end if;
  select * into d from public.devices where id = p_device_id and org_id = p_org_id for update;
  if not found then raise exception 'DEVICE_NOT_FOUND'; end if;
  update public.devices
  set device_name = nm,
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('custom_device_name', nm)
  where id = d.id;
  insert into public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  values (p_org_id, auth.uid(), 'rename_device', 'device', d.id,
          jsonb_build_object('old_name', d.device_name, 'new_name', nm));
  return jsonb_build_object('ok', true, 'device_id', d.id, 'device_name', nm,
                            'client_id_unchanged', true, 'pairing_token_unchanged', true);
end
$function$;

CREATE OR REPLACE FUNCTION api.admin_rental_accounts(p_org_id uuid, p_device_id uuid)
 RETURNS SETOF rental_accounts
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
 select r.* from public.rental_accounts r where r.org_id=p_org_id and r.device_id=p_device_id and private.admin_can_access_device(r.device_id,p_org_id) order by r.code;
$function$;

CREATE OR REPLACE FUNCTION api.admin_rental_accounts_global(p_org_id uuid)
 RETURNS SETOF rental_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
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

CREATE OR REPLACE FUNCTION api.admin_selected_sessions(p_org_id uuid, p_device_id uuid)
 RETURNS SETOF rental_sessions
 LANGUAGE sql
 SECURITY DEFINER
 SET search_path TO 'public'
AS $function$ select rs.* from public.rental_sessions rs where rs.org_id=p_org_id and rs.device_id=p_device_id and rs.status in ('active','paused') and exists(select 1 from public.admin_accounts a where a.auth_user_id=auth.uid() and a.status='active' and (a.role='SUPER_ADMIN' or a.org_id=p_org_id)); $function$;

CREATE OR REPLACE FUNCTION api.admin_set_free_test_policy(p_enabled boolean)
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
$function$;

CREATE OR REPLACE FUNCTION api.admin_start_trial(p_org_id uuid, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.admin_accounts%rowtype; d public.devices%rowtype; rid uuid; cid uuid;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into a from public.admin_accounts where auth_user_id=auth.uid() and status='active' limit 1;
 if not found then raise exception 'ADMIN_ACCOUNT_NOT_CONFIGURED'; end if;
 if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if;
 select * into d from public.devices where id=p_device_id and org_id=p_org_id for update;
 if not found or not private.admin_can_access_device(p_device_id,p_org_id) then raise exception 'DEVICE_ACCESS_DENIED'; end if;
 if d.status<>'online' or coalesce(d.last_heartbeat_at,d.last_seen_at) is null or coalesce(d.last_heartbeat_at,d.last_seen_at)<now()-interval '45 seconds' then raise exception 'PC_OFFLINE_COMMAND_BLOCKED'; end if;
 if coalesce(d.metadata->>'activeCode','')<>'' or coalesce(d.metadata->>'pausedCode','')<>'' then raise exception 'SESSION_ALREADY_ACTIVE'; end if;
 if exists(select 1 from public.rental_sessions rs where rs.device_id=p_device_id and rs.status in ('active','paused')) then raise exception 'SESSION_ALREADY_ACTIVE'; end if;
 insert into public.device_trial_requests(org_id,device_id,created_by) values(p_org_id,p_device_id,auth.uid()) returning id into rid;
 insert into public.device_commands(org_id,device_id,command,payload,status,created_by) values(p_org_id,p_device_id,'start_trial',jsonb_build_object('trial_request_id',rid),'queued',auth.uid()) returning id into cid;
 update public.device_trial_requests set command_id=cid where id=rid;
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(p_org_id,auth.uid(),'start_trial_requested','device',p_device_id::text,jsonb_build_object('trial_request_id',rid,'command_id',cid));
 return jsonb_build_object('ok',true,'trial_request_id',rid,'command_id',cid,'duration_seconds',600);
exception when unique_violation then raise exception 'SESSION_ALREADY_ACTIVE';
end; $function$;

CREATE OR REPLACE FUNCTION api.admin_update_rental_global(p_org_id uuid, p_rental_id uuid, p_code text, p_category text, p_minutes bigint, p_client_label text, p_expiry_at timestamp with time zone, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  uid uuid := auth.uid();
  initial_account_id uuid;
  r public.rental_accounts%ROWTYPE;
  active_session public.rental_sessions%ROWTYPE;
  target_device public.devices%ROWTYPE;
  c text := UPPER(TRIM(COALESCE(p_code, '')));
  cat text := COALESCE(NULLIF(TRIM(p_category), ''), 'reguler');
  st text := COALESCE(p_status, '');
  secs bigint;
  expiry timestamptz := p_expiry_at;
  active_row boolean := false;
  effective_remaining bigint := 0;
  pending_add_seconds bigint := 0;
  added_seconds bigint := 0;
  time_command_id uuid;
  v_lease_until timestamptz;
  v_lease_device_id uuid;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  IF NOT COALESCE(private.is_owner_access(p_org_id), false)
     AND NOT EXISTS (SELECT 1 FROM public.org_members m
       WHERE m.org_id=p_org_id AND m.auth_user_id=uid AND m.role='reseller_admin')
  THEN RAISE EXCEPTION 'ADMIN_ORG_ACCESS_DENIED'; END IF;
  IF p_rental_id IS NULL OR c='' OR LENGTH(c)>120 OR c='__TEST10__' THEN
    RAISE EXCEPTION 'RENTAL_FIELDS_INVALID';
  END IF;
  IF p_minutes IS NULL OR p_minutes<0 OR p_minutes>525600 THEN RAISE EXCEPTION 'RENTAL_MINUTES_INVALID'; END IF;
  IF cat NOT IN ('reguler','mingguan','bulanan','hemat','sultan','mega hemat') THEN RAISE EXCEPTION 'RENTAL_CATEGORY_INVALID'; END IF;
  IF st NOT IN ('active','expired','disabled') THEN RAISE EXCEPTION 'RENTAL_STATUS_INVALID'; END IF;

  secs := p_minutes*60;
  IF secs=0 AND st='active' THEN st:='expired'; END IF;

  SELECT id INTO initial_account_id FROM public.rental_accounts WHERE id=p_rental_id AND org_id=p_org_id;
  IF initial_account_id IS NULL THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(p_org_id::text||':'||c,0));

  SELECT * INTO active_session FROM public.rental_sessions s
  WHERE s.rental_account_id=p_rental_id AND s.status IN ('active','paused')
  ORDER BY s.started_at DESC,s.id DESC LIMIT 1 FOR UPDATE;
  active_row := FOUND;

  SELECT * INTO r FROM public.rental_accounts WHERE id=p_rental_id AND org_id=p_org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF EXISTS (SELECT 1 FROM public.rental_accounts x
    WHERE x.org_id=p_org_id AND UPPER(TRIM(x.code))=c AND x.id<>r.id)
  THEN RAISE EXCEPTION 'CODE_ALREADY_EXISTS'; END IF;

  IF active_row THEN
    IF active_session.last_client_at IS NULL THEN RAISE EXCEPTION 'RENTAL_ACTIVE_SESSION_STATE_UNAVAILABLE'; END IF;
    IF c<>UPPER(TRIM(r.code)) THEN RAISE EXCEPTION 'RENTAL_ACTIVE_CODE_LOCKED'; END IF;
    IF expiry IS DISTINCT FROM r.expiry_at THEN RAISE EXCEPTION 'RENTAL_ACTIVE_EXPIRY_LOCKED'; END IF;
    IF st<>'active' THEN RAISE EXCEPTION 'RENTAL_ACTIVE_STATUS_LOCKED'; END IF;

    SELECT COALESCE(SUM(GREATEST(0,COALESCE((dc.payload->>'seconds')::bigint,0))),0)
      INTO pending_add_seconds
    FROM public.device_commands dc
    WHERE dc.device_id=active_session.device_id
      AND dc.command='add_time'
      AND dc.payload->>'sessionId'=active_session.id::text
      AND (dc.status IN ('queued','acknowledged')
        OR (dc.status='completed' AND dc.completed_at>active_session.last_client_at));

    effective_remaining := GREATEST(0,
      COALESCE(active_session.last_client_remaining_seconds,r.remaining_seconds,0)
      - GREATEST(0,FLOOR(EXTRACT(EPOCH FROM (NOW()-active_session.last_client_at)))::bigint)
      + pending_add_seconds);

    IF p_minutes=FLOOR(r.remaining_seconds/60.0)::bigint THEN
      secs := effective_remaining;
    ELSE
      secs := p_minutes*60;
    END IF;
    IF secs<effective_remaining THEN RAISE EXCEPTION 'RENTAL_ACTIVE_TIME_REDUCTION_BLOCKED'; END IF;

    added_seconds := secs-effective_remaining;
    IF added_seconds>0 THEN
      IF active_session.status='paused' THEN RAISE EXCEPTION 'RENTAL_PAUSED_TIME_EDIT_UNSUPPORTED'; END IF;
      IF active_session.device_id IS NULL THEN RAISE EXCEPTION 'RENTAL_ACTIVE_DEVICE_UNAVAILABLE'; END IF;
      SELECT * INTO target_device FROM public.devices d
      WHERE d.id=active_session.device_id AND d.org_id=p_org_id;
      IF NOT FOUND OR target_device.status<>'online'
         OR COALESCE(target_device.last_heartbeat_at,target_device.last_seen_at) IS NULL
         OR COALESCE(target_device.last_heartbeat_at,target_device.last_seen_at)<NOW()-INTERVAL '45 seconds'
      THEN RAISE EXCEPTION 'RENTAL_ACTIVE_DEVICE_OFFLINE'; END IF;

      INSERT INTO public.device_commands(org_id,device_id,command,payload,status,created_by)
      VALUES(p_org_id,active_session.device_id,'add_time',
        JSONB_BUILD_OBJECT('seconds',added_seconds,'code',r.code,'source','admin-global-active-edit',
          'rentalAccountId',r.id,'sessionId',active_session.id),'queued',uid)
      RETURNING id INTO time_command_id;
    END IF;

    UPDATE public.rental_accounts SET category=cat,
      client_label=NULLIF(TRIM(p_client_label),''),updated_at=NOW(),
      metadata=COALESCE(metadata,'{}'::jsonb)||JSONB_BUILD_OBJECT('source','admin-global-edit','adminEditedAt',NOW())
    WHERE id=r.id;
  ELSE
    IF expiry IS NOT NULL AND expiry<=NOW() THEN RAISE EXCEPTION 'EXPIRY_MUST_BE_FUTURE'; END IF;
    UPDATE public.rental_accounts SET code=c,category=cat,remaining_seconds=secs,expiry_at=expiry,
      client_label=NULLIF(TRIM(p_client_label),''),status=st,updated_at=NOW(),
      metadata=COALESCE(metadata,'{}'::jsonb)||JSONB_BUILD_OBJECT('source','admin-global-edit','adminEditedAt',NOW())
    WHERE id=r.id;
  END IF;

  SELECT l.lease_until,l.device_id INTO v_lease_until,v_lease_device_id
  FROM public.rental_offline_leases l WHERE l.rental_account_id=r.id FOR UPDATE;

  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(p_org_id,uid,'admin_update_rental_global','rental_account',r.id,
    JSONB_BUILD_OBJECT('old_code',r.code,'new_code',c,'old_minutes',FLOOR(r.remaining_seconds/60.0),
      'new_minutes',p_minutes,'old_status',r.status,'new_status',CASE WHEN active_row THEN r.status ELSE st END,
      'active_session',active_row,'seconds_added',added_seconds,'pending_add_seconds',pending_add_seconds,
      'time_command_id',time_command_id,'lease_preserved',v_lease_until>NOW(),
      'lease_until',v_lease_until,'lease_device_id',v_lease_device_id,'device_independent_edit',true));

  RETURN JSONB_BUILD_OBJECT('ok',true,'id',r.id,'org_id',p_org_id,
    'code',CASE WHEN active_row THEN r.code ELSE c END,'category',cat,'remaining_seconds',secs,
    'expiry_at',CASE WHEN active_row THEN r.expiry_at ELSE expiry END,
    'status',CASE WHEN active_row THEN r.status ELSE st END,'device_id',r.device_id,
    'active_session',active_row,'time_command_queued',time_command_id IS NOT NULL,
    'time_command_id',time_command_id,'seconds_added',added_seconds,'pending_add_seconds',pending_add_seconds,
    'lease_preserved',v_lease_until>NOW(),'lease_until',v_lease_until,'lease_device_id',v_lease_device_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.create_device_recovery_enrollment(p_device_id uuid, p_minutes bigint DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  uid uuid := auth.uid();
  d public.devices%ROWTYPE;
  raw text;
  code_hash text;
  enrollment_id uuid;
  expires timestamptz;
  mins bigint;
BEGIN
  IF uid IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_device_id IS NULL THEN RAISE EXCEPTION 'DEVICE_ID_REQUIRED'; END IF;

  SELECT * INTO d
  FROM public.devices
  WHERE id = p_device_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RECOVERY_DEVICE_NOT_FOUND'; END IF;
  IF NOT private.is_owner_access(d.org_id) THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;
  IF coalesce(d.metadata, '{}'::jsonb) ? 'pairingDuplicateArchivedAt' THEN
    RAISE EXCEPTION 'RECOVERY_TARGET_ARCHIVED';
  END IF;

  raw := upper(substr(md5(random()::text || clock_timestamp()::text || uid::text || d.id::text), 1, 8));
  code_hash := encode(extensions.digest(raw, 'sha256'), 'hex');
  mins := greatest(1::bigint, least(coalesce(p_minutes, 30::bigint), 1440::bigint));
  expires := now() + (mins * interval '1 minute');

  -- Target UUID is encoded in the internal label. redeem_device enforces it server-side.
  INSERT INTO public.device_enrollments(org_id, code_hash, label, expires_at)
  VALUES (d.org_id, code_hash, '__RECOVERY__:' || d.id::text || ':' || coalesce(d.client_id, ''), expires)
  RETURNING id INTO enrollment_id;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (
    d.org_id, uid, 'create_device_recovery_enrollment', 'device', d.id::text,
    jsonb_build_object('enrollment_id', enrollment_id, 'target_client_id', d.client_id, 'expires_at', expires)
  );

  RETURN jsonb_build_object(
    'id', enrollment_id,
    'code', raw,
    'expires_at', expires,
    'target_device_id', d.id,
    'target_client_id', d.client_id
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.report_rental_period_breakdown(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_combined jsonb := '[]'::jsonb;
  v_per_pc jsonb := '[]'::jsonb;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;
  IF p_org_id IS NULL OR NOT private.user_has_org_access(p_org_id) THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN
    RAISE EXCEPTION 'INVALID_REPORT_RANGE';
  END IF;
  IF p_to - p_from > interval '740 days' THEN
    RAISE EXCEPTION 'REPORT_RANGE_TOO_LARGE';
  END IF;

  WITH month_ranges AS (
    SELECT gs::date AS month_start,
           (gs + interval '1 month')::date AS next_month_start
    FROM generate_series(
      date_trunc('month', p_from AT TIME ZONE 'Asia/Jakarta'),
      date_trunc('month', (p_to - interval '1 microsecond') AT TIME ZONE 'Asia/Jakarta'),
      interval '1 month'
    ) AS gs
  ),
  sessions_by_month AS MATERIALIZED (
    SELECT
      to_char(m.month_start, 'YYYY-MM') AS month_key,
      COALESCE(ra.id::text, 'legacy:' || upper(COALESCE(ra.code, s.code, '-'))) AS member_key,
      COALESCE(ra.code, s.code, '-') AS rental_id,
      COALESCE(
        NULLIF(BTRIM(ra.client_label), ''),
        NULLIF(BTRIM(s.metadata->>'clientLabel'), ''),
        '-'
      ) AS rental_name,
      COALESCE(s.device_id::text, 'unknown') AS pc_key,
      COALESCE(
        NULLIF(BTRIM(d.device_name), ''),
        NULLIF(BTRIM(d.client_id), ''),
        'PC tidak diketahui'
      ) AS pc_name,
      CASE
        WHEN lower(COALESCE(s.status, '')) = 'paused' THEN 0::bigint
        ELSE GREATEST(
          0,
          FLOOR(EXTRACT(EPOCH FROM (
            LEAST(
              COALESCE(s.ended_at, s.deadline_at, now()),
              p_to,
              now(),
              (m.next_month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
            )
            -
            GREATEST(
              s.started_at,
              p_from,
              (m.month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
            )
          )))::bigint
        )
      END AS played_seconds
    FROM month_ranges m
    JOIN public.rental_sessions s
      ON s.started_at < LEAST(
           p_to,
           (m.next_month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
         )
     AND COALESCE(s.ended_at, s.deadline_at, now()) > GREATEST(
           p_from,
           (m.month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
         )
    LEFT JOIN public.rental_accounts ra ON ra.id = s.rental_account_id
    LEFT JOIN public.devices d ON d.id = s.device_id
    WHERE s.org_id = p_org_id
      AND COALESCE(s.session_type, 'rental') <> 'free_test'
  ),
  combined AS (
    SELECT
      month_key, member_key,
      MAX(rental_id) AS rental_id,
      MAX(rental_name) AS rental_name,
      SUM(played_seconds)::bigint AS total_play_seconds,
      COUNT(*)::bigint AS total_sessions
    FROM sessions_by_month
    GROUP BY month_key, member_key
  ),
  per_pc AS (
    SELECT
      month_key, pc_key, member_key,
      MAX(pc_name) AS pc_name,
      MAX(rental_id) AS rental_id,
      MAX(rental_name) AS rental_name,
      SUM(played_seconds)::bigint AS total_play_seconds,
      COUNT(*)::bigint AS total_sessions
    FROM sessions_by_month
    GROUP BY month_key, pc_key, member_key
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'month', month_key,
        'member_key', member_key,
        'rental_id', rental_id,
        'rental_name', rental_name,
        'total_play_seconds', total_play_seconds,
        'total_sessions', total_sessions
      )
      ORDER BY month_key, total_play_seconds DESC, total_sessions DESC, rental_id
    ),
    '[]'::jsonb
  )
  INTO v_combined
  FROM combined;

  WITH month_ranges AS (
    SELECT gs::date AS month_start,
           (gs + interval '1 month')::date AS next_month_start
    FROM generate_series(
      date_trunc('month', p_from AT TIME ZONE 'Asia/Jakarta'),
      date_trunc('month', (p_to - interval '1 microsecond') AT TIME ZONE 'Asia/Jakarta'),
      interval '1 month'
    ) AS gs
  ),
  sessions_by_month AS MATERIALIZED (
    SELECT
      to_char(m.month_start, 'YYYY-MM') AS month_key,
      COALESCE(ra.id::text, 'legacy:' || upper(COALESCE(ra.code, s.code, '-'))) AS member_key,
      COALESCE(ra.code, s.code, '-') AS rental_id,
      COALESCE(
        NULLIF(BTRIM(ra.client_label), ''),
        NULLIF(BTRIM(s.metadata->>'clientLabel'), ''),
        '-'
      ) AS rental_name,
      COALESCE(s.device_id::text, 'unknown') AS pc_key,
      COALESCE(
        NULLIF(BTRIM(d.device_name), ''),
        NULLIF(BTRIM(d.client_id), ''),
        'PC tidak diketahui'
      ) AS pc_name,
      CASE
        WHEN lower(COALESCE(s.status, '')) = 'paused' THEN 0::bigint
        ELSE GREATEST(
          0,
          FLOOR(EXTRACT(EPOCH FROM (
            LEAST(
              COALESCE(s.ended_at, s.deadline_at, now()),
              p_to,
              now(),
              (m.next_month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
            )
            -
            GREATEST(
              s.started_at,
              p_from,
              (m.month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
            )
          )))::bigint
        )
      END AS played_seconds
    FROM month_ranges m
    JOIN public.rental_sessions s
      ON s.started_at < LEAST(
           p_to,
           (m.next_month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
         )
     AND COALESCE(s.ended_at, s.deadline_at, now()) > GREATEST(
           p_from,
           (m.month_start::timestamp AT TIME ZONE 'Asia/Jakarta')
         )
    LEFT JOIN public.rental_accounts ra ON ra.id = s.rental_account_id
    LEFT JOIN public.devices d ON d.id = s.device_id
    WHERE s.org_id = p_org_id
      AND COALESCE(s.session_type, 'rental') <> 'free_test'
  ),
  per_pc AS (
    SELECT
      month_key, pc_key, member_key,
      MAX(pc_name) AS pc_name,
      MAX(rental_id) AS rental_id,
      MAX(rental_name) AS rental_name,
      SUM(played_seconds)::bigint AS total_play_seconds,
      COUNT(*)::bigint AS total_sessions
    FROM sessions_by_month
    GROUP BY month_key, pc_key, member_key
  )
  SELECT COALESCE(
    jsonb_agg(
      jsonb_build_object(
        'month', month_key,
        'pc_id', pc_key,
        'pc_name', pc_name,
        'member_key', member_key,
        'rental_id', rental_id,
        'rental_name', rental_name,
        'total_play_seconds', total_play_seconds,
        'total_sessions', total_sessions
      )
      ORDER BY month_key, pc_name, total_play_seconds DESC, total_sessions DESC, rental_id
    ),
    '[]'::jsonb
  )
  INTO v_per_pc
  FROM per_pc;

  RETURN jsonb_build_object(
    'timezone', 'Asia/Jakarta',
    'from', p_from,
    'to', p_to,
    'combined_rows', v_combined,
    'pc_rows', v_per_pc
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_login_lookup(p_login text)
RETURNS TABLE(email text,role text,status text)
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'pg_catalog','public','auth'
AS $function$
  SELECT u.email,a.role,a.status
  FROM public.admin_accounts a
  JOIN auth.users u ON u.id=a.auth_user_id
  WHERE p_login IS NOT NULL
    AND length(trim(p_login)) BETWEEN 1 AND 120
    AND a.status='active'
    AND a.role='SUPER_ADMIN'
    AND (
      lower(trim(a.username))=lower(trim(p_login))
      OR lower(trim(u.email))=lower(trim(p_login))
    )
  ORDER BY CASE WHEN lower(trim(a.username))=lower(trim(p_login)) THEN 0 ELSE 1 END
  LIMIT 1;
$function$;

CREATE OR REPLACE FUNCTION api.create_enrollment(p_org_id uuid, p_label text, p_minutes bigint DEFAULT 30)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  uid uuid := auth.uid();
  raw text;
  hash text;
  eid uuid;
  exp timestamptz;
  mins bigint;
begin
  if uid is null then raise exception 'AUTH_REQUIRED'; end if;
  if not private.is_owner_access(p_org_id) then raise exception 'OWNER_ONLY'; end if;

  raw := upper(substr(md5(random()::text || clock_timestamp()::text || uid::text), 1, 8));
  hash := encode(extensions.digest(raw, 'sha256'), 'hex');

  mins := greatest(1::bigint, least(coalesce(p_minutes,30::bigint), 1440::bigint));
  exp := now() + (mins * interval '1 minute');

  insert into public.device_enrollments(org_id,code_hash,label,expires_at)
  values(p_org_id,hash,coalesce(nullif(trim(p_label),''),'PC'),exp)
  returning id into eid;

  insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  values(p_org_id,uid,'create_device_enrollment','device_enrollment',eid,
         jsonb_build_object('label',p_label));

  return jsonb_build_object('id',eid,'code',raw,'expires_at',exp);
end
$function$;

CREATE OR REPLACE FUNCTION api.create_reseller(p_name text, p_slug text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare uid uuid:=auth.uid(); parent_id uuid; org_id uuid; clean_slug text:=lower(regexp_replace(coalesce(nullif(trim(p_slug),''),trim(p_name)),'[^a-zA-Z0-9]+','-','g'));
begin
 if uid is null then raise exception 'AUTH_REQUIRED'; end if;
 select om.org_id into parent_id from public.org_members om join public.organizations o on o.id=om.org_id where om.auth_user_id=uid and om.role='owner' and o.kind='owner' order by om.created_at limit 1;
 if parent_id is null then raise exception 'OWNER_REQUIRED'; end if;
 insert into public.organizations(parent_org_id,name,slug,kind) values(parent_id,coalesce(nullif(trim(p_name),''),'Reseller'),clean_slug,'reseller') returning id into org_id;
 insert into public.org_members(org_id,auth_user_id,role) values(org_id,uid,'owner');
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(org_id,uid,'create_reseller','organization',org_id,jsonb_build_object('name',p_name));
 return jsonb_build_object('org_id',org_id,'parent_org_id',parent_id,'name',p_name,'slug',clean_slug);
end $function$;

CREATE OR REPLACE FUNCTION api.dashboard_billing_user(p_action text, p_username text, p_password text DEFAULT NULL::text, p_status text DEFAULT 'active'::text, p_role text DEFAULT 'RESELLER_ADMIN'::text, p_org_id uuid DEFAULT NULL::uuid, p_display_name text DEFAULT NULL::text, p_user_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$ declare me public.admin_accounts%rowtype; b public.billing_control_accounts%rowtype; uname text:=lower(trim(coalesce(p_username,''))); begin select * into me from public.admin_accounts where auth_user_id=auth.uid() and role='SUPER_ADMIN' and status='active' limit 1; if not found then raise exception 'SUPER_ADMIN_REQUIRED'; end if; if p_action <> 'delete' and uname='' then raise exception 'USERNAME_REQUIRED'; end if; if p_action <> 'delete' and p_role not in ('SUPER_ADMIN','RESELLER_ADMIN') then raise exception 'INVALID_ROLE'; end if; if p_action <> 'delete' and p_status not in ('active','disabled') then raise exception 'INVALID_STATUS'; end if; if p_action='create' then if length(coalesce(p_password,''))<8 then raise exception 'PASSWORD_TOO_SHORT'; end if; if exists(select 1 from public.billing_control_accounts where lower(username)=uname) then raise exception 'USERNAME_EXISTS'; end if; insert into public.billing_control_accounts(auth_user_id,username,role,org_id,status,display_name,must_change_password,password_hash) values(null,uname,p_role,coalesce(p_org_id,me.org_id),p_status,nullif(trim(p_display_name),''),true,extensions.crypt(p_password,extensions.gen_salt('bf'))) returning * into b; elsif p_action='update' then select * into b from public.billing_control_accounts where id=p_user_id for update; if not found then raise exception 'BILLING_ACCOUNT_NOT_FOUND'; end if; if exists(select 1 from public.billing_control_accounts where lower(username)=uname and id<>b.id) then raise exception 'USERNAME_EXISTS'; end if; update public.billing_control_accounts set username=uname,role=p_role,org_id=coalesce(p_org_id,org_id),status=p_status,display_name=nullif(trim(p_display_name),''),updated_at=now() where id=b.id; if p_password is not null and p_password<>'' then if length(p_password)<8 then raise exception 'PASSWORD_TOO_SHORT'; end if; update public.billing_control_accounts set password_hash=extensions.crypt(p_password,extensions.gen_salt('bf')),must_change_password=true,failed_attempts=0,locked_until=null where id=b.id; update public.billing_control_sessions set revoked_at=now() where billing_account_id=b.id and revoked_at is null; end if; if p_status='disabled' then update public.billing_control_sessions set revoked_at=now() where billing_account_id=b.id and revoked_at is null; end if; select * into b from public.billing_control_accounts where id=b.id; elsif p_action='delete' then select * into b from public.billing_control_accounts where id=p_user_id for update; if not found then raise exception 'BILLING_ACCOUNT_NOT_FOUND'; end if; update public.billing_control_sessions set revoked_at=now() where billing_account_id=b.id and revoked_at is null; delete from public.billing_control_accounts where id=b.id; insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(coalesce(b.org_id,me.org_id),auth.uid(),'billing_user_admin_delete','billing_control_account',b.id,jsonb_build_object('action','delete','username',b.username,'role',b.role,'status',b.status)); return jsonb_build_object('ok',true,'deleted',true,'id',b.id,'username',b.username); else raise exception 'UNKNOWN_ACTION'; end if; insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(coalesce(b.org_id,me.org_id),auth.uid(),'billing_user_admin_action','billing_control_account',b.id,jsonb_build_object('action',p_action,'username',b.username,'role',b.role,'status',b.status)); return jsonb_build_object('ok',true,'id',b.id,'username',b.username,'role',b.role,'org_id',b.org_id,'status',b.status); end $function$;

CREATE OR REPLACE FUNCTION api.dashboard_billing_users()
 RETURNS TABLE(id uuid, username text, role text, org_id uuid, org_name text, status text, display_name text, must_change_password boolean, last_login_at timestamp with time zone, created_at timestamp with time zone)
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  me public.admin_accounts%rowtype;
begin
  select a.* into me
  from public.admin_accounts as a
  where a.auth_user_id = auth.uid()
    and a.role = 'SUPER_ADMIN'
    and a.status = 'active'
  limit 1;

  if not found then
    raise exception 'SUPER_ADMIN_REQUIRED';
  end if;

  return query
  select
    b.id,
    b.username,
    b.role,
    b.org_id,
    o.name as org_name,
    b.status,
    b.display_name,
    b.must_change_password,
    b.last_login_at,
    b.created_at
  from public.billing_control_accounts as b
  left join public.organizations as o on o.id = b.org_id
  order by b.username;
end
$function$;

CREATE OR REPLACE FUNCTION api.report_detailed_usage_page(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone, p_limit integer DEFAULT 200, p_before_started_at timestamp with time zone DEFAULT NULL::timestamp with time zone, p_before_session_id uuid DEFAULT NULL::uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE v_limit integer:=least(greatest(coalesce(p_limit,200),1),500); v_rows jsonb:='[]'::jsonb; v_has_more boolean:=false; v_next_started_at timestamptz; v_next_session_id uuid;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
 IF NOT private.user_has_org_access(p_org_id) THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
 IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from THEN RAISE EXCEPTION 'INVALID_REPORT_RANGE'; END IF;
 IF (p_before_started_at IS NULL)<>(p_before_session_id IS NULL) THEN RAISE EXCEPTION 'INVALID_REPORT_CURSOR'; END IF;
 WITH candidates AS MATERIALIZED (
  SELECT rs.id,rs.rental_account_id,rs.device_id,rs.code,rs.started_at,rs.deadline_at,rs.ended_at,rs.status
  FROM public.rental_sessions rs
  WHERE rs.org_id=p_org_id AND rs.started_at<p_to AND coalesce(rs.ended_at,rs.deadline_at,now())>p_from
   AND (p_before_started_at IS NULL OR rs.started_at<p_before_started_at OR (rs.started_at=p_before_started_at AND rs.id<p_before_session_id))
  ORDER BY rs.started_at DESC,rs.id DESC LIMIT (v_limit+1)
 ), page AS MATERIALIZED (SELECT * FROM candidates ORDER BY started_at DESC,id DESC LIMIT v_limit)
 SELECT coalesce((SELECT jsonb_agg(jsonb_build_object(
   'session_id',p.id,'code',coalesce(ra.code,p.code,'-'),'pc_name',coalesce(d.device_name,d.client_id,'-'),
   'play_date',(p.started_at AT TIME ZONE 'Asia/Jakarta')::date,
   'started_at',p.started_at,'ended_at',p.ended_at,'deadline_at',p.deadline_at,'status',p.status,
   'seconds_played',CASE WHEN lower(p.status)='paused' THEN 0::bigint ELSE greatest(0,floor(extract(epoch FROM (least(coalesce(p.ended_at,p.deadline_at,now()),p_to,now())-greatest(p.started_at,p_from)))))::bigint END
  ) ORDER BY p.started_at DESC,p.id DESC)
  FROM page p LEFT JOIN public.rental_accounts ra ON ra.id=p.rental_account_id LEFT JOIN public.devices d ON d.id=p.device_id),'[]'::jsonb),
  (SELECT count(*)>v_limit FROM candidates),
  (SELECT p.started_at FROM page p ORDER BY p.started_at ASC,p.id ASC LIMIT 1),
  (SELECT p.id FROM page p ORDER BY p.started_at ASC,p.id ASC LIMIT 1)
 INTO v_rows,v_has_more,v_next_started_at,v_next_session_id;
 RETURN jsonb_build_object('rows',v_rows,'has_more',v_has_more,'next_cursor',CASE WHEN v_has_more AND v_next_started_at IS NOT NULL AND v_next_session_id IS NOT NULL THEN jsonb_build_object('started_at',v_next_started_at,'session_id',v_next_session_id) ELSE NULL END);
END; $function$;

CREATE OR REPLACE FUNCTION api.report_monthly_rental_summary(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_rows jsonb := '[]'::jsonb;
  v_daily jsonb := '[]'::jsonb;
  v_total_sessions bigint := 0;
  v_total_seconds bigint := 0;
  v_rental_count bigint := 0;
  v_from_date date;
  v_to_date date;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_org_id IS NULL OR NOT private.user_has_org_access(p_org_id) THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
  IF p_from IS NULL OR p_to IS NULL OR p_to <= p_from THEN RAISE EXCEPTION 'INVALID_REPORT_RANGE'; END IF;
  IF p_to - p_from > interval '32 days' THEN RAISE EXCEPTION 'MONTH_REPORT_RANGE_TOO_LARGE'; END IF;
  v_from_date := (p_from AT TIME ZONE 'Asia/Jakarta')::date;
  v_to_date := ((p_to - interval '1 microsecond') AT TIME ZONE 'Asia/Jakarta')::date;

  WITH sessions_in_month AS MATERIALIZED (
    SELECT s.id, s.rental_account_id,
      COALESCE(r.code, s.code, '-') AS rental_code,
      COALESCE(NULLIF(BTRIM(r.client_label), ''), NULLIF(BTRIM(s.metadata->>'clientLabel'), ''), '-') AS rental_name,
      s.started_at, s.ended_at, s.deadline_at, s.status,
      CASE WHEN LOWER(COALESCE(s.status, '')) = 'paused' THEN 0::bigint
        ELSE GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (
          LEAST(COALESCE(s.ended_at, s.deadline_at, NOW()), p_to, NOW())
          - GREATEST(s.started_at, p_from)
        )))::bigint) END AS played_seconds
    FROM public.rental_sessions s
    LEFT JOIN public.rental_accounts r ON r.id = s.rental_account_id
    WHERE s.org_id = p_org_id
      AND COALESCE(s.session_type, 'rental') <> 'free_test'
      AND s.started_at < p_to
      AND COALESCE(s.ended_at, s.deadline_at, NOW()) > p_from
  ), grouped AS (
    SELECT COALESCE(rental_account_id::text, 'legacy:' || UPPER(rental_code)) AS rental_key,
      MAX(rental_code) AS rental_id, MAX(rental_name) AS rental_name,
      SUM(played_seconds)::bigint AS total_play_seconds, COUNT(*)::bigint AS total_sessions
    FROM sessions_in_month
    GROUP BY COALESCE(rental_account_id::text, 'legacy:' || UPPER(rental_code))
  )
  SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
      'rental_id', rental_id, 'rental_name', rental_name,
      'total_play_seconds', total_play_seconds, 'total_sessions', total_sessions
    ) ORDER BY total_play_seconds DESC, rental_id), '[]'::jsonb),
    COALESCE(SUM(total_sessions), 0), COALESCE(SUM(total_play_seconds), 0), COUNT(*)
  INTO v_rows, v_total_sessions, v_total_seconds, v_rental_count FROM grouped;

  WITH days AS (
    SELECT gs::date AS day
    FROM GENERATE_SERIES(v_from_date::timestamp, v_to_date::timestamp, interval '1 day') gs
  ), daily AS (
    SELECT d.day,
      COUNT(s.id) FILTER (
        WHERE s.started_at >= (d.day::timestamp AT TIME ZONE 'Asia/Jakarta')
          AND s.started_at < ((d.day + 1)::timestamp AT TIME ZONE 'Asia/Jakarta')
      )::bigint AS sessions_started,
      COALESCE(SUM(
        CASE WHEN s.id IS NULL OR LOWER(COALESCE(s.status, '')) = 'paused' THEN 0::bigint
        ELSE GREATEST(0, FLOOR(EXTRACT(EPOCH FROM (
          LEAST(COALESCE(s.ended_at, s.deadline_at, NOW()), p_to, NOW(),
            ((d.day + 1)::timestamp AT TIME ZONE 'Asia/Jakarta'))
          - GREATEST(s.started_at, p_from, (d.day::timestamp AT TIME ZONE 'Asia/Jakarta'))
        )))::bigint) END
      ), 0)::bigint AS active_seconds
    FROM days d
    LEFT JOIN public.rental_sessions s
      ON s.org_id = p_org_id
     AND COALESCE(s.session_type, 'rental') <> 'free_test'
     AND s.started_at < ((d.day + 1)::timestamp AT TIME ZONE 'Asia/Jakarta')
     AND COALESCE(s.ended_at, s.deadline_at, NOW()) > (d.day::timestamp AT TIME ZONE 'Asia/Jakarta')
    GROUP BY d.day
  )
  SELECT COALESCE(JSONB_AGG(JSONB_BUILD_OBJECT(
      'date', day, 'sessions_started', sessions_started, 'active_seconds', active_seconds
    ) ORDER BY day), '[]'::jsonb)
  INTO v_daily FROM daily;

  RETURN JSONB_BUILD_OBJECT('from', p_from, 'to', p_to, 'timezone', 'Asia/Jakarta',
    'rental_count', v_rental_count, 'total_sessions', v_total_sessions,
    'total_play_seconds', v_total_seconds, 'rows', v_rows, 'daily', v_daily);
END;
$function$;

CREATE OR REPLACE FUNCTION api.report_summary_compact(p_org_id uuid, p_from timestamp with time zone, p_to timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE result jsonb;
BEGIN
 IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
 IF NOT private.user_has_org_access(p_org_id) THEN RAISE EXCEPTION 'ORG_ACCESS_DENIED'; END IF;
 IF p_from IS NULL OR p_to IS NULL OR p_to<=p_from THEN RAISE EXCEPTION 'INVALID_REPORT_RANGE'; END IF;
 SELECT jsonb_build_object(
  'sessions',(SELECT count(*) FROM public.rental_sessions WHERE org_id=p_org_id AND started_at<p_to AND coalesce(ended_at,deadline_at,now())>p_from),
  'active_sessions',(SELECT count(*) FROM public.rental_sessions WHERE org_id=p_org_id AND status='active'),
  'transactions',(SELECT count(*) FROM public.billing_transactions WHERE org_id=p_org_id AND occurred_at>=p_from AND occurred_at<p_to),
  'free_tests',(SELECT count(*) FROM public.rental_sessions WHERE org_id=p_org_id AND session_type='free_test' AND started_at<p_to AND coalesce(ended_at,deadline_at,now())>p_from)
 ) INTO result;
 RETURN result;
END; $function$;

CREATE OR REPLACE FUNCTION api.save_theme(p_org_id uuid, p_name text, p_brand_title text, p_brand_subtitle text, p_primary_color text, p_secondary_color text, p_card_color text DEFAULT NULL::text, p_media_url text DEFAULT NULL::text, p_wallpaper_url text DEFAULT NULL::text, p_logo_url text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare tid uuid;
begin
 if auth.uid() is null then raise exception 'AUTH_REQUIRED'; end if;
 if not (private.is_owner_access(p_org_id) or private.is_reseller_admin(p_org_id)) then raise exception 'ORG_ACCESS_DENIED'; end if;
 insert into public.themes(org_id,name,brand_title,brand_subtitle,primary_color,secondary_color,card_color,media_url,wallpaper_url,logo_url,is_active,updated_at)
 values(p_org_id,coalesce(nullif(trim(p_name),''),'Theme'),nullif(trim(p_brand_title),''),nullif(trim(p_brand_subtitle),''),p_primary_color,p_secondary_color,p_card_color,p_media_url,p_wallpaper_url,p_logo_url,true,now()) returning id into tid;
 update public.themes set is_active=false,updated_at=now() where org_id=p_org_id and id<>tid and is_active=true;
 update public.organizations set theme_id=tid where id=p_org_id;
 update public.rental_accounts set theme_id=tid,updated_at=now() where org_id=p_org_id and theme_id is null;
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(p_org_id,auth.uid(),'save_theme','theme',tid,jsonb_build_object('name',p_name));
 return jsonb_build_object('ok',true,'theme_id',tid);
end $function$;

-- Token-bound wrappers for the existing Admin UI RPCs.
CREATE OR REPLACE FUNCTION api.create_enrollment(p_session_token text,p_org_id uuid,p_label text,p_minutes bigint DEFAULT 30)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.create_enrollment(p_org_id,p_label,p_minutes); END; $function$;

CREATE OR REPLACE FUNCTION api.create_reseller(p_session_token text,p_name text,p_slug text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.create_reseller(p_name,p_slug); END; $function$;

CREATE OR REPLACE FUNCTION api.dashboard_billing_user(p_session_token text,p_action text,p_username text,p_password text,p_status text,p_role text,p_org_id uuid,p_display_name text,p_user_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.dashboard_billing_user(p_action,p_username,p_password,p_status,p_role,p_org_id,p_display_name,p_user_id); END; $function$;

CREATE OR REPLACE FUNCTION api.dashboard_billing_users(p_session_token text)
RETURNS TABLE(id uuid,username text,role text,org_id uuid,org_name text,status text,display_name text,must_change_password boolean,last_login_at timestamptz,created_at timestamptz)
LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN QUERY SELECT * FROM api.dashboard_billing_users(); END; $function$;

CREATE OR REPLACE FUNCTION api.report_detailed_usage_page(p_session_token text,p_org_id uuid,p_from timestamptz,p_to timestamptz,p_limit integer DEFAULT 200,p_before_started_at timestamptz DEFAULT NULL,p_before_session_id uuid DEFAULT NULL)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.report_detailed_usage_page(p_org_id,p_from,p_to,p_limit,p_before_started_at,p_before_session_id); END; $function$;

CREATE OR REPLACE FUNCTION api.report_monthly_rental_summary(p_session_token text,p_org_id uuid,p_from timestamptz,p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.report_monthly_rental_summary(p_org_id,p_from,p_to); END; $function$;

CREATE OR REPLACE FUNCTION api.report_summary_compact(p_session_token text,p_org_id uuid,p_from timestamptz,p_to timestamptz)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.report_summary_compact(p_org_id,p_from,p_to); END; $function$;

CREATE OR REPLACE FUNCTION api.save_theme(p_session_token text,p_org_id uuid,p_name text,p_brand_title text,p_brand_subtitle text,p_primary_color text,p_secondary_color text,p_card_color text,p_media_url text,p_wallpaper_url text,p_logo_url text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.save_theme(p_org_id,p_name,p_brand_title,p_brand_subtitle,p_primary_color,p_secondary_color,p_card_color,p_media_url,p_wallpaper_url,p_logo_url); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_command_status(p_session_token text,p_org_id uuid,p_command_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE v_command public.device_commands%ROWTYPE;
BEGIN
  PERFORM private.set_admin_actor(p_session_token);
  SELECT * INTO v_command FROM public.device_commands
  WHERE id=p_command_id AND org_id=p_org_id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMAND_NOT_FOUND'; END IF;
  IF NOT private.admin_can_access_device(v_command.device_id,p_org_id) THEN RAISE EXCEPTION 'DEVICE_ACCESS_DENIED'; END IF;
  RETURN jsonb_build_object('id',v_command.id,'status',v_command.status,'result',coalesce(v_command.result,'{}'::jsonb),
    'delivered_at',v_command.delivered_at,'completed_at',v_command.completed_at);
END;
$function$;

-- Token-bound wrappers for the remaining Admin screens and controls.
CREATE OR REPLACE FUNCTION api.admin_active_sessions(p_session_token text,p_org_id uuid)
RETURNS SETOF public.rental_sessions LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN QUERY SELECT * FROM api.admin_active_sessions(p_org_id); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_activity(p_session_token text,p_org_id uuid,p_from timestamptz,p_to timestamptz,p_limit integer DEFAULT 100)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_activity(p_org_id,p_from,p_to,p_limit); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_device_state(p_session_token text,p_org_id uuid,p_device_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_device_state(p_org_id,p_device_id); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_devices(p_session_token text,p_org_id uuid)
RETURNS SETOF public.devices LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN QUERY SELECT * FROM api.admin_devices(p_org_id); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_disconnect_device(p_session_token text,p_org_id uuid,p_device_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_disconnect_device(p_org_id,p_device_id); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_get_free_test_policy(p_session_token text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_get_free_test_policy(); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_rename_device(p_session_token text,p_org_id uuid,p_device_id uuid,p_device_name text)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_rename_device(p_org_id,p_device_id,p_device_name); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_rental_accounts(p_session_token text,p_org_id uuid,p_device_id uuid)
RETURNS SETOF public.rental_accounts LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN QUERY SELECT * FROM api.admin_rental_accounts(p_org_id,p_device_id); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_set_free_test_policy(p_session_token text,p_enabled boolean)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_set_free_test_policy(p_enabled); END; $function$;

CREATE OR REPLACE FUNCTION api.admin_start_trial(p_session_token text,p_org_id uuid,p_device_id uuid)
RETURNS jsonb LANGUAGE plpgsql SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$ BEGIN PERFORM private.set_admin_actor(p_session_token); RETURN api.admin_start_trial(p_org_id,p_device_id); END; $function$;

-- No-token DB1 routines and helper predicates are never directly exposed to the API role.
REVOKE EXECUTE ON FUNCTION private.admin_can_access_device(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.is_owner_access(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.is_reseller_admin(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.user_has_org_access(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION private.user_role(uuid) FROM PUBLIC,ani_api_runtime;

REVOKE EXECUTE ON FUNCTION api.admin_login_lookup(text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.create_enrollment(uuid,text,bigint) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.create_reseller(text,text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.dashboard_billing_user(text,text,text,text,text,uuid,text,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.dashboard_billing_users() FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.report_detailed_usage_page(uuid,timestamptz,timestamptz,integer,timestamptz,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.report_monthly_rental_summary(uuid,timestamptz,timestamptz) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.report_summary_compact(uuid,timestamptz,timestamptz) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.save_theme(uuid,text,text,text,text,text,text,text,text,text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_active_sessions(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_activity(uuid,timestamptz,timestamptz,integer) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_command(uuid,uuid,text,jsonb) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_context() FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_context_v2() FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_create_rental_global(uuid,text,text,bigint,text,timestamptz) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_delete_rental_global(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_device_state(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_devices(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_disable_rental_global(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_disconnect_device(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_get_free_test_policy() FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_recent_alerts(uuid,timestamptz) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_rename_device(uuid,uuid,text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_rental_accounts_global(uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_rental_accounts(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_selected_sessions(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_set_free_test_policy(boolean) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_start_trial(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.admin_update_rental_global(uuid,uuid,text,text,bigint,text,timestamptz,text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.create_device_recovery_enrollment(uuid,bigint) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.report_rental_period_breakdown(uuid,timestamptz,timestamptz) FROM PUBLIC,ani_api_runtime;

GRANT EXECUTE ON FUNCTION api.admin_login_lookup(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.create_enrollment(text,uuid,text,bigint) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.create_reseller(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.dashboard_billing_user(text,text,text,text,text,text,uuid,text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.dashboard_billing_users(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.report_detailed_usage_page(text,uuid,timestamptz,timestamptz,integer,timestamptz,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.report_monthly_rental_summary(text,uuid,timestamptz,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.report_summary_compact(text,uuid,timestamptz,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.save_theme(text,uuid,text,text,text,text,text,text,text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_command_status(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_active_sessions(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_activity(text,uuid,timestamptz,timestamptz,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_device_state(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_devices(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_disconnect_device(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_get_free_test_policy(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_rename_device(text,uuid,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_rental_accounts(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_set_free_test_policy(text,boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_start_trial(text,uuid,uuid) TO ani_api_runtime;

COMMIT;
