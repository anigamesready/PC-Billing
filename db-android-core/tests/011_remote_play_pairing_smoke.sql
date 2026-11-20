-- Remote Play / Sunshine pairing schema, privilege and PL/pgSQL entry-point smoke checks.
-- Runs only against a fresh disposable PostgreSQL database in CI.
DO $$
DECLARE
  rls_enabled boolean;
  error_message text;
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
      'api.remote_play_pairing_prepare(text,uuid,text,text)','EXECUTE')
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

  -- Ensure the client/host pairing RPCs compile and reject missing bearer tokens
  -- before reading or returning a PIN/challenge.
  BEGIN
    PERFORM api.remote_play_pairing_prepare(NULL,NULL,NULL,NULL);
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
