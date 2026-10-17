-- Reduce repetitive PC heartbeat history writes without changing live heartbeat checks,
-- command delivery, rental synchronization, or devices.last_heartbeat_at.
CREATE INDEX IF NOT EXISTS device_heartbeats_device_received_at_idx
ON public.device_heartbeats (device_id, received_at DESC);

CREATE OR REPLACE FUNCTION api.device_heartbeat(p_token text, p_app_version text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  d public.devices%rowtype;
  commands jsonb;
  rental_rows jsonb;
  active_code text;
  paused_code text;
  active_remaining bigint;
  paused_remaining bigint;
  active_category text;
  active_expiry timestamptz;
  active_label text;
  target_code text;
  target_status text;
  target_remaining bigint;
  target_category text;
  target_expiry timestamptz;
  target_label text;
  rid uuid;
  tid uuid;
  open_sid uuid;
  open_code text;
BEGIN
  SELECT d0.* INTO d
  FROM public.device_tokens t
  JOIN public.devices d0 ON d0.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL;

  IF d.id IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  UPDATE public.devices
  SET status = 'online',
      power_state = 'online',
      app_version = coalesce(p_app_version, app_version),
      last_seen_at = now(),
      last_heartbeat_at = now(),
      metadata = coalesce(metadata, '{}'::jsonb) || coalesce(p_metadata, '{}'::jsonb)
  WHERE id = d.id;

  -- Keep history rows as minute-level samples; last_heartbeat_at above is still updated every request.
  IF NOT EXISTS (
    SELECT 1
    FROM public.device_heartbeats h
    WHERE h.device_id = d.id
      AND h.received_at > now() - interval '60 seconds'
  ) THEN
    INSERT INTO public.device_heartbeats(device_id, org_id, app_version, metadata)
    VALUES (d.id, d.org_id, p_app_version, coalesce(p_metadata, '{}'::jsonb));
  END IF;

  active_code := upper(nullif(trim(p_metadata->>'activeCode'), ''));
  paused_code := upper(nullif(trim(p_metadata->>'pausedCode'), ''));
  active_remaining := greatest(0, coalesce((p_metadata->>'activeRemainingSeconds')::bigint, 0));
  paused_remaining := greatest(0, coalesce((p_metadata->>'pausedRemainingSeconds')::bigint, 0));
  active_category := coalesce(nullif(trim(p_metadata->>'activeCategory'), ''), 'reguler');
  active_expiry := nullif(p_metadata->>'activeExpiryDate', '')::timestamptz;
  active_label := nullif(trim(p_metadata->>'activeClientLabel'), '');
  target_code := coalesce(active_code, paused_code);
  target_status := CASE WHEN active_code IS NOT NULL THEN 'active'
                        WHEN paused_code IS NOT NULL THEN 'paused' ELSE NULL END;
  target_remaining := CASE WHEN active_code IS NOT NULL THEN active_remaining
                            WHEN paused_code IS NOT NULL THEN paused_remaining ELSE 0 END;
  target_category := active_category;
  target_expiry := active_expiry;
  target_label := active_label;

  SELECT s.id, s.code INTO open_sid, open_code
  FROM public.rental_sessions s
  WHERE s.device_id = d.id AND s.status IN ('active', 'paused')
  ORDER BY s.started_at DESC
  LIMIT 1 FOR UPDATE;

  IF target_code IS NULL THEN
    IF open_sid IS NOT NULL THEN
      UPDATE public.rental_sessions
      SET status = 'ended',
          ended_at = now(),
          last_client_at = now(),
          last_client_remaining_seconds = 0
      WHERE id = open_sid;
    END IF;
  ELSE
    -- The 10-minute trial is a session, not a customer rental account.
    -- Do not create or update a visible rental_accounts row for __TEST10__.
    IF target_code = '__TEST10__' THEN
      rid := NULL;
      SELECT theme_id INTO tid FROM public.organizations WHERE id = d.org_id;
    ELSE
      SELECT ra.id, ra.theme_id INTO rid, tid
      FROM public.rental_accounts ra
      WHERE ra.org_id = d.org_id
        AND ra.code = target_code
        AND (ra.device_id IS NULL OR ra.device_id = d.id)
      ORDER BY CASE WHEN ra.device_id = d.id THEN 0 ELSE 1 END, ra.created_at DESC
      LIMIT 1;

      IF rid IS NULL THEN
        SELECT theme_id INTO tid FROM public.organizations WHERE id = d.org_id;
        INSERT INTO public.rental_accounts(
          org_id, device_id, code, category, remaining_seconds, expiry_at, status,
          client_label, theme_id, metadata
        ) VALUES (
          d.org_id, d.id, target_code, target_category, target_remaining, target_expiry,
          'active', target_label, tid, jsonb_build_object('source', 'pc-heartbeat')
        )
        RETURNING id INTO rid;
      ELSE
        UPDATE public.rental_accounts
        SET device_id = d.id,
            category = target_category,
            remaining_seconds = target_remaining,
            expiry_at = target_expiry,
            status = CASE WHEN target_remaining > 0 THEN 'active' ELSE status END,
            client_label = coalesce(target_label, client_label),
            updated_at = now()
        WHERE id = rid;
      END IF;
    END IF;

    IF open_sid IS NULL THEN
      INSERT INTO public.rental_sessions(
        org_id, device_id, rental_account_id, code, session_type, started_at,
        deadline_at, status, last_client_at, metadata, last_client_remaining_seconds, theme_id
      ) VALUES (
        d.org_id, d.id, rid, target_code,
        CASE WHEN target_code = '__TEST10__' THEN 'free_test' ELSE 'rental' END,
        now(), now() + make_interval(secs => target_remaining), target_status, now(),
        jsonb_build_object('source', 'pc-heartbeat'), target_remaining, tid
      );
    ELSIF open_code = target_code THEN
      UPDATE public.rental_sessions
      SET rental_account_id = rid,
          status = target_status,
          last_client_at = now(),
          deadline_at = now() + make_interval(secs => target_remaining),
          last_client_remaining_seconds = target_remaining,
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('source', 'pc-heartbeat'),
          theme_id = tid
      WHERE id = open_sid;
    ELSE
      UPDATE public.rental_sessions
      SET status = 'ended', ended_at = now(), last_client_at = now()
      WHERE id = open_sid;

      INSERT INTO public.rental_sessions(
        org_id, device_id, rental_account_id, code, session_type, started_at,
        deadline_at, status, last_client_at, metadata, last_client_remaining_seconds, theme_id
      ) VALUES (
        d.org_id, d.id, rid, target_code,
        CASE WHEN target_code = '__TEST10__' THEN 'free_test' ELSE 'rental' END,
        now(), now() + make_interval(secs => target_remaining), target_status, now(),
        jsonb_build_object('source', 'pc-heartbeat'), target_remaining, tid
      );
    END IF;
  END IF;

  WITH claimed AS (
    UPDATE public.device_commands c
    SET status = 'acknowledged',
        acknowledged_at = now(),
        delivered_at = now(),
        delivery_attempts = coalesce(delivery_attempts, 0) + 1
    WHERE c.device_id = d.id AND c.status = 'queued'
    RETURNING c.*
  )
  SELECT coalesce(jsonb_agg(to_jsonb(claimed) ORDER BY claimed.created_at), '[]'::jsonb)
  INTO commands
  FROM claimed;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.updated_at, r.id), '[]'::jsonb)
  INTO rental_rows
  FROM public.rental_accounts r
  WHERE r.org_id = d.org_id
    AND r.device_id = d.id
    AND upper(r.code) <> '__TEST10__';

  RETURN jsonb_build_object(
    'device_id', d.id,
    'org_id', d.org_id,
    'commands', commands,
    'rental_accounts', rental_rows,
    'server_time', now(),
    'power_state', 'online'
  );
END;
$function$
;
