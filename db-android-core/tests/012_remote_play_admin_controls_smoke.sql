-- Admin Remote Play owner controls: dashboard, host permission/enrollment, rental permission/activation.
-- Runs only on a fresh disposable PostgreSQL CI database.
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
  client_dashboard jsonb;
  dashboard jsonb;
  sessions_result jsonb;
  owner_token text;
  host_token text;
  org_id uuid;
  device_id uuid;
  rental_id uuid;
  activation_code text;
  client_token text;
  client_session_id uuid;
  cooldown_session_id uuid;
  cooldown_dashboard jsonb;
BEGIN
  -- Reuse the Owner provisioned by 004_admin_local_auth_smoke.sql.
  -- That test consumes the single-use bootstrap and rotates the password.
  login_result := api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  owner_token := login_result->>'token';
  org_id := (login_result->>'org_id')::uuid;

  IF coalesce(owner_token,'')='' OR org_id IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_OWNER_TEST_SESSION_NOT_CREATED';
  END IF;

  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(org_id,'CI-REMOTE-PLAY-HOST','CI Remote Play PC','online')
  RETURNING id INTO device_id;

  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status,client_label,expiry_at)
  VALUES(org_id,'CI-REMOTE-PLAY-RENTAL','reguler',7200,'active','CI Remote Play Member',now()+interval '7 days')
  RETURNING id INTO rental_id;

  IF has_function_privilege(
      'ani_api_runtime','api.admin_remote_play_dashboard(text,integer)','EXECUTE') IS NOT TRUE THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_DASHBOARD_GRANT_MISSING';
  END IF;
  IF has_table_privilege('ani_api_runtime','remote_play.host_permissions','SELECT')
     OR has_table_privilege('ani_api_runtime','remote_play.rental_permissions','SELECT')
     OR has_table_privilege('ani_api_runtime','remote_play.host_registrations','SELECT') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_DASHBOARD_LEAKED_TABLE_PRIVILEGES';
  END IF;

  host_permission := api.admin_remote_play_set_host_permission(owner_token,device_id,true);
  IF host_permission->>'enabled' <> 'true' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_PERMISSION_ENABLE_FAILED';
  END IF;

  rental_permission := api.admin_remote_play_set_rental_permission(owner_token,rental_id,true);
  IF rental_permission->>'enabled' <> 'true' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_RENTAL_PERMISSION_ENABLE_FAILED';
  END IF;

  host_enrollment := api.admin_remote_play_issue_host_enrollment(owner_token,device_id,15);
  IF length(coalesce(host_enrollment->>'enrollment_code','')) < 24 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_ENROLLMENT_CODE_INVALID';
  END IF;
  host_enroll_result := api.remote_play_host_enroll(host_enrollment->>'enrollment_code','ci-admin-controls');
  host_token := host_enroll_result->>'host_token';
  IF length(coalesce(host_token,'')) <> 64 OR (host_enroll_result->>'device_id')::uuid <> device_id THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_ENROLLMENT_FAILED';
  END IF;

  host_heartbeat := api.remote_play_host_heartbeat(host_token,true,'100.96.23.45'::inet,'ci-admin-controls');
  IF host_heartbeat->>'permission_enabled' <> 'true'
     OR host_heartbeat->>'sunshine_ready' <> 'true' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_HEARTBEAT_NOT_READY';
  END IF;

  -- The client streaming status follows Host Agent, not PC Billing's own runtime heartbeat.
  UPDATE public.devices
  SET status='offline',last_seen_at=now()-interval '10 minutes'
  WHERE id=device_id;

  -- Cloudflare Mesh /12 is permitted, but adjacent CGNAT space must remain denied.
  BEGIN
    PERFORM api.remote_play_host_heartbeat(
      host_token,true,'100.95.255.254'::inet,'ci-admin-controls'
    );
    RAISE EXCEPTION 'REMOTE_PLAY_MESH_ALLOWLIST_ACCEPTED_NEIGHBORING_CGNAT';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'REMOTE_PLAY_MEDIA_ADDRESS_MUST_BE_APPROVED_OVERLAY' THEN
      RAISE;
    END IF;
  END;

  client_credential := api.admin_remote_play_issue_client_credential(owner_token,rental_id);
  activation_code := client_credential->>'activation_code';
  IF length(coalesce(activation_code,'')) <> 16 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_CLIENT_ACTIVATION_CODE_INVALID';
  END IF;

  -- The customer dashboard exposes only the approved host address so Android
  -- can verify that Cloudflare One is connected before it reserves a session.
  client_login := api.remote_play_login(
    'CI-REMOTE-PLAY-RENTAL',activation_code,'CI-REMOTE-PLAY-CLIENT'
  );
  client_token := client_login->>'access_token';
  client_session_id := (client_login->>'client_session_id')::uuid;
  IF length(coalesce(client_token,'')) <> 64 OR client_session_id IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_TEST_CLIENT_LOGIN_FAILED';
  END IF;
  client_dashboard := api.remote_play_dashboard(client_token);
  IF NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(client_dashboard->'hosts') h
    WHERE h->>'device_id'=device_id::text
      AND h->>'media_address'='100.96.23.45'
      AND h->>'media_path_ready'='true'
      AND h->>'online'='true'
      AND h->>'pc_billing_online'='false'
      AND h->>'available'='true'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_CLIENT_MESH_ADDRESS_NOT_EXPOSED';
  END IF;

  dashboard := api.admin_remote_play_dashboard(owner_token,200);
  IF coalesce((dashboard->>'ok')::boolean,false) IS NOT TRUE
     OR jsonb_typeof(dashboard->'host_devices') <> 'array'
     OR jsonb_typeof(dashboard->'rental_accounts') <> 'array'
     OR jsonb_typeof(dashboard->'sessions') <> 'array' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_DASHBOARD_RESPONSE_INVALID';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(dashboard->'host_devices') h
    WHERE h->>'device_id'=device_id::text
      AND h->>'permission_enabled'='true'
      AND h->>'agent_enrolled'='true'
      AND h->>'sunshine_ready'='true'
      AND h->>'media_path_ready'='true'
      AND h->>'media_address'='100.96.23.45'
      AND h->>'pending_enrollment'='false'
      AND h->>'device_online'='false'
      AND h->>'host_agent_online'='true'
      AND h->>'host_agent_ready'='true'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_HOST_STATUS_MISSING';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(dashboard->'rental_accounts') r
    WHERE r->>'rental_account_id'=rental_id::text
      AND r->>'permission_enabled'='true'
      AND r->>'activation_issued'='true'
      AND r->>'client_logged_in'='true'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_RENTAL_STATUS_MISSING';
  END IF;

  sessions_result := api.admin_remote_play_sessions(owner_token,25);
  IF jsonb_typeof(sessions_result->'sessions') <> 'array' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_SESSION_LIST_INVALID';
  END IF;

  -- A settled session must keep the client blocked for the full 10-minute cooldown.
  INSERT INTO remote_play.sessions(
    org_id,rental_account_id,device_id,client_session_id,status,
    started_at,stream_started_at,deadline_at,last_client_heartbeat_at,starting_balance_seconds,idempotency_key
  )
  VALUES(org_id,rental_id,device_id,client_session_id,'active',
    now()-interval '60 seconds',now()-interval '60 seconds',now()+interval '2 hours',now(),7200,'ci-cooldown-'||rental_id::text)
  RETURNING id INTO cooldown_session_id;

  PERFORM private.remote_play_settle_session(cooldown_session_id,'ci_cooldown_test',false);
  cooldown_dashboard := api.remote_play_dashboard(client_token);
  IF coalesce((cooldown_dashboard->>'can_start')::boolean,true) IS NOT FALSE
     OR coalesce((cooldown_dashboard->>'cooldown_seconds')::bigint,0) NOT BETWEEN 1 AND 600
     OR (cooldown_dashboard->>'cooldown_until')::timestamptz <= now()
     OR cooldown_dashboard->'active_session' <> 'null'::jsonb THEN
    RAISE EXCEPTION 'REMOTE_PLAY_DASHBOARD_DID_NOT_EXPOSE_ACTIVE_COOLDOWN';
  END IF;

  -- Revoking permissions must persist and remain visible to the Admin dashboard.
  PERFORM api.admin_remote_play_set_host_permission(owner_token,device_id,false);
  PERFORM api.admin_remote_play_set_rental_permission(owner_token,rental_id,false);
  dashboard := api.admin_remote_play_dashboard(owner_token,200);
  IF NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(dashboard->'host_devices') h
    WHERE h->>'device_id'=device_id::text AND h->>'permission_enabled'='false'
  ) OR NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(dashboard->'rental_accounts') r
    WHERE r->>'rental_account_id'=rental_id::text
      AND r->>'permission_enabled'='false'
      AND r->>'activation_issued'='false'
      AND r->>'client_logged_in'='false'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ADMIN_PERMISSION_REVOCATION_NOT_VISIBLE';
  END IF;

  -- Re-enable the feature: the previously issued activation credential must
  -- remain revoked and must never become usable again.
  PERFORM api.admin_remote_play_set_rental_permission(owner_token,rental_id,true);
  dashboard := api.admin_remote_play_dashboard(owner_token,200);
  IF NOT EXISTS(
    SELECT 1 FROM jsonb_array_elements(dashboard->'rental_accounts') r
    WHERE r->>'rental_account_id'=rental_id::text
      AND r->>'permission_enabled'='true'
      AND r->>'activation_issued'='false'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_OLD_ACTIVATION_CREDENTIAL_REACTIVATED';
  END IF;

  BEGIN
    PERFORM api.remote_play_login(
      'CI-REMOTE-PLAY-RENTAL',activation_code,'CI-REMOTE-PLAY-CLIENT-RELOGIN'
    );
    RAISE EXCEPTION 'REMOTE_PLAY_REVOKED_ACTIVATION_LOGIN_SUCCEEDED';
  EXCEPTION WHEN SQLSTATE 'P0001' THEN
    IF SQLERRM <> 'REMOTE_PLAY_INVALID_CREDENTIALS' THEN
      RAISE;
    END IF;
  END;
END;
$$;

SELECT 'PASS: Owner-only Remote Play dashboard, per-PC/per-rental permissions, host enrollment and one-time activation issuance' AS result;
