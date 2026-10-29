-- Additive, token-authenticated polling for the independent PC Billing watchdog.
-- It only claims restart_billing and never consumes the normal renderer's command queue.
CREATE OR REPLACE FUNCTION api.device_watchdog_poll(p_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  command_row public.device_commands%ROWTYPE;
BEGIN
  IF COALESCE(btrim(p_token), '') = '' THEN
    RAISE EXCEPTION 'INVALID_DEVICE_TOKEN';
  END IF;

  SELECT d.id, d.org_id INTO did, oid
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;

  IF did IS NULL THEN
    RAISE EXCEPTION 'INVALID_DEVICE_TOKEN';
  END IF;

  SELECT c.* INTO command_row
  FROM public.device_commands c
  WHERE c.device_id = did
    AND c.command = 'restart_billing'
    AND c.created_at >= now() - interval '24 hours'
    AND (
      c.status = 'queued'
      OR (
        c.status = 'acknowledged'
        AND COALESCE(c.acknowledged_at, c.delivered_at, c.created_at)
              <= now() - interval '20 seconds'
      )
    )
  ORDER BY c.created_at, c.id
  FOR UPDATE SKIP LOCKED
  LIMIT 1;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'device_id', did,
      'commands', '[]'::jsonb
    );
  END IF;

  UPDATE public.device_commands
  SET status = 'acknowledged',
      acknowledged_at = now(),
      delivered_at = now(),
      delivery_attempts = COALESCE(delivery_attempts, 0) + 1
  WHERE id = command_row.id
  RETURNING * INTO command_row;

  RETURN jsonb_build_object(
    'ok', true,
    'device_id', did,
    'commands', jsonb_build_array(jsonb_build_object(
      'id', command_row.id,
      'command', command_row.command,
      'payload', command_row.payload,
      'status', command_row.status,
      'created_at', command_row.created_at,
      'delivery_attempts', command_row.delivery_attempts
    ))
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.device_watchdog_poll(text) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.device_watchdog_poll(text) TO anon, authenticated;
