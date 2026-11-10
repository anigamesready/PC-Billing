-- Ani Games Ready Android Wake-on-LAN Relay v1
-- Additive-only migration. Does not alter devices, rental, billing, pairing, or existing command queues.

CREATE TABLE IF NOT EXISTS public.wol_relay_enrollments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code_hash text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  used_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS public.wol_relay_devices (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  relay_name text NOT NULL CHECK (length(btrim(relay_name)) BETWEEN 1 AND 100),
  installation_id text NOT NULL CHECK (length(btrim(installation_id)) BETWEEN 8 AND 128),
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  app_version text,
  model text,
  status text NOT NULL DEFAULT 'offline' CHECK (status IN ('online','offline','revoked')),
  last_seen_at timestamptz,
  battery_percent integer CHECK (battery_percent BETWEEN 0 AND 100),
  battery_temp_c numeric(5,2),
  charging boolean,
  battery_health text,
  last_packet_at timestamptz,
  last_error text,
  revoked_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (org_id, installation_id)
);

CREATE TABLE IF NOT EXISTS public.wol_relay_commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  relay_id uuid NOT NULL REFERENCES public.wol_relay_devices(id) ON DELETE CASCADE,
  target_device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  target_mac text NOT NULL CHECK (target_mac ~ '^([0-9A-F]{2}:){5}[0-9A-F]{2}$'),
  target_device_name text NOT NULL,
  status text NOT NULL DEFAULT 'queued'
    CHECK (status IN ('queued','delivered','packet_sent','failed','expired','confirmed')),
  expires_at timestamptz NOT NULL,
  created_by uuid,
  delivered_at timestamptz,
  packet_sent_at timestamptz,
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE INDEX IF NOT EXISTS wol_relay_devices_org_seen_idx
  ON public.wol_relay_devices(org_id, last_seen_at DESC)
  WHERE revoked_at IS NULL;
CREATE INDEX IF NOT EXISTS wol_relay_commands_relay_queue_idx
  ON public.wol_relay_commands(relay_id, status, created_at);
CREATE INDEX IF NOT EXISTS wol_relay_commands_target_recent_idx
  ON public.wol_relay_commands(target_device_id, created_at DESC);

ALTER TABLE public.wol_relay_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wol_relay_devices ENABLE ROW LEVEL SECURITY;
ALTER TABLE public.wol_relay_commands ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON TABLE public.wol_relay_enrollments FROM anon, authenticated;
REVOKE ALL ON TABLE public.wol_relay_devices FROM anon, authenticated;
REVOKE ALL ON TABLE public.wol_relay_commands FROM anon, authenticated;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.wol_relay_enrollments TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.wol_relay_devices TO service_role;
GRANT SELECT, INSERT, UPDATE, DELETE ON TABLE public.wol_relay_commands TO service_role;

-- Owner-only Admin RPC: create a short-lived, one-time pairing code.
CREATE OR REPLACE FUNCTION api.wol_relay_create_enrollment()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'api', 'extensions', 'pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  v_code text;
  v_expires timestamptz := now() + interval '10 minutes';
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO a FROM public.admin_accounts
   WHERE auth_user_id = auth.uid() AND status = 'active' LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_NOT_CONFIGURED'; END IF;
  IF a.role <> 'SUPER_ADMIN' THEN RAISE EXCEPTION 'ADMIN_ROLE_REQUIRED'; END IF;

  v_code := upper(encode(extensions.gen_random_bytes(6), 'hex'));
  INSERT INTO public.wol_relay_enrollments(org_id, code_hash, expires_at, created_by)
  VALUES (a.org_id, encode(extensions.digest(convert_to(v_code, 'UTF8'), 'sha256'), 'hex'), v_expires, auth.uid());

  RETURN jsonb_build_object('ok', true, 'code', v_code, 'expires_at', v_expires);
END
$function$;

-- Owner-only Admin RPC: list relay health without exposing the relay token.
CREATE OR REPLACE FUNCTION api.wol_relay_status()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'api', 'pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  v_relays jsonb;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO a FROM public.admin_accounts
   WHERE auth_user_id = auth.uid() AND status = 'active' LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_NOT_CONFIGURED'; END IF;
  IF a.role <> 'SUPER_ADMIN' THEN RAISE EXCEPTION 'ADMIN_ROLE_REQUIRED'; END IF;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'relay_id', id,
    'relay_name', relay_name,
    'status', CASE
      WHEN revoked_at IS NOT NULL THEN 'revoked'
      WHEN last_seen_at > now() - interval '90 seconds' THEN 'online'
      ELSE 'offline'
    END,
    'app_version', app_version,
    'model', model,
    'last_seen_at', last_seen_at,
    'battery_percent', battery_percent,
    'battery_temp_c', battery_temp_c,
    'charging', charging,
    'battery_health', battery_health,
    'last_packet_at', last_packet_at,
    'last_error', last_error
  ) ORDER BY last_seen_at DESC NULLS LAST), '[]'::jsonb)
  INTO v_relays
  FROM public.wol_relay_devices
  WHERE org_id = a.org_id;

  RETURN jsonb_build_object('ok', true, 'relays', v_relays);
