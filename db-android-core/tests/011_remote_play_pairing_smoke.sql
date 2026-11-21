-- Remote Play / Sunshine pairing schema, privilege and PL/pgSQL entry-point smoke checks.
-- Runs only against a fresh disposable PostgreSQL database in CI.
DO $$
DECLARE
  rls_enabled boolean;
  error_message text;
  v_org_id uuid := gen_random_uuid();
  v_device_id uuid := gen_random_uuid();
  v_rental_id uuid := gen_random_uuid();
  v_client_session_id uuid := gen_random_uuid();
  v_remote_session_id uuid := gen_random_uuid();
  v_pair_session_id uuid := gen_random_uuid();
  v_pair_challenge_id uuid;
  v_client_token text := encode(extensions.gen_random_bytes(32),'hex');
  v_host_token text := encode(extensions.gen_random_bytes(32),'hex');
  watchdog_result jsonb;
  pair_prepare_result jsonb;
  pair_poll_result jsonb;
  pair_complete_result jsonb;
BEGIN
  IF to_regclass('remote_play.pairing_challenges') IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_TABLE_MISSING';
  END IF;

  SELECT c.relrowsecurity INTO rls_enabled
  FROM pg_class c WHERE c.oid='remote_play.pairing_challenges'::regclass;
  IF NOT coalesce(rls_enabled,false) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_RLS_DISABLED';
  END IF;

  IF has_table_privilege('ani_api_runtime','remote_play.pairing_challenges','SELECT')
     OR has_table_privilege('ani_api_runtime','remote_play.pairing_challenges','INSERT')
     OR has_table_privilege('ani_api_runtime','remote_play.pairing_challenges','UPDATE') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_TABLE_LEAKED_TO_RUNTIME_ROLE';
  END IF;

  IF NOT has_function_privilege('ani_api_runtime',
      'api.remote_play_pairing_prepare(text,uuid,text,text,inet)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime',
      'api.remote_play_host_pairing_poll(text,uuid)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime',
      'api.remote_play_host_pairing_complete(text,uuid,uuid,boolean,text,text)','EXECUTE') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_RPC_GRANTS_MISSING';
  END IF;

  -- Exercise login far enough to compile and execute its account-count lookup.
  -- A missing rental must return the documented invalid-credentials error.
  BEGIN
    PERFORM api.remote_play_login('CI-NO-SUCH-RENTAL','0000000000000000','ci-install-remote-play');
    RAISE EXCEPTION 'EXPECTED_REMOTE_PLAY_INVALID_CREDENTIALS';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
    IF error_message <> 'REMOTE_PLAY_INVALID_CREDENTIALS' THEN
      RAISE EXCEPTION 'REMOTE_PLAY_LOGIN_SMOKE_FAILED: %', error_message;
    END IF;
  END;

  -- Exercise a real host watchdog lifecycle in a throwaway tenant. An active session
  -- with no client heartbeat for 90 seconds must be settled and enqueue stop_stream.
  INSERT INTO public.organizations(id,name,slug,kind)
  VALUES(v_org_id,'Remote Play CI','remote-play-ci-'||replace(v_org_id::text,'-',''),'owner');

  INSERT INTO public.devices(id,org_id,client_id,device_name,status)
  VALUES(v_device_id,v_org_id,'REMOTE-PLAY-CI-'||replace(v_device_id::text,'-',''),'CI Sunshine Host','online');

  INSERT INTO public.rental_accounts(id,org_id,code,category,remaining_seconds,status,client_label)
  VALUES(v_rental_id,v_org_id,'RP-CI-'||replace(v_rental_id::text,'-',''),'remote_play',7200,'active','Remote Play CI');

  INSERT INTO remote_play.client_sessions(
    id,rental_account_id,token_hash,refresh_token_hash,client_install_id,expires_at,refresh_expires_at
  ) VALUES(v_client_session_id,v_rental_id,
    encode(extensions.digest(v_client_token,'sha256'),'hex'),
    encode(extensions.digest(v_client_token||'-refresh','sha256'),'hex'),
    'ci-remote-play-install',now()+interval '12 hours',now()+interval '30 days');

  INSERT INTO remote_play.host_permissions(device_id,org_id,enabled)
  VALUES(v_device_id,v_org_id,true);

  INSERT INTO remote_play.host_registrations(
    device_id,org_id,token_hash,agent_version,sunshine_ready,media_address,last_heartbeat_at
  ) VALUES(v_device_id,v_org_id,
    encode(extensions.digest(v_host_token,'sha256'),'hex'),
    'ci-smoke',true,'10.20.30.40'::inet,now());

  INSERT INTO remote_play.sessions(
    id,org_id,rental_account_id,device_id,client_session_id,status,
    started_at,stream_started_at,deadline_at,last_client_heartbeat_at,starting_balance_seconds,idempotency_key
  ) VALUES(v_remote_session_id,v_org_id,v_rental_id,v_device_id,v_client_session_id,'active',
    now()-interval '2 minutes',now()-interval '2 minutes',now()+interval '1 hour',now()-interval '2 minutes',7200,'ci:'||v_remote_session_id::text);

  watchdog_result := api.remote_play_host_heartbeat(v_host_token,true,'10.20.30.40'::inet,'ci-smoke');
  IF NOT coalesce((watchdog_result->>'watchdog_settled')::boolean,false) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_WATCHDOG_DID_NOT_SETTLE_STALE_CLIENT';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM remote_play.sessions
    WHERE id=v_remote_session_id AND status='ended' AND settled_at IS NOT NULL
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_WATCHDOG_SESSION_NOT_SETTLED';
  END IF;
  IF NOT EXISTS (
    SELECT 1 FROM remote_play.commands
    WHERE session_id=v_remote_session_id AND command='stop_stream' AND status='queued'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_WATCHDOG_STOP_COMMAND_NOT_QUEUED';
  END IF;
  IF (SELECT remaining_seconds FROM public.rental_accounts WHERE id=v_rental_id)>=7200 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_WATCHDOG_USAGE_NOT_SETTLED';
  END IF;

  -- Exercise the complete authorized challenge path using distinct client/host tokens.
  INSERT INTO remote_play.sessions(
    id,org_id,rental_account_id,device_id,client_session_id,status,
    started_at,deadline_at,last_client_heartbeat_at,starting_balance_seconds,idempotency_key
  ) VALUES(v_pair_session_id,v_org_id,v_rental_id,v_device_id,v_client_session_id,'active',
    now(),now()+interval '1 hour',now(),7000,'ci-pair:'||v_pair_session_id::text);

  -- An address outside the approved private overlays must never create a challenge.
  BEGIN
    PERFORM api.remote_play_pairing_prepare(
      v_client_token,v_pair_session_id,'1234','ANI-AABBCCDDEEFF','100.95.255.254'::inet
    );
    RAISE EXCEPTION 'REMOTE_PLAY_UNAPPROVED_CLIENT_IP_ACCEPTED';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'REMOTE_PLAY_PAIRING_CLIENT_ADDRESS_INVALID' THEN RAISE; END IF;
  END;

  pair_prepare_result := api.remote_play_pairing_prepare(
    v_client_token,v_pair_session_id,'1234','ANI-AABBCCDDEEFF','100.96.23.45'::inet);
  v_pair_challenge_id := (pair_prepare_result->>'challenge_id')::uuid;
  IF pair_prepare_result->>'status' <> 'pending' OR v_pair_challenge_id IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_PREPARE_DID_NOT_CREATE_CHALLENGE';
  END IF;

  pair_poll_result := api.remote_play_host_pairing_poll(v_host_token,v_pair_session_id);
  IF NOT coalesce((pair_poll_result->>'pending')::boolean,false)
     OR pair_poll_result->>'pin' <> '1234'
     OR pair_poll_result->>'client_name' <> 'ANI-AABBCCDDEEFF'
     OR pair_poll_result->>'expected_client_address' <> '100.96.23.45' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_DID_NOT_RECEIVE_EXACT_PAIRING_CHALLENGE';
  END IF;

  pair_complete_result := api.remote_play_host_pairing_complete(
    v_host_token,v_pair_session_id,v_pair_challenge_id,true,'0123456789abcdef0123456789abcdef',NULL);
  IF pair_complete_result->>'status' <> 'paired' OR NOT EXISTS (
    SELECT 1 FROM remote_play.pairing_challenges
    WHERE id=v_pair_challenge_id AND status='paired'
      AND sunshine_pairing_id='0123456789abcdef0123456789abcdef'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_COMPLETION_NOT_PERSISTED';
  END IF;

  -- Ensure the client/host pairing RPCs compile and reject missing bearer tokens
  -- before reading or returning a PIN/challenge.
  BEGIN
    PERFORM api.remote_play_pairing_prepare(NULL,NULL,NULL,NULL,NULL);
    RAISE EXCEPTION 'EXPECTED_REMOTE_PLAY_AUTH_REQUIRED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
    IF error_message <> 'REMOTE_PLAY_AUTH_REQUIRED' THEN
      RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_PREPARE_SMOKE_FAILED: %', error_message;
    END IF;
  END;

  BEGIN
    PERFORM api.remote_play_host_pairing_poll(NULL,NULL);
    RAISE EXCEPTION 'EXPECTED_REMOTE_PLAY_HOST_AUTH_REQUIRED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
    IF error_message <> 'REMOTE_PLAY_HOST_AUTH_REQUIRED' THEN
      RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_POLL_SMOKE_FAILED: %', error_message;
    END IF;
  END;

  BEGIN
    PERFORM api.remote_play_host_pairing_complete(NULL,NULL,NULL,false,NULL,NULL);
    RAISE EXCEPTION 'EXPECTED_REMOTE_PLAY_HOST_AUTH_REQUIRED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS error_message = MESSAGE_TEXT;
    IF error_message <> 'REMOTE_PLAY_HOST_AUTH_REQUIRED' THEN
      RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_COMPLETE_SMOKE_FAILED: %', error_message;
    END IF;
  END;
END;
$$;

SELECT 'PASS: Remote Play login PL/pgSQL entry point, Sunshine pairing RPC entry points, RLS, and runtime table isolation' AS result;
