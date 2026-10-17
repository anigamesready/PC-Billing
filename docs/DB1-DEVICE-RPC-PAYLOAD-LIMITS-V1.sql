-- DB1 live definitions after device_rpc_payload_limits_v1 + device_sync_payload_preflight_v1.
-- These replace the live PostgreSQL definitions and must be applied only after reviewing this
-- project's current functions/migration history. Limits:
-- device_sync: max 100 events, <=512 KiB batch
-- device_heartbeat: JSON object metadata <=32 KiB, app_version <=120 chars
-- device_ack: result <=32 KiB
-- device_finalize_trial: result <=32 KiB
-- device_emit_admin_alert: payload <=16 KiB
CREATE OR REPLACE FUNCTION api.device_sync(p_token text, p_events jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
declare did uuid; oid uuid; item jsonb; accepted jsonb:='[]'::jsonb; sid text; inserted_count integer:=0;
 rid uuid; tid uuid; evtype text; c text; base_updated timestamptz; existing_updated timestamptz;
begin
 if jsonb_typeof(coalesce(p_events,'[]'::jsonb))<>'array' then raise exception 'EVENTS_MUST_BE_ARRAY'; end if;
 if jsonb_array_length(coalesce(p_events,'[]'::jsonb))>100 then raise exception 'EVENT_BATCH_TOO_LARGE'; end if;
 if pg_column_size(coalesce(p_events,'[]'::jsonb))>524288 then raise exception 'EVENT_BATCH_TOO_LARGE'; end if;
 select d.id,d.org_id into did,oid from public.device_tokens t join public.devices d on d.id=t.device_id
 where t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') and t.revoked_at is null;
 if did is null then raise exception 'INVALID_DEVICE_TOKEN'; end if;
 for item in select value from jsonb_array_elements(coalesce(p_events,'[]'::jsonb)) loop
  sid:=nullif(trim(item->>'sourceEventId'),''); if sid is null then continue; end if;
  evtype:=coalesce(nullif(item->>'eventType',''),'system'); c:=upper(trim(coalesce(item->>'code','')));
  if evtype='rental_account_upsert' and c<>'' then
    base_updated:=nullif(item->'payload'->>'baseUpdatedAt','')::timestamptz;
    select updated_at into existing_updated from public.rental_accounts where org_id=oid and code=c and (device_id is null or device_id=did)
      order by case when device_id=did then 0 else 1 end,created_at desc limit 1;
    if base_updated is not null and existing_updated is not null and existing_updated>base_updated then
      accepted:=accepted||jsonb_build_array(sid); continue;
    end if;
    select id,theme_id into rid,tid from public.rental_accounts where org_id=oid and code=c and (device_id is null or device_id=did)
      order by case when device_id=did then 0 else 1 end,created_at desc limit 1;
    if tid is null then select theme_id into tid from public.organizations where id=oid; end if;
    if rid is null then
      insert into public.rental_accounts(org_id,device_id,code,category,remaining_seconds,expiry_at,status,client_label,theme_id,metadata)
      values(oid,did,c,coalesce(nullif(item->>'category',''),'reguler'),greatest(0,coalesce((item->>'remainingSeconds')::bigint,0)),
      nullif(item->>'expiryDate','')::timestamptz,'active',nullif(item->>'clientLabel',''),tid,jsonb_build_object('source','pc-sync')) returning id into rid;
    else
      update public.rental_accounts set device_id=did,category=coalesce(nullif(item->>'category',''),category),
      remaining_seconds=greatest(0,coalesce((item->>'remainingSeconds')::bigint,0)),expiry_at=nullif(item->>'expiryDate','')::timestamptz,
      status='active',client_label=coalesce(nullif(item->>'clientLabel',''),client_label),updated_at=now() where id=rid;
    end if;
    accepted:=accepted||jsonb_build_array(sid); inserted_count:=inserted_count+1; continue;
  end if;
  if evtype='rental_account_delete' and c<>'' then
    update public.rental_accounts set status='disabled',updated_at=now() where org_id=oid and device_id=did and code=c;
    accepted:=accepted||jsonb_build_array(sid); inserted_count:=inserted_count+1; continue;
  end if;
  select id,theme_id into rid,tid from public.rental_accounts where org_id=oid and code=c and (device_id is null or device_id=did)
    order by case when device_id=did then 0 else 1 end,created_at desc limit 1;
  if tid is null then select theme_id into tid from public.organizations where id=oid; end if;
  insert into public.usage_events(org_id,device_id,rental_session_id,rental_account_id,theme_id,event_type,data_class,occurred_at,duration_seconds,category,client_label,payload,source_event_id,reseller_org_id)
  values(oid,did,case when nullif(item->>'sessionId','') is null then null else (item->>'sessionId')::uuid end,rid,tid,evtype,
  coalesce(nullif(item->>'dataClass',''),'system'),coalesce((item->>'occurredAt')::timestamptz,now()),
  greatest(0,coalesce((item->>'durationSeconds')::integer,0)),nullif(item->>'category',''),nullif(item->>'clientLabel',''),
  coalesce(item->'payload','{}'::jsonb),sid,oid) on conflict (org_id,source_event_id) where source_event_id is not null do nothing;
  if found then inserted_count:=inserted_count+1; end if; accepted:=accepted||jsonb_build_array(sid);
 end loop;
 update public.devices set last_seen_at=now(),status='online' where id=did;
 return jsonb_build_object('acceptedSourceEventIds',accepted,'inserted',inserted_count,'serverTime',now());
end $function$;

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
  IF jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'DEVICE_METADATA_MUST_BE_OBJECT'; END IF;
  IF pg_column_size(coalesce(p_metadata, '{}'::jsonb)) > 32768 THEN RAISE EXCEPTION 'DEVICE_METADATA_TOO_LARGE'; END IF;
  IF length(coalesce(p_app_version, '')) > 120 THEN RAISE EXCEPTION 'DEVICE_APP_VERSION_TOO_LONG'; END IF;

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
$function$;

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

CREATE OR REPLACE FUNCTION api.device_finalize_trial(p_token text, p_command_id uuid, p_status text, p_result jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  req public.device_trial_requests%rowtype;
  existing_session public.rental_sessions%rowtype;
  sid uuid;
  org uuid;
  reused boolean := false;
BEGIN
  IF pg_column_size(coalesce(p_result, '{}'::jsonb)) > 32768 THEN RAISE EXCEPTION 'TRIAL_RESULT_TOO_LARGE'; END IF;
  SELECT dt.device_id INTO did
  FROM public.device_tokens dt
  WHERE dt.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND dt.revoked_at IS NULL
  LIMIT 1;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  SELECT * INTO req
  FROM public.device_trial_requests
  WHERE command_id = p_command_id
    AND device_id = did
    AND status = 'queued'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'TRIAL_REQUEST_NOT_QUEUED');
  END IF;

  SELECT d.org_id INTO org FROM public.devices d WHERE d.id = did;

  IF p_status <> 'completed' THEN
    UPDATE public.device_trial_requests
    SET status = 'failed',
        finished_at = now(),
        result = coalesce(p_result, '{}'::jsonb)
    WHERE id = req.id;
    RETURN jsonb_build_object('ok', true, 'trial_request_id', req.id, 'status', 'failed');
  END IF;

  -- Heartbeat can create the __TEST10__ session before the final ACK reaches
  -- the server. Adopt that session instead of treating our own trial as conflict.
  SELECT * INTO existing_session
  FROM public.rental_sessions s
  WHERE s.device_id = did
    AND s.status IN ('active', 'paused')
  ORDER BY s.started_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF existing_session.code <> '__TEST10__' OR existing_session.session_type <> 'free_test' THEN
      UPDATE public.device_trial_requests
      SET status = 'failed',
          finished_at = now(),
          result = coalesce(p_result, '{}'::jsonb) || jsonb_build_object('error', 'SESSION_CONFLICT_AFTER_QUEUE')
      WHERE id = req.id;
      RETURN jsonb_build_object('ok', false, 'error', 'SESSION_CONFLICT_AFTER_QUEUE');
    END IF;
    sid := existing_session.id;
    reused := true;
  ELSE
    INSERT INTO public.rental_sessions(
      org_id, device_id, code, session_type, started_at, deadline_at, status, metadata
    ) VALUES (
      org, did, '__TEST10__', 'free_test', now(), now() + interval '10 minutes',
      'active', jsonb_build_object('source', 'web_admin', 'trial_request_id', req.id)
    )
    RETURNING id INTO sid;
  END IF;

  -- The billing record is idempotent if heartbeat and ACK race.
  IF NOT EXISTS (
    SELECT 1 FROM public.billing_transactions bt
    WHERE bt.rental_session_id = sid AND bt.transaction_type = 'free_test'
  ) THEN
    INSERT INTO public.billing_transactions(
      org_id, device_id, rental_session_id, transaction_type, amount, duration_seconds,
      actor_user_id, reference, metadata
    ) VALUES (
      org, did, sid, 'free_test', 0, 600, req.created_by, 'ADMIN-TRIAL',
      jsonb_build_object('source', 'web_admin', 'trial_request_id', req.id)
    );
  END IF;

  UPDATE public.device_trial_requests
  SET status = 'started',
      session_id = sid,
      started_at = coalesce(existing_session.started_at, now()),
      finished_at = now(),
      result = coalesce(p_result, '{}'::jsonb)
        || jsonb_build_object('reused_heartbeat_session', reused)
  WHERE id = req.id;

  RETURN jsonb_build_object(
    'ok', true, 'trial_request_id', req.id, 'session_id', sid, 'reused_session', reused
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.device_emit_admin_alert(p_token text, p_event_id text, p_event_type text, p_message text, p_payload jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  device_row public.devices%ROWTYPE;
  event_id uuid;
  safe_message text;
  safe_payload jsonb;
BEGIN
  IF pg_column_size(coalesce(p_payload, '{}'::jsonb)) > 16384 THEN RAISE EXCEPTION 'ADMIN_ALERT_PAYLOAD_TOO_LARGE'; END IF;
  IF coalesce(trim(p_token), '') = '' THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF coalesce(trim(p_event_id), '') = '' OR length(p_event_id) > 120 THEN RAISE EXCEPTION 'INVALID_EVENT_ID'; END IF;
  IF p_event_type NOT IN ('session_expired', 'session_stopped') THEN RAISE EXCEPTION 'INVALID_ADMIN_ALERT_TYPE'; END IF;
  safe_message := left(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'), 240);
  IF safe_message = '' THEN RAISE EXCEPTION 'EMPTY_ADMIN_ALERT_MESSAGE'; END IF;

  SELECT d.* INTO device_row
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(trim(p_token), 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  safe_payload := CASE WHEN jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) = 'object'
    THEN coalesce(p_payload, '{}'::jsonb) ELSE '{}'::jsonb END;

  INSERT INTO public.admin_alert_events(
    org_id, device_id, source_event_id, event_type, message, payload, occurred_at
  )
  VALUES(
    device_row.org_id, device_row.id, trim(p_event_id), p_event_type, safe_message,
    safe_payload, coalesce(p_occurred_at, now())
  )
  ON CONFLICT (device_id, source_event_id) DO NOTHING
  RETURNING id INTO event_id;

  -- Keep this small event table bounded. This cleanup is event-triggered, not a timer/log loop.
  DELETE FROM public.admin_alert_events
  WHERE created_at < now() - interval '30 days';

  RETURN jsonb_build_object('accepted', true, 'duplicate', event_id IS NULL);
END
$function$;