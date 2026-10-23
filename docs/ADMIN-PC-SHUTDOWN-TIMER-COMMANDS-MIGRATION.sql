-- AniGames Admin/PC Billing — scheduled shutdown timer command allowlist.
-- Apply to BOTH Supabase projects: DB1 (Billing Ani Games Ready) and DB2 (Billing Ani Games Ready 2).
-- No rental rows, device rows, command queues, or logs are deleted.
-- New command names are intentionally separate from "shutdown", so older PC Billing
-- builds fail closed with COMMAND_NOT_ALLOWED rather than treating a scheduled request
-- as an immediate Windows shutdown.

ALTER TABLE public.device_commands
  DROP CONSTRAINT IF EXISTS device_commands_command_check;

ALTER TABLE public.device_commands
  ADD CONSTRAINT device_commands_command_check CHECK (
    command = ANY (ARRAY[
      'restart_billing'::text,
      'restart_pc'::text,
      'restart'::text,
      'logoff'::text,
      'logout'::text,
      'pause'::text,
      'resume'::text,
      'stop'::text,
      'shutdown'::text,
      'add_time'::text,
      'set_theme'::text,
      'refresh'::text,
      'wake'::text,
      'upsert_rental'::text,
      'start_trial'::text,
      'delete_rental'::text,
      'show_admin_message'::text,
      'schedule_shutdown'::text,
      'cancel_shutdown_timer'::text
    ])
  );

CREATE OR REPLACE FUNCTION api.admin_command(
  p_org_id uuid,
  p_device_id uuid,
  p_command text,
  p_payload jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  s public.rental_sessions%ROWTYPE;
  cid uuid;
  sid uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;

  SELECT * INTO a
  FROM public.admin_accounts
  WHERE auth_user_id = auth.uid() AND status = 'active'
  LIMIT 1;

  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_NOT_CONFIGURED'; END IF;
  IF a.role <> 'SUPER_ADMIN' AND a.org_id IS DISTINCT FROM p_org_id THEN
    RAISE EXCEPTION 'ORG_ACCESS_DENIED';
  END IF;

  SELECT * INTO d
  FROM public.devices
  WHERE id = p_device_id AND org_id = p_org_id
  LIMIT 1;

  IF NOT FOUND OR NOT private.admin_can_access_device(p_device_id, p_org_id) THEN
    RAISE EXCEPTION 'DEVICE_ACCESS_DENIED';
  END IF;
  IF d.status = 'disabled' THEN RAISE EXCEPTION 'DEVICE_DISABLED'; END IF;
  IF coalesce(d.last_heartbeat_at, d.last_seen_at) IS NULL
     OR coalesce(d.last_heartbeat_at, d.last_seen_at) < now() - interval '45 seconds'
     OR d.status <> 'online' THEN
    RAISE EXCEPTION 'PC_OFFLINE_COMMAND_BLOCKED';
  END IF;

  IF p_command NOT IN (
    'restart_billing','restart_pc','restart','logoff','logout','pause','resume',
    'stop','shutdown','refresh','wake','add_time','show_admin_message',
    'schedule_shutdown','cancel_shutdown_timer'
  ) THEN
    RAISE EXCEPTION 'COMMAND_NOT_ALLOWED';
  END IF;

  -- Keep timer messages bound to the selected device and require explicit intent flags.
  IF p_command = 'schedule_shutdown' THEN
    IF coalesce((p_payload->>'scheduled')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_PAYLOAD';
    END IF;
    IF nullif(btrim(coalesce(p_payload->>'scheduleId','')), '') IS NULL
       OR nullif(btrim(coalesce(p_payload->>'deadlineAt','')), '') IS NULL
       OR p_payload->>'targetDeviceId' IS DISTINCT FROM p_device_id::text THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_TARGET';
    END IF;
  ELSIF p_command = 'cancel_shutdown_timer' THEN
    IF coalesce((p_payload->>'cancelScheduled')::boolean, false) IS NOT TRUE THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_CANCEL_PAYLOAD';
    END IF;
    IF p_payload->>'targetDeviceId' IS DISTINCT FROM p_device_id::text THEN
      RAISE EXCEPTION 'INVALID_SHUTDOWN_TIMER_TARGET';
    END IF;
  END IF;

  IF p_command = 'show_admin_message'
     AND length(btrim(coalesce(p_payload->>'message',''))) NOT BETWEEN 1 AND 240 THEN
    RAISE EXCEPTION 'INVALID_ADMIN_MESSAGE';
  END IF;

  IF p_command IN ('pause','resume','stop') THEN
    IF nullif(p_payload->>'session_id','') IS NULL THEN
      RAISE EXCEPTION 'SESSION_ID_REQUIRED';
    END IF;
    sid := (p_payload->>'session_id')::uuid;
    SELECT * INTO s
    FROM public.rental_sessions
    WHERE id = sid AND org_id = p_org_id AND device_id = p_device_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'SESSION_NOT_FOUND'; END IF;
    IF p_command = 'pause' AND s.status <> 'active' THEN RAISE EXCEPTION 'SESSION_NOT_ACTIVE'; END IF;
    IF p_command = 'resume' AND s.status <> 'paused' THEN RAISE EXCEPTION 'SESSION_NOT_PAUSED'; END IF;
    IF p_command = 'stop' AND s.status NOT IN ('active','paused') THEN RAISE EXCEPTION 'SESSION_NOT_OPEN'; END IF;
  END IF;

  INSERT INTO public.device_commands(org_id, device_id, command, payload, status, created_by)
  VALUES (p_org_id, p_device_id, p_command, coalesce(p_payload,'{}'::jsonb), 'queued', auth.uid())
  RETURNING id INTO cid;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (
    p_org_id, auth.uid(), 'remote_command', 'device', p_device_id::text,
    jsonb_build_object('command',p_command,'command_id',cid,'payload',coalesce(p_payload,'{}'::jsonb))
  );

  RETURN jsonb_build_object('ok',true,'command_id',cid,'device_id',p_device_id,'command',p_command);
END
$function$;
