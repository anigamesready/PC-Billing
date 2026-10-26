-- AniGames Ready: FREE TEST 10 minutes policy and server enforcement.
-- Safe additive migration. Does not change DB route-control/readiness flags.

create table if not exists private.admin_feature_settings (
  feature_key text primary key check (feature_key in ('free_test_10m_enabled')),
  enabled boolean not null default false,
  updated_at timestamptz not null default now(),
  updated_by uuid
);

alter table private.admin_feature_settings enable row level security;
revoke all on table private.admin_feature_settings from public, anon, authenticated, service_role;

insert into private.admin_feature_settings(feature_key, enabled)
values ('free_test_10m_enabled', false)
on conflict (feature_key) do nothing;

create or replace function private.is_free_test_10m_enabled()
returns boolean
language sql
stable
security definer
set search_path = private, pg_catalog
as $$
  select coalesce((
    select s.enabled
    from private.admin_feature_settings s
    where s.feature_key = 'free_test_10m_enabled'
    limit 1
  ), false);
$$;

revoke all on function private.is_free_test_10m_enabled() from public, anon, authenticated;
grant execute on function private.is_free_test_10m_enabled() to service_role;

-- Server-side defense in depth: a legacy/tampered PC cannot create a new open
-- __TEST10__ rental session while the global setting is disabled. Existing open
-- test sessions can still heartbeat/update while the admin turns new tests off.
create or replace function private.guard_free_test_10m_session()
returns trigger
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $
begin
  if NEW.code = '__TEST10__' and NEW.status in ('active', 'paused') then
    if TG_OP = 'INSERT' then
      if not private.is_free_test_10m_enabled() then
        raise exception 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
      end if;
    elsif OLD.code is distinct from '__TEST10__'
       or OLD.status not in ('active', 'paused') then
      if not private.is_free_test_10m_enabled() then
        raise exception 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
      end if;
    end if;
  end if;
  return NEW;
end;
$;

revoke all on function private.guard_free_test_10m_session() from public, anon, authenticated, service_role;
drop trigger if exists guard_free_test_10m_session on public.rental_sessions;
create trigger guard_free_test_10m_session
before insert or update of code, status on public.rental_sessions
for each row execute function private.guard_free_test_10m_session();

