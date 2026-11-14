-- Local Admin authentication and DB1 Admin RPC compatibility regression tests.
-- Synthetic disposable PostgreSQL CI rows only. Never run against production.
DO $$
DECLARE
  v_bootstrap jsonb;
  v_login jsonb;
  v_login2 jsonb;
  v_user jsonb;
  v_refresh jsonb;
  v_old_token text;
  v_ctx jsonb;
  v_old_ctx jsonb;
  v_created jsonb;
  v_updated jsonb;
  v_disabled jsonb;
  v_deleted jsonb;
  v_command jsonb;
  v_recovery jsonb;
  v_report jsonb;
  v_alerts integer;
  v_sessions integer;
  v_account uuid;
  v_org uuid;
  v_device uuid;
  v_rental uuid;
  v_session uuid;
  v_token text;
  v_device_token text;
  v_error text;
BEGIN
  -- Install a one-time bootstrap token hash exactly as the Termux server will.
  INSERT INTO private.admin_bootstrap_control(singleton,token_hash)
  VALUES(true,encode(extensions.digest('CI-Admin-Bootstrap-Token','sha256'),'hex'));

  v_bootstrap := api.admin_bootstrap_owner(
    'CI-Admin-Bootstrap-Token','CI-OWNER','CI-Admin-Strong-Password-2026','CI Ani Games Owner'
  );
  IF coalesce((v_bootstrap->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce((v_bootstrap->>'bootstrap_consumed')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_FAILED';
  END IF;
  v_org := (v_bootstrap->>'org_id')::uuid;

  BEGIN
    PERFORM api.admin_bootstrap_owner(
      'CI-Admin-Bootstrap-Token','CI-OWNER-2','CI-Admin-Strong-Password-2026','Second Owner'
    );
    RAISE EXCEPTION 'EXPECTED_BOOTSTRAP_REUSE_DENIAL_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'ADMIN_BOOTSTRAP_DENIED' THEN RAISE; END IF;
  END;

  -- Invalid credentials are rate-counted and do not disclose account existence.
  BEGIN
    PERFORM api.admin_login_rate_limit_consume(repeat('d',64));
    PERFORM api.admin_login('CI-OWNER','wrong-password');
    RAISE EXCEPTION 'EXPECTED_INVALID_ADMIN_PASSWORD_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'INVALID_CREDENTIALS' THEN RAISE; END IF;
  END;

  v_login := api.admin_login('CI-OWNER','CI-Admin-Strong-Password-2026');
  PERFORM api.admin_login_rate_limit_clear(ARRAY[repeat('d',64)]);
  v_token := v_login->>'token';
  v_account := (v_login->>'id')::uuid;
  IF coalesce((v_login->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce(v_token,'')=''
     OR coalesce(v_login->>'refresh_token','')=''
     OR coalesce(v_login->>'auth_user_id','')=''
     OR v_login->>'role' IS DISTINCT FROM 'SUPER_ADMIN'
     OR v_login->>'org_id' IS DISTINCT FROM v_org::text THEN
    RAISE EXCEPTION 'ADMIN_LOGIN_RESPONSE_INVALID';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.admin_local_sessions
    WHERE admin_account_id=v_account
      AND token_hash=encode(extensions.digest(v_token,'sha256'),'hex')
      AND revoked_at IS NULL AND expires_at>now()+interval '11 hours'
  ) THEN RAISE EXCEPTION 'ADMIN_SESSION_NOT_HASHED_OR_12H'; END IF;

  -- Supabase-js-compatible local user lookup and rotating refresh token.
  v_user := api.admin_get_user(v_token);
  IF v_user->>'id' IS DISTINCT FROM v_login->>'auth_user_id'
     OR v_user->>'email' IS DISTINCT FROM 'ci-owner@local.anigamesready' THEN
    RAISE EXCEPTION 'ADMIN_GET_USER_INVALID';
  END IF;
  v_old_token := v_token;
  v_refresh := api.admin_refresh_session(v_login->>'refresh_token');
  v_token := v_refresh->>'token';
  IF coalesce((v_refresh->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce(v_token,'')=''
     OR v_refresh->>'refresh_token' IS NOT DISTINCT FROM v_login->>'refresh_token' THEN
    RAISE EXCEPTION 'ADMIN_REFRESH_ROTATION_FAILED';
  END IF;
  BEGIN
    PERFORM api.admin_context_v2(v_old_token);
    RAISE EXCEPTION 'EXPECTED_OLD_ACCESS_TOKEN_REJECTION_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'ADMIN_SESSION_EXPIRED' THEN RAISE; END IF;
  END;
  v_ctx := api.admin_context_v2(v_token);
  IF v_ctx->>'role' IS DISTINCT FROM 'SUPER_ADMIN'
     OR v_ctx->>'id' IS DISTINCT FROM v_account::text
     OR jsonb_array_length(v_ctx->'orgs')<>1 THEN
    RAISE EXCEPTION 'ADMIN_CONTEXT_V2_INVALID';
  END IF;
  v_old_ctx := api.admin_context(v_token);
  IF v_old_ctx->>'role' IS DISTINCT FROM 'owner'
     OR jsonb_array_length(v_old_ctx->'orgs')<>1 THEN
    RAISE EXCEPTION 'ADMIN_CONTEXT_ORG_MEMBER_COMPAT_INVALID';
  END IF;

  -- Create a device and issue a local token; heartbeat must make it controllable.
  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(v_org,'CI-ADMIN-PC','CI Admin PC','offline') RETURNING id INTO v_device;
  v_device_token := encode(extensions.gen_random_bytes(32),'hex');
  INSERT INTO public.device_tokens(device_id,token_hash)
  VALUES(v_device,encode(extensions.digest(v_device_token,'sha256'),'hex'));
  PERFORM api.device_heartbeat(v_device_token,'CI-test',jsonb_build_object('rentalSyncReady',true));

  v_recovery := api.create_device_recovery_enrollment(v_token,v_device,30);
  IF (v_recovery->>'target_device_id')::uuid IS DISTINCT FROM v_device
     OR coalesce(v_recovery->>'code','')='' THEN
    RAISE EXCEPTION 'ADMIN_RECOVERY_ENROLLMENT_INVALID';
  END IF;

  -- Device-independent Admin rental CRUD preserves the existing DB1 behavior.
  v_created := api.admin_create_rental_global(
    v_token,v_org,'CI-ADMIN-RENTAL','reguler',60,'CI Admin Member',now()+interval '30 days'
  );
  v_rental := (v_created->>'id')::uuid;
  IF coalesce((v_created->>'ok')::boolean,false) IS NOT TRUE
     OR v_created->>'device_id' IS DISTINCT FROM NULL THEN
    RAISE EXCEPTION 'ADMIN_CREATE_RENTAL_FAILED';
  END IF;
  IF (SELECT count(*) FROM api.admin_rental_accounts_global(v_token,v_org) WHERE id=v_rental)<>1 THEN
    RAISE EXCEPTION 'ADMIN_GLOBAL_RENTAL_LIST_FAILED';
  END IF;

  v_updated := api.admin_update_rental_global(
    v_token,v_org,v_rental,'CI-ADMIN-RENTAL-2','mingguan',90,'CI Admin Member',
    now()+interval '30 days','active'
  );
  IF v_updated->>'code' IS DISTINCT FROM 'CI-ADMIN-RENTAL-2'
     OR (v_updated->>'remaining_seconds')::bigint<>5400 THEN
    RAISE EXCEPTION 'ADMIN_UPDATE_RENTAL_FAILED';
  END IF;
  v_disabled := api.admin_disable_rental_global(v_token,v_org,v_rental);
  IF v_disabled->>'status' IS DISTINCT FROM 'disabled' THEN
    RAISE EXCEPTION 'ADMIN_DISABLE_RENTAL_FAILED';
  END IF;

  -- Active session guards remain in force for delete and status-changing operations.
  UPDATE public.rental_accounts SET status='active' WHERE id=v_rental;
  INSERT INTO public.rental_sessions(
    org_id,device_id,rental_account_id,code,session_type,started_at,deadline_at,last_client_at,
    last_client_remaining_seconds,status
  )
  VALUES(v_org,v_device,v_rental,'CI-ADMIN-RENTAL-2','rental',now(),now()+interval '90 minutes',
         now(),5400,'active')
  RETURNING id INTO v_session;
  BEGIN
    PERFORM api.admin_delete_rental_global(v_token,v_org,v_rental);
    RAISE EXCEPTION 'EXPECTED_ADMIN_ACTIVE_SESSION_DELETE_GUARD_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RENTAL_ACTIVE_TIMER_LOCKED' THEN RAISE; END IF;
  END;
  UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=v_session;

  -- Manual Windows command dispatch is retained; scheduled shutdown remains blocked.
  v_command := api.admin_command(v_token,v_org,v_device,'restart_billing',jsonb_build_object('source','ci-admin-test'));
  IF coalesce((v_command->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce(v_command->>'command_id','')='' THEN
    RAISE EXCEPTION 'ADMIN_COMMAND_DISPATCH_FAILED';
  END IF;
  BEGIN
    PERFORM api.admin_command(v_token,v_org,v_device,'schedule_shutdown',
      jsonb_build_object('scheduled',true,'scheduleId','ci','deadlineAt',now()+interval '30 minutes','targetDeviceId',v_device));
    RAISE EXCEPTION 'EXPECTED_SHUTDOWN_TIMER_BLOCK_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'SHUTDOWN_TIMER_DISABLED' THEN RAISE; END IF;
  END;

  -- Admin notification feed and report aggregation use Jakarta local calendar boundaries.
  PERFORM api.device_emit_admin_alert(v_device_token,'ci-admin-alert','session_stopped','CI Admin alert',
    jsonb_build_object('ci',true),now());
  SELECT count(*) INTO v_alerts FROM api.admin_recent_alerts(v_token,v_org,now()-interval '1 hour');
  IF v_alerts<1 THEN RAISE EXCEPTION 'ADMIN_RECENT_ALERTS_FAILED'; END IF;

  INSERT INTO public.rental_sessions(org_id,device_id,rental_account_id,code,session_type,started_at,ended_at,status)
  VALUES(v_org,v_device,v_rental,'CI-ADMIN-RENTAL-2','rental',now()-interval '10 minutes',now(),'ended');
  v_report := api.report_rental_period_breakdown(v_token,v_org,now()-interval '1 day',now()+interval '1 minute');
  IF v_report->>'timezone' IS DISTINCT FROM 'Asia/Jakarta'
     OR jsonb_typeof(v_report->'combined_rows') IS DISTINCT FROM 'array'
     OR jsonb_typeof(v_report->'pc_rows') IS DISTINCT FROM 'array' THEN
    RAISE EXCEPTION 'ADMIN_REPORT_BREAKDOWN_INVALID';
  END IF;

  SELECT count(*) INTO v_sessions FROM api.admin_selected_sessions(v_token,v_org,v_device);
  IF v_sessions<>0 THEN RAISE EXCEPTION 'ADMIN_SELECTED_SESSIONS_SHOULD_BE_EMPTY'; END IF;

  -- Password rotation revokes other sessions and preserves current one.
  v_login2 := api.admin_login('CI-OWNER','CI-Admin-Strong-Password-2026');
  IF coalesce((api.admin_change_password(v_token,'CI-Admin-Strong-Password-2026','CI-Admin-New-Password-2026')->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'ADMIN_PASSWORD_CHANGE_FAILED';
  END IF;
  IF EXISTS(SELECT 1 FROM public.admin_local_sessions WHERE token_hash=encode(extensions.digest(v_login2->>'token','sha256'),'hex') AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'ADMIN_PASSWORD_CHANGE_DID_NOT_REVOKE_OTHER_SESSIONS';
  END IF;
  v_login2 := api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  IF coalesce((v_login2->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'ADMIN_NEW_PASSWORD_LOGIN_FAILED'; END IF;

  PERFORM api.admin_logout(v_login2->>'token');
  BEGIN
    PERFORM api.admin_context_v2(v_login2->>'token');
    RAISE EXCEPTION 'EXPECTED_ADMIN_REVOKED_SESSION_REJECTION_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'ADMIN_SESSION_EXPIRED' THEN RAISE; END IF;
  END;

  -- The runtime cannot call the unbound Supabase-compatible functions directly.
  IF has_function_privilege('ani_api_runtime','api.admin_context_v2()','EXECUTE')
     OR has_function_privilege('ani_api_runtime','api.admin_command(uuid,uuid,text,jsonb)','EXECUTE') THEN
    RAISE EXCEPTION 'ADMIN_RUNTIME_RAW_FUNCTION_EXECUTE_LEAK';
  END IF;
  IF NOT has_function_privilege('ani_api_runtime','api.admin_context_v2(text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.device_heartbeat(text,text,jsonb)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.billing_reseller_rental_accounts_global(text,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'ADMIN_RUNTIME_TOKEN_ALLOWLIST_MISSING';
  END IF;
END;
$$;
SELECT 'PASS: local Admin bootstrap, hashed login sessions, role/org context, recovery, rental CRUD, command safety, alerts, reports, password rotation and token-only API grants' AS result;
