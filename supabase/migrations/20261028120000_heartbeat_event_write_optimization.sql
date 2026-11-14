-- Event-driven heartbeat history plus bounded liveness/session writes.
-- No existing data is deleted. DB route, pairing tokens, and role checks are untouched.
DO $migration$
DECLARE
  v_definition text := pg_get_functiondef('api.device_heartbeat(text,text,jsonb)'::regprocedure);
  v_old text;
  v_new text;
BEGIN
  IF position('HEARTBEAT_EVENT_WRITE_OPTIMIZATION_V1' in v_definition) > 0 THEN RETURN; END IF;

  v_old := $old$  open_sid uuid;
  open_code text;$old$;
  v_new := $new$  open_sid uuid;
  open_code text;
  open_status text;
  open_account_id uuid;
  open_remaining bigint;
  open_last_client_at timestamptz;
  open_theme_id uuid;
  state_changed boolean := false;
  liveness_due boolean := false;
  free_test_blocked boolean := false;$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_DECLARATIONS_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$BEGIN
  IF jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'DEVICE_METADATA_MUST_BE_OBJECT'; END IF;$old$;
  v_new := $new$BEGIN
  -- HEARTBEAT_EVENT_WRITE_OPTIMIZATION_V1
  IF jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'DEVICE_METADATA_MUST_BE_OBJECT'; END IF;$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_MARKER_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$  UPDATE public.devices
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
  END IF;$old$;
  v_new := $new$  state_changed :=
       d.status IS DISTINCT FROM 'online'
    OR d.power_state IS DISTINCT FROM 'online'
    OR d.app_version IS DISTINCT FROM coalesce(p_app_version, d.app_version)
    OR coalesce(d.metadata->>'clientId','') IS DISTINCT FROM coalesce(p_metadata->>'clientId','')
    OR coalesce(d.metadata->>'rentalSyncReady','') IS DISTINCT FROM coalesce(p_metadata->>'rentalSyncReady','')
    OR coalesce(d.metadata->>'activeCode','') IS DISTINCT FROM coalesce(p_metadata->>'activeCode','')
    OR coalesce(d.metadata->>'pausedCode','') IS DISTINCT FROM coalesce(p_metadata->>'pausedCode','')
    OR coalesce(d.metadata->>'activeCategory','') IS DISTINCT FROM coalesce(p_metadata->>'activeCategory','')
    OR coalesce(d.metadata->>'activeExpiryDate','') IS DISTINCT FROM coalesce(p_metadata->>'activeExpiryDate','')
    OR coalesce(d.metadata->>'activeClientLabel','') IS DISTINCT FROM coalesce(p_metadata->>'activeClientLabel','')
    OR coalesce(d.metadata #>> '{shutdownTimer,state}','') IS DISTINCT FROM coalesce(p_metadata #>> '{shutdownTimer,state}','')
    OR coalesce(d.metadata #>> '{shutdownTimer,scheduleId}','') IS DISTINCT FROM coalesce(p_metadata #>> '{shutdownTimer,scheduleId}','')
    OR coalesce(d.metadata #>> '{shutdownTimer,deadlineAt}','') IS DISTINCT FROM coalesce(p_metadata #>> '{shutdownTimer,deadlineAt}','');

  liveness_due := d.last_heartbeat_at IS NULL
    OR d.last_heartbeat_at <= now() - interval '30 seconds';

  IF state_changed OR liveness_due OR d.last_seen_at IS NULL THEN
    UPDATE public.devices
    SET status = 'online',
        power_state = 'online',
        app_version = coalesce(p_app_version, app_version),
        last_seen_at = now(),
        last_heartbeat_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || coalesce(p_metadata, '{}'::jsonb)
    WHERE id = d.id;
  END IF;

  -- Historical heartbeat table is event-only; stable polling cycles do not create log rows.
  IF state_changed OR d.last_heartbeat_at IS NULL THEN
    INSERT INTO public.device_heartbeats(device_id, org_id, app_version, metadata)
    VALUES (d.id, d.org_id, p_app_version, coalesce(p_metadata, '{}'::jsonb));
  END IF;$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_DEVICE_WRITE_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$  SELECT s.id, s.code INTO open_sid, open_code
  FROM public.rental_sessions s
  WHERE s.device_id = d.id AND s.status IN ('active', 'paused')
  ORDER BY s.started_at DESC
  LIMIT 1 FOR UPDATE;$old$;
  v_new := $new$  SELECT s.id, s.code, s.status, s.rental_account_id,
         s.last_client_remaining_seconds, s.last_client_at, s.theme_id
  INTO open_sid, open_code, open_status, open_account_id,
       open_remaining, open_last_client_at, open_theme_id
  FROM public.rental_sessions s
  WHERE s.device_id = d.id AND s.status IN ('active', 'paused')
  ORDER BY s.started_at DESC
  LIMIT 1 FOR UPDATE;$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_SESSION_SELECT_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$  IF target_code IS NULL THEN
    IF open_sid IS NOT NULL THEN
      UPDATE public.rental_sessions
      SET status = 'ended',
          ended_at = now(),
          last_client_at = now(),
          last_client_remaining_seconds = 0
      WHERE id = open_sid;
    END IF;
  ELSE$old$;
  v_new := $new$  IF target_code = '__TEST10__'
     AND NOT private.is_free_test_10m_enabled()
     AND (open_sid IS NULL OR open_code IS DISTINCT FROM '__TEST10__') THEN
    free_test_blocked := true;
  END IF;

  -- Do not roll back device liveness/command delivery when a stale client reports a denied test.
  -- Existing test sessions may finish; the trigger remains the authorization boundary for any new test-session insert.
  IF NOT free_test_blocked THEN
  IF target_code IS NULL THEN
    IF open_sid IS NOT NULL THEN
      UPDATE public.rental_sessions
      SET status = 'ended',
          ended_at = now(),
          last_client_at = now(),
          last_client_remaining_seconds = 0
      WHERE id = open_sid;
    END IF;
  ELSE$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_TEST_GUARD_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$      ELSE
        UPDATE public.rental_accounts
        SET device_id = d.id,
            category = target_category,
            remaining_seconds = target_remaining,
            expiry_at = target_expiry,
            status = CASE WHEN target_remaining > 0 THEN 'active' ELSE status END,
            client_label = coalesce(target_label, client_label),
            updated_at = now()
        WHERE id = rid;
      END IF;$old$;
  v_new := $new$      ELSE
        UPDATE public.rental_accounts
        SET device_id = d.id,
            category = target_category,
            remaining_seconds = target_remaining,
            expiry_at = target_expiry,
            status = CASE WHEN target_remaining > 0 THEN 'active' ELSE status END,
            client_label = coalesce(target_label, client_label),
            updated_at = now()
        WHERE id = rid
          AND (
            device_id IS DISTINCT FROM d.id
            OR category IS DISTINCT FROM target_category
            OR expiry_at IS DISTINCT FROM target_expiry
            OR (target_label IS NOT NULL AND client_label IS DISTINCT FROM target_label)
            OR status IS DISTINCT FROM (CASE WHEN target_remaining > 0 THEN 'active' ELSE status END)
            OR (
              remaining_seconds IS DISTINCT FROM target_remaining
              AND (
                abs(coalesce(remaining_seconds,0)-target_remaining) >= 30
                OR target_remaining <= 30
                OR coalesce(remaining_seconds,0) <= 30
              )
            )
          );
      END IF;$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_ACCOUNT_UPDATE_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$    ELSIF open_code = target_code THEN
      UPDATE public.rental_sessions
      SET rental_account_id = rid,
          status = target_status,
          last_client_at = now(),
          deadline_at = now() + make_interval(secs => target_remaining),
          last_client_remaining_seconds = target_remaining,
          metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('source', 'pc-heartbeat'),
          theme_id = tid
      WHERE id = open_sid;$old$;
  v_new := $new$    ELSIF open_code = target_code THEN
      IF open_status IS DISTINCT FROM target_status
         OR open_account_id IS DISTINCT FROM rid
         OR open_theme_id IS DISTINCT FROM tid
         OR (
           open_remaining IS DISTINCT FROM target_remaining
           AND (
             abs(coalesce(open_remaining,0)-target_remaining) >= 30
             OR target_remaining <= 30
             OR coalesce(open_remaining,0) <= 30
           )
         )
         OR open_last_client_at IS NULL
         OR open_last_client_at <= now() - interval '60 seconds' THEN
        UPDATE public.rental_sessions
        SET rental_account_id = rid,
            status = target_status,
            last_client_at = now(),
            deadline_at = now() + make_interval(secs => target_remaining),
            last_client_remaining_seconds = target_remaining,
            metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('source', 'pc-heartbeat'),
            theme_id = tid
        WHERE id = open_sid;
      END IF;$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_SESSION_UPDATE_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$  END IF;

  WITH claimed AS ($old$;
  v_new := $new$  END IF;
  END IF;

  WITH claimed AS ($new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_SESSION_GUARD_CLOSE_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  v_old := $old$    'server_time', now(),
    'power_state', 'online'
  );$old$;
  v_new := $new$    'server_time', now(),
    'power_state', 'online',
    'free_test_disabled', free_test_blocked,
    'free_test_message', CASE WHEN free_test_blocked
      THEN 'Silahkan hubungi admin untuk melakukan tes 082298316902'
      ELSE NULL END
  );$new$;
  IF length(v_definition)-length(replace(v_definition,v_old,'')) <> length(v_old) THEN RAISE EXCEPTION 'HEARTBEAT_OPTIMIZATION_ANCHOR_RESPONSE_MISMATCH'; END IF;
  v_definition := replace(v_definition,v_old,v_new);

  EXECUTE v_definition;
END;
$migration$;
