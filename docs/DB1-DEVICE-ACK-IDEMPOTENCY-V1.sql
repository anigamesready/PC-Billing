-- DB1 live definition after device_ack_idempotency_monotonic_state_v1.
-- Acknowledgement replay is a no-op. Terminal status does not regress on stale ACK.
CREATE OR REPLACE FUNCTION api.device_ack(p_token text, p_command_id uuid, p_status text, p_result jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  normalized_status text;
  command_row public.device_commands%ROWTYPE;
BEGIN
  IF pg_column_size(coalesce(p_result, '{}'::jsonb)) > 32768 THEN
    RAISE EXCEPTION 'COMMAND_RESULT_TOO_LARGE';
  END IF;

  SELECT d.id, d.org_id INTO did, oid
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;

  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  normalized_status := CASE
    WHEN p_status IN ('acknowledged','completed','failed','expired') THEN p_status
    ELSE 'acknowledged'
  END;

  SELECT * INTO command_row
  FROM public.device_commands
  WHERE id = p_command_id
    AND device_id = did
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'COMMAND_NOT_FOUND'; END IF;

  -- Duplicate ACK/retry: same state must not emit another log or audit row.
  IF command_row.status = normalized_status THEN
    RETURN jsonb_build_object(
      'ok', true,
      'command_id', p_command_id,
      'status', command_row.status,
      'duplicate', true
    );
  END IF;

  -- Terminal states are monotonic. A stale acknowledgement must never roll
  -- completed/failed/expired commands back to acknowledged or another terminal state.
  IF command_row.status IN ('completed','failed','expired') THEN
    RETURN jsonb_build_object(
      'ok', true,
      'command_id', p_command_id,
      'status', command_row.status,
      'duplicate', true,
      'ignored', true,
      'status_conflict', true
    );
  END IF;

  UPDATE public.device_commands
  SET status = normalized_status,
      acknowledged_at = CASE
        WHEN normalized_status = 'acknowledged' THEN coalesce(acknowledged_at, now())
        ELSE acknowledged_at
      END,
      completed_at = CASE
        WHEN normalized_status IN ('completed','failed','expired') THEN coalesce(completed_at, now())
        ELSE completed_at
      END,
      result = coalesce(p_result, '{}'::jsonb)
  WHERE id = p_command_id
    AND device_id = did;

  INSERT INTO public.device_command_logs(command_id, org_id, device_id, status, result)
  VALUES (p_command_id, oid, did, normalized_status, coalesce(p_result, '{}'::jsonb));

  INSERT INTO public.audit_logs(org_id, actor_device_id, action, target_type, target_id, payload)
  VALUES (
    oid, did, 'device_command_ack', 'device_command', p_command_id::text,
    jsonb_build_object('status', normalized_status, 'result', p_result)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'command_id', p_command_id,
    'status', normalized_status,
    'duplicate', false
  );
END
$function$;