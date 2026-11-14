-- ANI GAMES READY DB ANDROID — Billing Control command API port.
-- Exact DB1 token-authenticated function bodies, excluding any Supabase Auth dependency.
-- Reseller accounts are explicitly denied PC/Windows control; SUPER_ADMIN retains manual commands.
BEGIN;

CREATE OR REPLACE FUNCTION api.billing_command(
  p_session_token text,p_org_id uuid,p_device_id uuid,p_command text,p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  s public.rental_sessions%ROWTYPE;
  cid uuid;
  sid uuid;
BEGIN
  a := private.billing_account_by_token(p_session_token);
  IF a.role = 'RESELLER_ADMIN' THEN
    RAISE EXCEPTION 'RESELLER_FEATURE_NOT_AVAILABLE';
  END IF;
  IF a.role <> 'SUPER_ADMIN' AND a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;

  SELECT * INTO d FROM public.devices WHERE id=p_device_id AND org_id=p_org_id;
  IF NOT FOUND OR d.status='disabled' THEN RAISE EXCEPTION 'DEVICE_ACCESS_DENIED'; END IF;
  IF p_command <> 'restart_billing' AND (
    coalesce(d.last_heartbeat_at,d.last_seen_at) IS NULL
    OR coalesce(d.last_heartbeat_at,d.last_seen_at)<now()-interval '45 seconds'
    OR d.status<>'online'
  ) THEN RAISE EXCEPTION 'PC_OFFLINE_COMMAND_BLOCKED'; END IF;
  IF p_command NOT IN ('restart_billing','restart_pc','restart','logoff','logout','pause','resume','stop','shutdown','refresh','wake','add_time') THEN
    RAISE EXCEPTION 'COMMAND_NOT_ALLOWED';
  END IF;
  IF p_command IN ('pause','resume','stop') THEN
    IF nullif(p_payload->>'session_id','') IS NULL THEN RAISE EXCEPTION 'SESSION_ID_REQUIRED'; END IF;
    sid := (p_payload->>'session_id')::uuid;
    SELECT * INTO s FROM public.rental_sessions
    WHERE id=sid AND org_id=p_org_id AND device_id=p_device_id FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SESSION_NOT_FOUND'; END IF;
    IF p_command='pause' AND s.status<>'active' THEN RAISE EXCEPTION 'SESSION_NOT_ACTIVE'; END IF;
    IF p_command='resume' AND s.status<>'paused' THEN RAISE EXCEPTION 'SESSION_NOT_PAUSED'; END IF;
    IF p_command='stop' AND s.status NOT IN ('active','paused') THEN RAISE EXCEPTION 'SESSION_NOT_OPEN'; END IF;
  END IF;

  INSERT INTO public.device_commands(org_id,device_id,command,payload,status,created_by)
  VALUES(p_org_id,p_device_id,p_command,coalesce(p_payload,'{}'::jsonb),'queued',NULL)
  RETURNING id INTO cid;
  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(p_org_id,NULL,'billing_remote_command','device',p_device_id::text,
    jsonb_build_object('command',p_command,'command_id',cid,'billing_username',a.username,'payload',coalesce(p_payload,'{}'::jsonb)));

  RETURN jsonb_build_object('ok',true,'command_id',cid,'device_id',p_device_id,'command',p_command);
END;
$function$;

CREATE OR REPLACE FUNCTION api.billing_command_status(p_session_token text,p_command_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','pg_catalog'
AS $function$
DECLARE
  a public.billing_control_accounts%ROWTYPE;
  c public.device_commands%ROWTYPE;
BEGIN
  a := private.billing_account_by_token(p_session_token);
  IF a.role='RESELLER_ADMIN' THEN RAISE EXCEPTION 'RESELLER_FEATURE_NOT_AVAILABLE'; END IF;
  SELECT * INTO c FROM public.device_commands WHERE id=p_command_id AND org_id=a.org_id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'COMMAND_NOT_FOUND'; END IF;
  RETURN jsonb_build_object(
    'ok',true,'command_id',c.id,'device_id',c.device_id,'command',c.command,
    'status',c.status,'result',coalesce(c.result,'{}'::jsonb),'created_at',c.created_at,
    'acknowledged_at',c.acknowledged_at,'delivered_at',c.delivered_at,
    'completed_at',c.completed_at,'delivery_attempts',coalesce(c.delivery_attempts,0)
  );
END;
$function$;

GRANT EXECUTE ON FUNCTION api.billing_command(text,uuid,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.billing_command_status(text,uuid) TO ani_api_runtime;

COMMIT;