create or replace function api.admin_get_free_test_policy()
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  setting_row private.admin_feature_settings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if not exists (
    select 1 from public.admin_accounts a
    where a.auth_user_id = auth.uid()
      and a.status = 'active'
      and a.role = 'SUPER_ADMIN'
  ) then
    raise exception 'OWNER_ONLY';
  end if;

  select * into setting_row
  from private.admin_feature_settings
  where feature_key = 'free_test_10m_enabled';

  return jsonb_build_object(
    'enabled', coalesce(setting_row.enabled, false),
    'contact_phone', '082298316902',
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
end;
$$;

create or replace function api.admin_set_free_test_policy(p_enabled boolean)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  setting_row private.admin_feature_settings%rowtype;
begin
  if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
  if p_enabled is null then raise exception 'INVALID_FREE_TEST_SETTING'; end if;
  if not exists (
    select 1 from public.admin_accounts a
    where a.auth_user_id = auth.uid()
      and a.status = 'active'
      and a.role = 'SUPER_ADMIN'
  ) then
    raise exception 'OWNER_ONLY';
  end if;

  insert into private.admin_feature_settings(feature_key, enabled, updated_at, updated_by)
  values ('free_test_10m_enabled', p_enabled, now(), auth.uid())
  on conflict (feature_key) do update
    set enabled = excluded.enabled,
        updated_at = now(),
        updated_by = auth.uid()
  returning * into setting_row;

  return jsonb_build_object(
    'enabled', setting_row.enabled,
    'contact_phone', '082298316902',
    'updated_at', setting_row.updated_at,
    'updated_by', setting_row.updated_by
  );
end;
$$;

create or replace function api.device_free_test_policy(p_token text)
returns jsonb
language plpgsql
security definer
set search_path = public, private, pg_catalog
as $$
declare
  token_device_id uuid;
  is_enabled boolean;
begin
  if coalesce(btrim(p_token), '') = '' then raise exception 'INVALID_DEVICE_TOKEN'; end if;

  select t.device_id into token_device_id
  from public.device_tokens t
  where t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    and t.revoked_at is null
  order by t.created_at desc
  limit 1;

  if token_device_id is null then raise exception 'INVALID_DEVICE_TOKEN'; end if;

  is_enabled := private.is_free_test_10m_enabled();
  return jsonb_build_object(
    'ok', true,
    'enabled', is_enabled,
    'contact_phone', '082298316902',
    'message', case
      when is_enabled then 'FREE_TEST_ALLOWED'
      else 'Silahkan hubungi admin untuk melakukan tes 082298316902'
    end
  );
end;
$$;

revoke all on function api.admin_get_free_test_policy() from public;
revoke all on function api.admin_set_free_test_policy(boolean) from public;
revoke all on function api.device_free_test_policy(text) from public;
grant execute on function api.admin_get_free_test_policy() to authenticated, service_role;
grant execute on function api.admin_set_free_test_policy(boolean) to authenticated, service_role;
grant execute on function api.device_free_test_policy(text) to anon, authenticated, service_role;

-- Gate the browser/Admin/API entry points before creating a trial request or command.
create or replace function api.admin_start_trial(p_org_id uuid, p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_catalog
as $function$
declare a public.admin_accounts%rowtype; d public.devices%rowtype; rid uuid; cid uuid;
begin
 if auth.uid() is null then raise exception 'UNAUTHENTICATED'; end if;
 select * into a from public.admin_accounts where auth_user_id=auth.uid() and status='active' limit 1;
 if not found then raise exception 'ADMIN_ACCOUNT_NOT_CONFIGURED'; end if;
 if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if;
 if not private.is_free_test_10m_enabled() then
   raise exception 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
 end if;
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
end;
$function$;

create or replace function api.billing_start_trial(p_org_id uuid, p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_catalog
as $function$
declare a public.billing_control_accounts%rowtype; d public.devices%rowtype; rid uuid; cid uuid;
begin
 select * into a from public.billing_control_accounts where auth_user_id=auth.uid() and status='active' limit 1;
 if not found then raise exception 'BILLING_CONTROL_ACCESS_DENIED'; end if;
 if a.role = 'RESELLER_ADMIN' then raise exception 'RESELLER_FEATURE_NOT_AVAILABLE'; end if;
 if not private.is_free_test_10m_enabled() then
   raise exception 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
 end if;
 select * into d from public.devices where id=p_device_id and org_id=p_org_id for update;
 if not found or not private.billing_can_access_device(p_device_id,p_org_id) then raise exception 'DEVICE_ACCESS_DENIED'; end if;
 if d.status<>'online' or coalesce(d.last_heartbeat_at,d.last_seen_at) is null or coalesce(d.last_heartbeat_at,d.last_seen_at)<now()-interval '45 seconds' then raise exception 'PC_OFFLINE_COMMAND_BLOCKED'; end if;
 if coalesce(d.metadata->>'activeCode','')<>'' or coalesce(d.metadata->>'pausedCode','')<>'' or exists(select 1 from public.rental_sessions rs where rs.device_id=p_device_id and rs.status in ('active','paused')) then raise exception 'SESSION_ALREADY_ACTIVE'; end if;
 insert into public.device_trial_requests(org_id,device_id,created_by) values(p_org_id,p_device_id,auth.uid()) returning id into rid;
 insert into public.device_commands(org_id,device_id,command,payload,status,created_by) values(p_org_id,p_device_id,'start_trial',jsonb_build_object('trial_request_id',rid),'queued',auth.uid()) returning id into cid;
 update public.device_trial_requests set command_id=cid where id=rid;
 insert into public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload) values(p_org_id,auth.uid(),'billing_start_trial','device',p_device_id::text,jsonb_build_object('trial_request_id',rid,'command_id',cid));
 return jsonb_build_object('ok',true,'trial_request_id',rid,'command_id',cid,'duration_seconds',600);
exception when unique_violation then raise exception 'SESSION_ALREADY_ACTIVE';
end $function$;

create or replace function api.billing_start_trial(p_session_token text, p_org_id uuid, p_device_id uuid)
returns jsonb
language plpgsql
security definer
set search_path to public, pg_catalog
as $function$
declare a public.billing_control_accounts%rowtype; d public.devices%rowtype; rid uuid; cid uuid;
begin
 a:=private.billing_account_by_token(p_session_token);
 if a.role = 'RESELLER_ADMIN' then raise exception 'RESELLER_FEATURE_NOT_AVAILABLE'; end if;
 if a.role<>'SUPER_ADMIN' and a.org_id is distinct from p_org_id then raise exception 'ORG_ACCESS_DENIED'; end if;
 if not private.is_free_test_10m_enabled() then
   raise exception 'FREE_TEST_DISABLED: Silahkan hubungi admin untuk melakukan tes 082298316902';
 end if;
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
