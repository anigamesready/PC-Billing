-- Admin device list/state, activity, rename/disconnect, per-PC rental and free-test policy regressions.
-- Requires the CI owner account created by tests/004_admin_local_auth_smoke.sql.
DO $$
DECLARE
  v_org uuid;
  v_device uuid;
  v_user uuid;
  v_token text;
  v_login jsonb;
  v_policy jsonb;
  v_trial jsonb;
  v_state jsonb;
  v_rename jsonb;
  v_disconnect jsonb;
  v_activity jsonb;
  v_rental uuid;
  v_session uuid;
  v_count integer;
BEGIN
  SELECT id,auth_user_id,org_id INTO v_device,v_user,v_org
  FROM public.admin_accounts WHERE username='CI-OWNER' AND status='active' LIMIT 1;
  IF v_user IS NULL OR v_org IS NULL THEN RAISE EXCEPTION 'CI_ADMIN_ACCOUNT_MISSING'; END IF;

  v_login := api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  v_token := v_login->>'token';
  IF coalesce(v_token,'')='' THEN RAISE EXCEPTION 'ADMIN_LOGIN_FOR_DEVICE_TEST_FAILED'; END IF;

  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(v_org,'CI-ADMIN-SCREEN-PC','CI Admin Screen PC','offline') RETURNING id INTO v_device;
  -- Refresh v_device now refers to the device, not the Admin account row.
  INSERT INTO public.device_tokens(device_id,token_hash)
  VALUES(v_device,encode(extensions.digest('CI-ADMIN-SCREEN-DEVICE-TOKEN','sha256'),'hex'));
  PERFORM api.device_heartbeat('CI-ADMIN-SCREEN-DEVICE-TOKEN','ci',jsonb_build_object('rentalSyncReady',true));

  SELECT count(*) INTO v_count FROM api.admin_devices(v_token,v_org) WHERE id=v_device;
  IF v_count<>1 THEN RAISE EXCEPTION 'ADMIN_DEVICES_LIST_FAILED'; END IF;

  v_state := api.admin_device_state(v_token,v_org,v_device);
  IF coalesce((v_state->>'online')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_DEVICE_STATE_ONLINE_FAILED';
  END IF;

  v_rename := api.admin_rename_device(v_token,v_org,v_device,'CI Admin PC Renamed');
  IF v_rename->>'device_name' IS DISTINCT FROM 'CI Admin PC Renamed'
     OR coalesce((v_rename->>'pairing_token_unchanged')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_DEVICE_RENAME_FAILED';
  END IF;

  v_policy := api.admin_get_free_test_policy(v_token);
  IF coalesce((v_policy->>'enabled')::boolean,true) IS NOT FALSE THEN
    RAISE EXCEPTION 'FREE_TEST_POLICY_MUST_DEFAULT_DISABLED';
  END IF;
  v_policy := api.admin_set_free_test_policy(v_token,true);
  IF coalesce((v_policy->>'enabled')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'FREE_TEST_POLICY_ENABLE_FAILED';
  END IF;
  v_trial := api.admin_start_trial(v_token,v_org,v_device);
  IF coalesce((v_trial->>'ok')::boolean,false) IS NOT TRUE
     OR (v_trial->>'duration_seconds')::integer<>600 THEN
    RAISE EXCEPTION 'ADMIN_START_TRIAL_FAILED';
  END IF;
  PERFORM api.admin_set_free_test_policy(v_token,false);

  INSERT INTO public.rental_accounts(org_id,device_id,code,category,remaining_seconds,status,client_label)
  VALUES(v_org,v_device,'CI-ADMIN-PC-RENTAL','reguler',1200,'active','CI Admin PC Member')
  RETURNING id INTO v_rental;
  SELECT count(*) INTO v_count FROM api.admin_rental_accounts(v_token,v_org,v_device) WHERE id=v_rental;
  IF v_count<>1 THEN RAISE EXCEPTION 'ADMIN_PER_PC_RENTAL_LIST_FAILED'; END IF;

  INSERT INTO public.rental_sessions(org_id,device_id,rental_account_id,code,session_type,started_at,deadline_at,status)
  VALUES(v_org,v_device,v_rental,'CI-ADMIN-PC-RENTAL','rental',now(),now()+interval '20 minutes','active')
  RETURNING id INTO v_session;
  SELECT count(*) INTO v_count FROM api.admin_active_sessions(v_token,v_org) WHERE id=v_session;
  IF v_count<>1 THEN RAISE EXCEPTION 'ADMIN_ACTIVE_SESSIONS_LIST_FAILED'; END IF;

  v_state := api.admin_device_state(v_token,v_org,v_device);
  IF v_state->'session'->>'id' IS DISTINCT FROM v_session::text
     OR v_state->'session'->>'status' IS DISTINCT FROM 'active' THEN
    RAISE EXCEPTION 'ADMIN_DEVICE_STATE_ACTIVE_SESSION_FAILED';
  END IF;

  v_activity := api.admin_activity(v_token,v_org,now()-interval '1 day',now()+interval '1 minute',100);
  IF jsonb_typeof(v_activity->'accounts') IS DISTINCT FROM 'array'
     OR jsonb_typeof(v_activity->'sessions') IS DISTINCT FROM 'array'
     OR jsonb_array_length(v_activity->'sessions')<1 THEN
    RAISE EXCEPTION 'ADMIN_ACTIVITY_FEED_FAILED';
  END IF;

  UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=v_session;
  v_disconnect := api.admin_disconnect_device(v_token,v_org,v_device);
  IF coalesce((v_disconnect->>'ok')::boolean,false) IS NOT TRUE
     OR (v_disconnect->>'revoked_tokens')::integer<>1 THEN
    RAISE EXCEPTION 'ADMIN_DEVICE_DISCONNECT_FAILED';
  END IF;
  v_state := api.admin_device_state(v_token,v_org,v_device);
  IF coalesce((v_state->>'online')::boolean,true) IS NOT FALSE THEN
    RAISE EXCEPTION 'ADMIN_DEVICE_DISCONNECT_DID_NOT_MARK_OFFLINE';
  END IF;
  PERFORM api.admin_logout(v_token);
END;
$$;
SELECT 'PASS: Admin devices, state, activity, rename, disconnect, per-PC rentals, active sessions and free-test policy/trial' AS result;
