-- DB Android migration 011: Billing Control Android PC-management RPCs.
-- Captured from DB1 primary business routines, using the token-scoped overloads only.
-- These are restricted to authenticated Billing Control tokens; reseller role restrictions
-- remain enforced inside the original DB1 function bodies.
BEGIN;

CREATE OR REPLACE FUNCTION api.billing_rental_accounts(p_session_token text, p_org_id uuid, p_device_id uuid)
 RETURNS SETOF rental_accounts
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.billing_control_accounts%rowtype;
begin a:=private.billing_account_by_token(p_session_token); if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if; if not exists(select 1 from public.devices where id=p_device_id and org_id=p_org_id) then raise exception 'DEVICE_ACCESS_DENIED'; end if; return query select r.* from public.rental_accounts r where r.org_id=p_org_id and r.device_id=p_device_id order by r.code; end $function$;

CREATE OR REPLACE FUNCTION api.billing_create_rental(p_session_token text, p_org_id uuid, p_device_id uuid, p_code text, p_category text DEFAULT 'reguler'::text, p_minutes bigint DEFAULT 0, p_client_label text DEFAULT NULL::text, p_expiry_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  a public.billing_control_accounts%rowtype;
  rid uuid; tid uuid; cid uuid;
  secs bigint;
  c text;
  expiry timestamptz;
begin
  a:=private.billing_account_by_token(p_session_token);
  if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if;
  if not exists(select 1 from public.devices where id=p_device_id and org_id=p_org_id) then raise exception 'DEVICE_ACCESS_DENIED'; end if;
  if exists(select 1 from public.devices d where d.id=p_device_id and (d.status<>'online' or coalesce(d.last_heartbeat_at,d.last_seen_at) is null or coalesce(d.last_heartbeat_at,d.last_seen_at)<now()-interval '45 seconds')) then raise exception 'PC_OFFLINE_COMMAND_BLOCKED'; end if;

  c:=upper(trim(p_code));
  if c='' then raise exception 'CODE_REQUIRED'; end if;
  if exists(select 1 from public.rental_accounts where org_id=p_org_id and code=c) then raise exception 'CODE_ALREADY_EXISTS'; end if;

  -- Minutes are the ONLY source of timer duration.
  -- Expiry is an independent hard date boundary and never changes the minutes.
  secs:=greatest(0,coalesce(p_minutes,0))*60;
  expiry:=p_expiry_at;
  if expiry is not null and expiry<=now() then raise exception 'EXPIRY_MUST_BE_FUTURE'; end if;

  select theme_id into tid from public.organizations where id=p_org_id;

  insert into public.rental_accounts(
    org_id,device_id,code,category,remaining_seconds,expiry_at,status,client_label,theme_id,metadata
  ) values(
    p_org_id,p_device_id,c,coalesce(nullif(trim(p_category),''),'reguler'),
    secs,expiry,'active',nullif(trim(p_client_label),''),tid,
    jsonb_build_object('source','billing-control')
  ) returning id into rid;

  insert into public.billing_transactions(
    org_id,device_id,rental_account_id,theme_id,transaction_type,amount,duration_seconds,
    occurred_at,client_label,reference,data_class,metadata
  ) values(
    p_org_id,p_device_id,rid,tid,'time_add',0,secs,now(),
    nullif(trim(p_client_label),''),'account_create','transaction',
    jsonb_build_object('source','billing-control','actor',a.username)
  );

  insert into public.device_commands(org_id,device_id,command,payload,status,created_by)
  values(
    p_org_id,p_device_id,'upsert_rental',
    jsonb_build_object(
      'code',c,'category',coalesce(nullif(trim(p_category),''),'reguler'),
      'remainingSeconds',secs,'expiryDate',expiry,
      'clientLabel',nullif(trim(p_client_label),'')
    ),
    'queued',null
  ) returning id into cid;

  insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  values(
    p_org_id,null,'billing_create_rental','rental_account',rid,
    jsonb_build_object('device_id',p_device_id,'code',c,'command_id',cid,'billing_username',a.username)
  );

  return jsonb_build_object(
    'ok',true,'id',rid,'code',c,'device_id',p_device_id,
    'remaining_seconds',secs,'expiry_at',expiry,'command_id',cid
  );
end
$function$;

CREATE OR REPLACE FUNCTION api.billing_edit_rental(p_session_token text, p_org_id uuid, p_rental_id uuid, p_category text, p_minutes bigint, p_client_label text, p_expiry_at timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  a public.billing_control_accounts%rowtype;
  r public.rental_accounts%rowtype;
  cid uuid;
  secs bigint;
  expiry timestamptz;
begin
  a:=private.billing_account_by_token(p_session_token);
  if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if;

  select * into r from public.rental_accounts
  where id=p_rental_id and org_id=p_org_id for update;
  if not found then raise exception 'RENTAL_NOT_FOUND'; end if;

  if r.device_id is null or not exists(
    select 1 from public.devices d where d.id=r.device_id and d.org_id=p_org_id
  ) then raise exception 'DEVICE_ACCESS_DENIED'; end if;

  if exists(
    select 1 from public.rental_sessions s
    where s.rental_account_id=r.id and s.status in ('active','paused')
  ) then raise exception 'RENTAL_ACTIVE_CANNOT_EDIT_TIME'; end if;

  -- Minutes remain independent from expiry.
  secs:=greatest(0,coalesce(p_minutes,0))*60;
  expiry:=p_expiry_at;
  if expiry is not null and expiry<=now() then raise exception 'EXPIRY_MUST_BE_FUTURE'; end if;

  update public.rental_accounts
  set category=coalesce(nullif(trim(p_category),''),'reguler'),
      remaining_seconds=secs,
      expiry_at=expiry,
      client_label=nullif(trim(p_client_label),''),
      updated_at=now(),
      metadata=coalesce(metadata,'{}'::jsonb)||jsonb_build_object('source','billing-edit')
  where id=r.id;

  insert into public.device_commands(org_id,device_id,command,payload,status,created_by)
  values(
    p_org_id,r.device_id,'upsert_rental',
    jsonb_build_object(
      'code',r.code,
      'category',coalesce(nullif(trim(p_category),''),'reguler'),
      'remainingSeconds',secs,
      'expiryDate',expiry,
      'clientLabel',nullif(trim(p_client_label),'')
    ),
    'queued',null
  ) returning id into cid;

  insert into public.device_command_logs(command_id,org_id,device_id,status,result)
  values(cid,p_org_id,r.device_id,'queued',jsonb_build_object('source','billing-edit','rental_account_id',r.id));

  insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  values(
    p_org_id,null,'billing_edit_rental','rental_account',r.id,
    jsonb_build_object('device_id',r.device_id,'code',r.code,'command_id',cid,'billing_username',a.username)
  );

  return jsonb_build_object(
    'ok',true,'id',r.id,'code',r.code,'device_id',r.device_id,
    'command_id',cid,'expiry_at',expiry,'remaining_seconds',secs
  );
end
$function$;

CREATE OR REPLACE FUNCTION api.billing_delete_rental(p_session_token text, p_org_id uuid, p_rental_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare
  a public.billing_control_accounts%rowtype;
  r public.rental_accounts%rowtype;
  cid uuid;
begin
  a:=private.billing_account_by_token(p_session_token);
  if a.role = 'RESELLER_ADMIN' then
    raise exception 'RESELLER_FEATURE_NOT_AVAILABLE';
  end if;

  if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then
    raise exception 'ORG_ACCESS_DENIED';
  end if;

  select * into r
  from public.rental_accounts
  where id=p_rental_id and org_id=p_org_id
  for update;
  if not found then raise exception 'RENTAL_NOT_FOUND'; end if;

  -- Same custom-session authentication fix as billing_edit_rental.
  if r.device_id is null
     or not exists(
       select 1 from public.devices d
       where d.id=r.device_id and d.org_id=p_org_id
     ) then
    raise exception 'DEVICE_ACCESS_DENIED';
  end if;

  if exists(
    select 1 from public.rental_sessions s
    where s.rental_account_id=r.id
      and s.status in ('active','paused')
  ) then
    raise exception 'RENTAL_ACTIVE_CANNOT_DELETE';
  end if;

  insert into public.device_commands(
    org_id,device_id,command,payload,status,created_by
  )
  values(
    p_org_id,r.device_id,'delete_rental',
    jsonb_build_object('code',r.code),
    'queued',null
  )
  returning id into cid;

  delete from public.rental_accounts where id=r.id;

  insert into public.device_command_logs(
    command_id,org_id,device_id,status,result
  )
  values(
    cid,p_org_id,r.device_id,'queued',
    jsonb_build_object('source','billing-delete','code',r.code)
  );

  insert into public.audit_logs(
    org_id,actor_user_id,action,target_type,target_id,payload
  )
  values(
    p_org_id,null,'billing_delete_rental','rental_account',r.id,
    jsonb_build_object(
      'device_id',r.device_id,
      'code',r.code,
      'command_id',cid,
      'billing_username',a.username
    )
  );

  return jsonb_build_object(
    'ok',true,
    'code',r.code,
    'device_id',r.device_id,
    'command_id',cid
  );
end
$function$;

CREATE OR REPLACE FUNCTION api.billing_start_trial(p_session_token text, p_org_id uuid, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare a public.billing_control_accounts%rowtype; d public.devices%rowtype; rid uuid; cid uuid;
begin
 a:=private.billing_account_by_token(p_session_token);
  if a.role = 'RESELLER_ADMIN' then
    raise exception 'RESELLER_FEATURE_NOT_AVAILABLE';
  end if;

 if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if;
 select * into d from public.devices where id=p_device_id and org_id=p_org_id for update;
 if not found then raise exception 'DEVICE_ACCESS_DENIED'; end if;
 if d.status<>'online' or coalesce(d.last_heartbeat_at,d.last_seen_at) is null or coalesce(d.last_heartbeat_at,d.last_seen_at)<now()-interval '45 seconds' then raise exception 'PC_OFFLINE_COMMAND_BLOCKED'; end if;
 if coalesce(d.metadata->>'activeCode','')<>'' or coalesce(d.metadata->>'pausedCode','')<>'' or exists(select 1 from public.rental_sessions rs where rs.device_id=p_device_id and rs.status in ('active','paused')) then raise exception 'SESSION_ALREADY_ACTIVE'; end if;
 insert into public.device_trial_requests(org_id,device_id,created_by) values(p_org_id,p_device_id,null) returning id into rid;
 insert into public.device_commands(org_id,device_id,command,payload,status,created_by) values(p_org_id,p_device_id,'start_trial',jsonb_build_object('trial_request_id',rid),'queued',null) returning id into cid;
 update public.device_trial_requests set command_id=cid where id=rid;
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(p_org_id,null,'billing_start_trial','device',p_device_id::text,jsonb_build_object('trial_request_id',rid,'command_id',cid,'billing_username',a.username));
 return jsonb_build_object('ok',true,'trial_request_id',rid,'command_id',cid,'duration_seconds',600);
exception when unique_violation then raise exception 'SESSION_ALREADY_ACTIVE';
end $function$;

CREATE OR REPLACE FUNCTION api.billing_disconnect_device(p_session_token text, p_org_id uuid, p_device_id uuid)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  a public.billing_control_accounts%rowtype;
  revoked_count integer := 0;
BEGIN
  a := private.billing_account_by_token(p_session_token);
  IF a.role <> 'SUPER_ADMIN' AND a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM public.devices d
    WHERE d.id = p_device_id AND d.org_id = p_org_id
  ) THEN
    RAISE EXCEPTION 'DEVICE_NOT_FOUND';
  END IF;

  UPDATE public.device_tokens
  SET revoked_at = now()
  WHERE device_id = p_device_id AND revoked_at IS NULL;
  GET DIAGNOSTICS revoked_count = ROW_COUNT;

  UPDATE public.devices
  SET status = 'offline',
      power_state = 'unknown',
      metadata = coalesce(metadata, '{}'::jsonb)
        || jsonb_build_object('pairingDisconnectedAt', now()),
      last_seen_at = coalesce(last_seen_at, now())
  WHERE id = p_device_id AND org_id = p_org_id;

  INSERT INTO public.audit_logs(
    org_id, actor_user_id, action, target_type, target_id, payload
  ) VALUES (
    p_org_id, NULL, 'billing_control_disconnect_device', 'device',
    p_device_id::text,
    jsonb_build_object(
      'revoked_tokens', revoked_count,
      'billing_username', a.username,
      'source', 'billing-control'
    )
  );

  RETURN jsonb_build_object(
    'ok', true,
    'device_id', p_device_id,
    'revoked_tokens', revoked_count
  );
END
$function$;

REVOKE EXECUTE ON FUNCTION api.billing_rental_accounts(uuid,uuid) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.billing_create_rental(uuid,uuid,text,text,bigint,text) FROM PUBLIC,ani_api_runtime;
REVOKE EXECUTE ON FUNCTION api.billing_start_trial(uuid,uuid) FROM PUBLIC,ani_api_runtime;

REVOKE EXECUTE ON FUNCTION api.billing_rental_accounts(text,uuid,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_create_rental(text,uuid,uuid,text,text,bigint,text,timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_edit_rental(text,uuid,uuid,text,bigint,text,timestamptz) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_delete_rental(text,uuid,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_start_trial(text,uuid,uuid) FROM PUBLIC;
REVOKE EXECUTE ON FUNCTION api.billing_disconnect_device(text,uuid,uuid) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.billing_rental_accounts(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_create_rental(text,uuid,uuid,text,text,bigint,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_edit_rental(text,uuid,uuid,text,bigint,text,timestamptz) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_delete_rental(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_start_trial(text,uuid,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_disconnect_device(text,uuid,uuid) TO ani_api_runtime;

COMMIT;
