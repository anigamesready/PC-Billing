-- Billing starts at the first successful Moonlight stream connection, never at PC selection.
-- Runs only against a fresh disposable PostgreSQL CI database.
DO $$
DECLARE
  login_result jsonb;
  host_permission jsonb;
  rental_permission jsonb;
  host_enrollment jsonb;
  host_enroll_result jsonb;
  host_heartbeat jsonb;
  client_credential jsonb;
  client_login jsonb;
  preconnect_request jsonb;
  preconnect_end jsonb;
  connected_request jsonb;
  host_ack jsonb;
  connected_first jsonb;
  connected_again jsonb;
  stream_end jsonb;
  owner_token text;
  host_token text;
  client_token text;
  activation_code text;
  org_id uuid;
  device_id uuid;
  rental_id uuid;
  preconnect_session_id uuid;
  connected_session_id uuid;
  preconnect_balance bigint;
  balance_after_cancel bigint;
  balance_after_stream bigint;
  stream_started timestamptz;
  deadline_first timestamptz;
  deadline_again timestamptz;
  used_seconds bigint;
BEGIN
  login_result := api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  owner_token := login_result->>'token';
  org_id := (login_result->>'org_id')::uuid;
  IF coalesce(owner_token,'')='' OR org_id IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_CLOCK_OWNER_LOGIN_FAILED';
  END IF;

  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(org_id,'CI-REMOTE-PLAY-CLOCK-HOST','CI Remote Play Billing Clock PC','online')
  RETURNING id INTO device_id;

  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status,client_label,expiry_at)
  VALUES(org_id,'CI-REMOTE-PLAY-CLOCK-RENTAL','reguler',14400,'active',
    'CI Remote Play Billing Clock',now()+interval '7 days')
  RETURNING id INTO rental_id;
  SELECT remaining_seconds INTO preconnect_balance
  FROM public.rental_accounts WHERE id=rental_id;

  host_permission := api.admin_remote_play_set_host_permission(owner_token,device_id,true);
  rental_permission := api.admin_remote_play_set_rental_permission(owner_token,rental_id,true);
  IF host_permission->>'enabled'<>'true' OR rental_permission->>'enabled'<>'true' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_CLOCK_PERMISSION_SETUP_FAILED';
  END IF;

  host_enrollment := api.admin_remote_play_issue_host_enrollment(owner_token,device_id,15);
  host_enroll_result := api.remote_play_host_enroll(host_enrollment->>'enrollment_code','ci-billing-clock');
  host_token := host_enroll_result->>'host_token';
  IF length(coalesce(host_token,''))<>64 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_CLOCK_HOST_ENROLL_FAILED';
  END IF;
  host_heartbeat := api.remote_play_host_heartbeat(host_token,true,'100.96.24.45'::inet,'ci-billing-clock');
  IF host_heartbeat->>'sunshine_ready'<>'true' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_CLOCK_HOST_NOT_READY';
  END IF;

  client_credential := api.admin_remote_play_issue_client_credential(owner_token,rental_id);
  activation_code := client_credential->>'activation_code';
  client_login := api.remote_play_login(
    'CI-REMOTE-PLAY-CLOCK-RENTAL',activation_code,'CI-REMOTE-PLAY-CLOCK-CLIENT'
  );
  client_token := client_login->>'access_token';
  IF length(coalesce(client_token,''))<>64 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_CLOCK_CLIENT_LOGIN_FAILED';
  END IF;

  -- Aborting during pairing must settle without charging or starting cooldown.
  preconnect_request := api.remote_play_request_session(
    client_token,device_id,'ci-preconnect-cancel-'||rental_id::text
  );
  preconnect_session_id := (preconnect_request->>'session_id')::uuid;
  preconnect_end := api.remote_play_end_session(client_token,preconnect_session_id,'ci_preconnect_cancel');
  SELECT remaining_seconds INTO balance_after_cancel
  FROM public.rental_accounts WHERE id=rental_id;
  IF coalesce((preconnect_end->>'settled_seconds')::bigint,-1)<>0
     OR balance_after_cancel<>preconnect_balance
     OR (SELECT settled_seconds FROM remote_play.sessions WHERE id=preconnect_session_id)<>0
     OR (SELECT cooldown_until FROM remote_play.sessions WHERE id=preconnect_session_id) IS NOT NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PRECONNECT_CANCEL_WAS_CHARGED_OR_COOLDOWN_APPLIED';
  END IF;

  -- A second session is allowed immediately because the prior attempt never streamed.
  PERFORM api.remote_play_host_heartbeat(host_token,true,'100.96.24.45'::inet,'ci-billing-clock');
  connected_request := api.remote_play_request_session(
    client_token,device_id,'ci-connected-session-'||rental_id::text
  );
  connected_session_id := (connected_request->>'session_id')::uuid;
  host_ack := api.remote_play_host_ack(
    host_token,(connected_request->>'command_id')::uuid,'completed',
    jsonb_build_object('session_id',connected_session_id,'ci',true)
  );
  IF host_ack->>'status'<>'completed' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_CLOCK_HOST_START_ACK_FAILED';
  END IF;

  connected_first := api.remote_play_session_connected(client_token,connected_session_id);
  IF coalesce((connected_first->>'ok')::boolean,false) IS NOT TRUE
     OR connected_first->>'status'<>'active'
     OR connected_first->>'stream_started_at' IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_STREAM_CONNECTED_EVENT_FAILED: %',connected_first;
  END IF;
  stream_started := (connected_first->>'stream_started_at')::timestamptz;
  deadline_first := (connected_first->>'deadline_at')::timestamptz;
  IF deadline_first>stream_started+interval '3 hours'
     OR deadline_first<=stream_started THEN
    RAISE EXCEPTION 'REMOTE_PLAY_STREAM_DEADLINE_NOT_BOUNDED_TO_THREE_HOURS';
  END IF;

  -- Duplicate connection callbacks must not restart the billing clock.
  PERFORM pg_sleep(0.05);
  connected_again := api.remote_play_session_connected(client_token,connected_session_id);
  deadline_again := (connected_again->>'deadline_at')::timestamptz;
  IF coalesce((connected_again->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce((connected_again->>'idempotent')::boolean,false) IS NOT TRUE
     OR (connected_again->>'stream_started_at')::timestamptz<>stream_started
     OR deadline_again<>deadline_first THEN
    RAISE EXCEPTION 'REMOTE_PLAY_STREAM_CONNECTED_EVENT_NOT_IDEMPOTENT';
  END IF;

  -- Move the event time backwards to simulate about 50 seconds of real stream time.
  UPDATE remote_play.sessions
  SET stream_started_at=now()-interval '50 seconds',
      started_at=now()-interval '50 seconds'
  WHERE id=connected_session_id;

  stream_end := api.remote_play_end_session(client_token,connected_session_id,'ci_stream_end');
  used_seconds := (stream_end->>'settled_seconds')::bigint;
  SELECT remaining_seconds INTO balance_after_stream
  FROM public.rental_accounts WHERE id=rental_id;
  IF used_seconds NOT BETWEEN 48 AND 55 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_STREAM_USAGE_SECONDS_NOT_MATCHING_TEST_WINDOW: %',used_seconds;
  END IF;
  IF balance_after_stream<>preconnect_balance-used_seconds THEN
    RAISE EXCEPTION 'REMOTE_PLAY_STREAM_USAGE_NOT_DEDUCTED_FROM_RENTAL_BALANCE';
  END IF;
  IF (SELECT cooldown_until FROM remote_play.sessions WHERE id=connected_session_id) IS NULL
     OR (SELECT cooldown_until FROM remote_play.sessions WHERE id=connected_session_id)<=now()
     OR (SELECT cooldown_until FROM remote_play.sessions WHERE id=connected_session_id)>now()+interval '10 minutes 5 seconds' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_STREAM_COOLDOWN_NOT_APPLIED';
  END IF;
END;
$$;

SELECT 'PASS: aborted pre-stream sessions are free; first successful stream connection starts the capped billing clock idempotently' AS result;