END
$function$;

-- Owner-only Admin RPC: resolve target MAC from the paired PC heartbeat, then queue to Android relay.
CREATE OR REPLACE FUNCTION api.wol_relay_enqueue(p_target_device_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'api', 'private', 'pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  target public.devices%ROWTYPE;
  relay public.wol_relay_devices%ROWTYPE;
  v_mac text;
  v_command_id uuid;
  v_expires timestamptz := now() + interval '90 seconds';
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO a FROM public.admin_accounts
   WHERE auth_user_id = auth.uid() AND status = 'active' LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_NOT_CONFIGURED'; END IF;
  IF a.role <> 'SUPER_ADMIN' THEN RAISE EXCEPTION 'ADMIN_ROLE_REQUIRED'; END IF;

  SELECT * INTO target FROM public.devices
   WHERE id = p_target_device_id AND org_id = a.org_id LIMIT 1;
  IF NOT FOUND OR NOT private.admin_can_access_device(p_target_device_id, a.org_id) THEN
    RAISE EXCEPTION 'WAKE_TARGET_ACCESS_DENIED';
  END IF;
  IF target.status = 'disabled' THEN RAISE EXCEPTION 'WAKE_TARGET_DISABLED'; END IF;
  IF target.status = 'online'
     AND coalesce(target.last_heartbeat_at, target.last_seen_at) > now() - interval '45 seconds' THEN
    RAISE EXCEPTION 'WAKE_TARGET_ALREADY_ONLINE';
  END IF;

  v_mac := upper(regexp_replace(coalesce(target.metadata->>'wolLanMac', ''), '[^0-9A-F]', '', 'g'));
  IF v_mac !~ '^[0-9A-F]{12}$' OR v_mac IN ('000000000000','FFFFFFFFFFFF') THEN
    RAISE EXCEPTION 'WAKE_TARGET_MAC_NOT_REPORTED';
  END IF;

  SELECT * INTO relay
    FROM public.wol_relay_devices
   WHERE org_id = a.org_id
     AND status = 'online'
     AND revoked_at IS NULL
     AND last_seen_at > now() - interval '90 seconds'
   ORDER BY last_seen_at DESC
   LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'WOL_RELAY_OFFLINE'; END IF;

  IF EXISTS (
    SELECT 1 FROM public.wol_relay_commands c
     WHERE c.target_device_id = p_target_device_id
       AND c.status IN ('queued','delivered','packet_sent')
       AND c.created_at > now() - interval '120 seconds'
  ) THEN
    RAISE EXCEPTION 'WOL_COMMAND_ALREADY_PENDING';
  END IF;

  INSERT INTO public.wol_relay_commands(
    org_id, relay_id, target_device_id, target_mac, target_device_name,
    status, expires_at, created_by
  ) VALUES (
    a.org_id, relay.id, target.id,
    substr(v_mac,1,2)||':'||substr(v_mac,3,2)||':'||substr(v_mac,5,2)||':'||
    substr(v_mac,7,2)||':'||substr(v_mac,9,2)||':'||substr(v_mac,11,2),
    left(coalesce(target.device_name, target.client_id, 'PC target'), 100),
    'queued', v_expires, auth.uid()
  ) RETURNING id INTO v_command_id;

  INSERT INTO public.audit_logs(org_id, actor_user_id, action, target_type, target_id, payload)
  VALUES (
    a.org_id, auth.uid(), 'android_wol_queued', 'device', target.id::text,
    jsonb_build_object('command_id',v_command_id,'relay_id',relay.id,'target_device_id',target.id)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'command_id', v_command_id,
    'relay_name', relay.relay_name,
    'target_device_id', target.id,
    'target_device_name', left(coalesce(target.device_name, target.client_id, 'PC target'), 100),
    'expires_at', v_expires
  );
END
$function$;

-- Owner-only Admin RPC: inspect the outcome of a queued command.
CREATE OR REPLACE FUNCTION api.wol_relay_command_status(p_command_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'api', 'pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  c public.wol_relay_commands%ROWTYPE;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'UNAUTHENTICATED'; END IF;
  SELECT * INTO a FROM public.admin_accounts
   WHERE auth_user_id = auth.uid() AND status = 'active' LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'ADMIN_ACCOUNT_NOT_CONFIGURED'; END IF;
  IF a.role <> 'SUPER_ADMIN' THEN RAISE EXCEPTION 'ADMIN_ROLE_REQUIRED'; END IF;

  SELECT * INTO c FROM public.wol_relay_commands
   WHERE id = p_command_id AND org_id = a.org_id LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'WOL_COMMAND_NOT_FOUND'; END IF;
  RETURN jsonb_build_object(
    'ok', true,
    'command_id', c.id,
    'status', CASE WHEN c.status = 'queued' AND c.expires_at <= now() THEN 'expired' ELSE c.status END,
    'target_device_id', c.target_device_id,
    'target_device_name', c.target_device_name,
    'created_at', c.created_at,
    'expires_at', c.expires_at,
    'packet_sent_at', c.packet_sent_at,
    'result', c.result
  );
END
$function$;

-- Service-only RPC: redeem one-time enrollment and create/update a relay identity.
CREATE OR REPLACE FUNCTION api.wol_relay_register(
  p_code_hash text, p_token_hash text, p_relay_name text,
  p_installation_id text, p_app_version text, p_model text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'api', 'pg_catalog'
AS $function$
DECLARE
  v_org uuid;
  v_created_by uuid;
  v_relay_id uuid;
BEGIN
  UPDATE public.wol_relay_enrollments
     SET used_at = now()
   WHERE code_hash = p_code_hash
     AND used_at IS NULL
     AND expires_at > now()
   RETURNING org_id, created_by INTO v_org, v_created_by;
  IF v_org IS NULL THEN RAISE EXCEPTION 'WOL_RELAY_ENROLLMENT_INVALID'; END IF;

  INSERT INTO public.wol_relay_devices(
    org_id, relay_name, installation_id, token_hash, app_version, model,
    status, last_seen_at, revoked_at
  ) VALUES (
    v_org, left(coalesce(nullif(btrim(p_relay_name),''),'Ani WoL Relay'),100),
    p_installation_id, p_token_hash, p_app_version, p_model,
    'online', now(), NULL
  )
  ON CONFLICT (org_id, installation_id) DO UPDATE SET
    relay_name = EXCLUDED.relay_name,
    token_hash = EXCLUDED.token_hash,
    app_version = EXCLUDED.app_version,
    model = EXCLUDED.model,
    status = 'online',
    last_seen_at = now(),
    revoked_at = NULL,
    updated_at = now()
  RETURNING id INTO v_relay_id;

  RETURN jsonb_build_object('ok',true,'relay_id',v_relay_id,'org_id',v_org);
END
$function$;

CREATE OR REPLACE FUNCTION api.wol_relay_heartbeat(p_relay_id uuid, p_token_hash text, p_metrics jsonb DEFAULT '{}'::jsonb)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'api', 'pg_catalog'
AS $function$
DECLARE
  n integer;
BEGIN
  UPDATE public.wol_relay_devices SET
    status = 'online',
    last_seen_at = now(),
    app_version = left(coalesce(p_metrics->>'appVersion',app_version),64),
    model = left(coalesce(p_metrics->>'model',model),100),
    battery_percent = CASE WHEN (p_metrics->>'batteryPercent') ~ '^[0-9]{1,3}$'
      THEN least(100,greatest(0,(p_metrics->>'batteryPercent')::integer)) ELSE battery_percent END,
    battery_temp_c = CASE WHEN (p_metrics->>'batteryTemperatureC') ~ '^-?[0-9]{1,3}(\.[0-9]{1,2})?$'
      THEN (p_metrics->>'batteryTemperatureC')::numeric ELSE battery_temp_c END,
    charging = CASE WHEN p_metrics ? 'charging' THEN (p_metrics->>'charging')::boolean ELSE charging END,
    battery_health = left(coalesce(p_metrics->>'batteryHealth',battery_health),40),
    updated_at = now()
  WHERE id = p_relay_id AND token_hash = p_token_hash AND revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'INVALID_WOL_RELAY_TOKEN'; END IF;
  RETURN jsonb_build_object('ok',true,'server_time',now());
END
$function$;

CREATE OR REPLACE FUNCTION api.wol_relay_poll(p_relay_id uuid, p_token_hash text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'api', 'pg_catalog'
AS $function$
DECLARE
  c public.wol_relay_commands%ROWTYPE;
  n integer;
BEGIN
  UPDATE public.wol_relay_devices SET status='online',last_seen_at=now(),updated_at=now()
   WHERE id=p_relay_id AND token_hash=p_token_hash AND revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'INVALID_WOL_RELAY_TOKEN'; END IF;

  UPDATE public.wol_relay_commands SET status='expired'
   WHERE relay_id=p_relay_id AND status IN ('queued','delivered') AND expires_at <= now();

  -- Re-lease a delivered command if the relay crashed before acknowledging it.
  -- Duplicate Magic Packets are harmless; the 90-second expiry and 120-second
  -- Admin duplicate guard prevent uncontrolled repeated wake requests.
  UPDATE public.wol_relay_commands SET status='queued', delivered_at=NULL
   WHERE relay_id=p_relay_id AND status='delivered'
     AND delivered_at < now() - interval '30 seconds' AND expires_at > now();

  SELECT * INTO c FROM public.wol_relay_commands
   WHERE relay_id=p_relay_id AND status='queued' AND expires_at > now()
   ORDER BY created_at ASC
   LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'command',NULL); END IF;

  UPDATE public.wol_relay_commands SET status='delivered',delivered_at=now()
   WHERE id=c.id;
  RETURN jsonb_build_object('ok',true,'command',jsonb_build_object(
    'id',c.id,'targetMac',c.target_mac,'targetDeviceName',c.target_device_name,
    'expiresAt',c.expires_at
  ));
END
$function$;

CREATE OR REPLACE FUNCTION api.wol_relay_ack(
  p_relay_id uuid, p_token_hash text, p_command_id uuid,
  p_status text, p_result jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY INVOKER
SET search_path TO 'public', 'api', 'pg_catalog'
AS $function$
DECLARE
  n integer;
BEGIN
  IF p_status NOT IN ('packet_sent','failed') THEN RAISE EXCEPTION 'INVALID_WOL_RELAY_ACK_STATUS'; END IF;
  UPDATE public.wol_relay_commands c SET
    status=p_status,
    packet_sent_at=CASE WHEN p_status='packet_sent' THEN now() ELSE packet_sent_at END,
    result=coalesce(p_result,'{}'::jsonb)
  FROM public.wol_relay_devices r
  WHERE c.id=p_command_id AND c.relay_id=p_relay_id
    AND c.status='delivered'
    AND r.id=p_relay_id AND r.token_hash=p_token_hash AND r.revoked_at IS NULL;
  GET DIAGNOSTICS n = ROW_COUNT;
  IF n <> 1 THEN RAISE EXCEPTION 'WOL_RELAY_ACK_REJECTED'; END IF;

  UPDATE public.wol_relay_devices SET
    last_packet_at=CASE WHEN p_status='packet_sent' THEN now() ELSE last_packet_at END,
    last_error=CASE WHEN p_status='failed' THEN left(coalesce(p_result->>'message',p_result->>'error','WoL failed'),240) ELSE NULL END,
    updated_at=now()
  WHERE id=p_relay_id;

  RETURN jsonb_build_object('ok',true,'status',p_status);
END
$function$;

-- Service-only execution for relay RPCs; Admin functions are authenticated-owner only.
REVOKE ALL ON FUNCTION api.wol_relay_create_enrollment() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION api.wol_relay_status() FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION api.wol_relay_enqueue(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION api.wol_relay_command_status(uuid) FROM PUBLIC, anon;
REVOKE ALL ON FUNCTION api.wol_relay_register(text,text,text,text,text,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION api.wol_relay_heartbeat(uuid,text,jsonb) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION api.wol_relay_poll(uuid,text) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION api.wol_relay_ack(uuid,text,uuid,text,jsonb) FROM PUBLIC, anon, authenticated;

GRANT EXECUTE ON FUNCTION api.wol_relay_create_enrollment() TO authenticated;
GRANT EXECUTE ON FUNCTION api.wol_relay_status() TO authenticated;
GRANT EXECUTE ON FUNCTION api.wol_relay_enqueue(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.wol_relay_command_status(uuid) TO authenticated;
GRANT EXECUTE ON FUNCTION api.wol_relay_register(text,text,text,text,text,text) TO service_role;
GRANT EXECUTE ON FUNCTION api.wol_relay_heartbeat(uuid,text,jsonb) TO service_role;
GRANT EXECUTE ON FUNCTION api.wol_relay_poll(uuid,text) TO service_role;
GRANT EXECUTE ON FUNCTION api.wol_relay_ack(uuid,text,uuid,text,jsonb) TO service_role;
