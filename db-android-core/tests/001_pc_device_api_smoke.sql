-- DB Android PC-device core smoke + safety regression tests.
-- Runs only against a disposable CI PostgreSQL database with synthetic rows.
DO $$
DECLARE
  v_org uuid;
  v_device1 uuid;
  v_device2 uuid;
  v_rental uuid;
  v_command uuid;
  v_token1 text;
  v_token2 text;
  v_pair jsonb;
  v_hb jsonb;
  v_lookup jsonb;
  v_start jsonb;
  v_end jsonb;
  v_alert1 jsonb;
  v_alert2 jsonb;
  v_rate jsonb;
  v_sync1 jsonb;
  v_sync2 jsonb;
  v_pull jsonb;
  v_ack jsonb;
  v_watchdog jsonb;
  v_cursor timestamptz;
  v_error text;
BEGIN
  -- Verify the expected business schema and PC API functions exist.
  IF (SELECT count(*) FROM information_schema.tables
      WHERE table_schema='public' AND table_type='BASE TABLE') <> 24 THEN
    RAISE EXCEPTION 'EXPECTED_24_CORE_TABLES';
  END IF;
  IF (SELECT count(*) FROM pg_proc p JOIN pg_namespace n ON n.oid=p.pronamespace
      WHERE n.nspname='api' AND p.proname IN (
        'device_ack','device_disconnect','device_emit_admin_alert','device_end_rental_session',
        'device_finalize_trial','device_free_test_policy','device_heartbeat',
        'device_pairing_rate_limit_clear','device_pairing_rate_limit_consume','device_pull_sync',
        'device_release_rental_lease','device_rental_lookup','device_rentals_snapshot',
        'device_start_rental_session','device_sync','device_sync_cursor','device_watchdog_poll','redeem_device'
      )) <> 18 THEN
    RAISE EXCEPTION 'EXPECTED_18_PC_DEVICE_FUNCTIONS';
  END IF;

  INSERT INTO public.organizations(name,slug,kind,status)
  VALUES ('CI Ani Games','ci-anigames','owner','active')
  RETURNING id INTO v_org;

  -- A new local database must not silently enable the 10-minute free test.
  IF private.is_free_test_10m_enabled() THEN
    RAISE EXCEPTION 'FREE_TEST_MUST_DEFAULT_DISABLED';
  END IF;
  BEGIN
    INSERT INTO public.rental_sessions(org_id,code,session_type,started_at,status)
    VALUES(v_org,'__TEST10__','free_test',now(),'active');
    RAISE EXCEPTION 'EXPECTED_FREE_TEST_BLOCK_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'FREE_TEST_DISABLED' THEN RAISE; END IF;
  END;

  -- Enabling the feature explicitly allows a free-test session and trial request.
  UPDATE private.admin_feature_settings SET enabled=true,updated_at=now()
  WHERE feature_key='free_test_10m_enabled';
  INSERT INTO public.rental_sessions(org_id,code,session_type,started_at,status)
  VALUES(v_org,'__TEST10__','free_test',now(),'active');
  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(v_org,'CI-PC-TRIAL','CI PC Trial','offline') RETURNING id INTO v_device2;
  INSERT INTO public.device_trial_requests(org_id,device_id,status)
  VALUES(v_org,v_device2,'queued');
  UPDATE private.admin_feature_settings SET enabled=false,updated_at=now()
  WHERE feature_key='free_test_10m_enabled';

  -- Pairing redemption issues a raw token once and stores only its SHA-256 hash.
  INSERT INTO public.device_enrollments(org_id,code_hash,label,expires_at)
  VALUES(v_org,encode(extensions.digest('PAIR-CI-TEST','sha256'),'hex'),'CI enrollment',now()+interval '10 minutes');
  v_pair := api.redeem_device('PAIR-CI-TEST','CI-PC-1','CI PC 1','CI-test');
  v_token1 := v_pair->>'token';
  v_device1 := (v_pair->>'device_id')::uuid;
  IF coalesce(v_token1,'')='' OR v_device1 IS NULL THEN
    RAISE EXCEPTION 'PAIRING_DID_NOT_ISSUE_DEVICE_TOKEN';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.device_tokens
                WHERE device_id=v_device1
                  AND token_hash=encode(extensions.digest(v_token1,'sha256'),'hex')
                  AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'DEVICE_TOKEN_NOT_HASHED_OR_STORED';
  END IF;

  -- Create a second synthetic device in the same organization for lease/session conflict tests.
  v_token2 := encode(extensions.gen_random_bytes(32),'hex');
  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(v_org,'CI-PC-2','CI PC 2','offline') RETURNING id INTO v_device2;
  INSERT INTO public.device_tokens(device_id,token_hash)
  VALUES(v_device2,encode(extensions.digest(v_token2,'sha256'),'hex'));

  v_hb := api.device_heartbeat(v_token1,'CI-test',
    jsonb_build_object('clientId','CI-PC-1','rentalSyncReady',true));
  IF v_hb->>'device_id' IS DISTINCT FROM v_device1::text
     OR v_hb->>'power_state' IS DISTINCT FROM 'online' THEN
    RAISE EXCEPTION 'HEARTBEAT_RESPONSE_INVALID';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.devices WHERE id=v_device1 AND status='online') THEN
    RAISE EXCEPTION 'HEARTBEAT_DID_NOT_MARK_DEVICE_ONLINE';
  END IF;

  INSERT INTO public.rental_accounts(org_id,device_id,code,category,remaining_seconds,status)
  VALUES(v_org,NULL,'CI-RENTAL','reguler',600,'active')
  RETURNING id INTO v_rental;

  -- Offline lease prevents a second PC from claiming the same rental.
  v_lookup := api.device_rental_lookup(v_token1,'CI-RENTAL');
  IF coalesce((v_lookup->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FIRST_RENTAL_LOOKUP_FAILED';
  END IF;
  BEGIN
    PERFORM api.device_rental_lookup(v_token2,'CI-RENTAL');
    RAISE EXCEPTION 'EXPECTED_OFFLINE_LEASE_CONFLICT_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC' THEN RAISE; END IF;
  END;

  -- One active session per rental/PC; a second PC cannot start it.
  v_start := api.device_start_rental_session(v_token1,'CI-RENTAL','ci-start-1');
  IF coalesce((v_start->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FIRST_RENTAL_SESSION_START_FAILED';
  END IF;
  BEGIN
    PERFORM api.device_start_rental_session(v_token2,'CI-RENTAL','ci-start-2');
    RAISE EXCEPTION 'EXPECTED_ACTIVE_OTHER_PC_CONFLICT_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RENTAL_ACTIVE_ON_OTHER_PC' THEN RAISE; END IF;
  END;

  v_end := api.device_end_rental_session(v_token1,'CI-RENTAL',540,'ci-end-1');
  IF coalesce((v_end->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'RENTAL_SESSION_END_FAILED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.rental_sessions
                WHERE id=(v_start->>'session_id')::uuid AND status='ended') THEN
    RAISE EXCEPTION 'SESSION_STATUS_NOT_ENDED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM public.rental_accounts WHERE id=v_rental AND remaining_seconds=540) THEN
    RAISE EXCEPTION 'RENTAL_REMAINING_TIME_NOT_RECONCILED';
  END IF;

  -- Lease is released after session end; the second PC can now claim the rental.
  v_lookup := api.device_rental_lookup(v_token2,'CI-RENTAL');
  IF coalesce((v_lookup->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'LEASE_NOT_RELEASED_AFTER_SESSION_END';
  END IF;
  v_start := api.device_start_rental_session(v_token2,'CI-RENTAL','ci-start-3');
  v_end := api.device_end_rental_session(v_token2,'CI-RENTAL',500,'ci-end-2');

  -- Pairing rate limit and clearing behavior.
  v_rate := api.device_pairing_rate_limit_consume(repeat('a',64),5);
  IF coalesce((v_rate->>'allowed')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'PAIRING_RATE_LIMIT_INITIAL_REQUEST_REJECTED';
  END IF;
  PERFORM api.device_pairing_rate_limit_clear(ARRAY[repeat('a',64)]);

  -- Sync event idempotency and delta pull.
  v_sync1 := api.device_sync(v_token1,jsonb_build_array(jsonb_build_object(
    'sourceEventId','ci-usage-event-1','eventType','ci_smoke','dataClass','system',
    'occurredAt',now(),'durationSeconds',1,'code','CI-RENTAL','payload',jsonb_build_object('ci',true)
  )));
  v_sync2 := api.device_sync(v_token1,jsonb_build_array(jsonb_build_object(
    'sourceEventId','ci-usage-event-1','eventType','ci_smoke','dataClass','system',
    'occurredAt',now(),'durationSeconds',1,'code','CI-RENTAL','payload',jsonb_build_object('ci',true)
  )));
  IF (SELECT count(*) FROM public.usage_events WHERE org_id=v_org AND source_event_id='ci-usage-event-1') <> 1 THEN
    RAISE EXCEPTION 'SYNC_IDEMPOTENCY_FAILED';
  END IF;
  v_pull := api.device_pull_sync(v_token1,now()-interval '1 day');
  IF jsonb_typeof(v_pull->'rentalAccounts') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'DELTA_PULL_RESPONSE_INVALID';
  END IF;
  v_cursor := (api.device_sync_cursor(v_token1)->>'cursor')::timestamptz;
  IF v_cursor IS NULL THEN RAISE EXCEPTION 'SYNC_CURSOR_MISSING'; END IF;

  -- Admin alert delivery is idempotent by (device_id, source_event_id).
  v_alert1 := api.device_emit_admin_alert(v_token1,'ci-alert-1','session_stopped','CI alert',jsonb_build_object('ci',true),now());
  v_alert2 := api.device_emit_admin_alert(v_token1,'ci-alert-1','session_stopped','CI alert',jsonb_build_object('ci',true),now());
  IF coalesce((v_alert1->>'accepted')::boolean,false) IS NOT TRUE
     OR coalesce((v_alert2->>'duplicate')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_ALERT_IDEMPOTENCY_FAILED';
  END IF;

  -- Command acknowledgement is scoped to the paired device and terminal state is monotonic.
  INSERT INTO public.device_commands(org_id,device_id,command,payload,status)
  VALUES(v_org,v_device1,'restart_billing','{}'::jsonb,'queued')
  RETURNING id INTO v_command;
  v_ack := api.device_ack(v_token1,v_command,'completed',jsonb_build_object('ok',true,'ci',true));
  IF v_ack->>'status' IS DISTINCT FROM 'completed' THEN
    RAISE EXCEPTION 'COMMAND_ACK_FAILED';
  END IF;
  v_watchdog := api.device_watchdog_poll(v_token1);
  IF jsonb_typeof(v_watchdog->'commands') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'WATCHDOG_RESPONSE_INVALID';
  END IF;

  -- The removed automatic countdown must remain unavailable on this local server.
  BEGIN
    INSERT INTO public.device_commands(org_id,device_id,command,payload,status)
    VALUES(v_org,v_device1,'schedule_shutdown','{}'::jsonb,'queued');
    RAISE EXCEPTION 'EXPECTED_SHUTDOWN_TIMER_BLOCK_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'SHUTDOWN_TIMER_DISABLED' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'PASS: PC device DB core schema, pairing, heartbeat, rental lookup/session, offline lease, sync idempotency, alerts, command ack, free-test guard and no-shutdown-timer guard' AS result;
