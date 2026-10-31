-- Secure Wake-on-LAN target resolution for Ani Games Ready.
-- The Admin client supplies paired device IDs only. The database resolves the
-- target's wired LAN MAC from that paired device's heartbeat metadata.
-- Existing authorization, online relay gate, command queue and audit flow remain intact.

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

  -- Wake commands are bound to an accessible, paired target in the same org.
  -- Client-supplied targetMac/expiresAt are never trusted; canonical values are injected here.
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

    -- Avoid repeated Magic Packets from double taps/retries while the PC is booting.
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
