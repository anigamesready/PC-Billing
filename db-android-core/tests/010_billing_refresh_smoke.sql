DO $$
DECLARE
  v_login jsonb; v_refresh jsonb; v_context jsonb; v_count integer; v_error text;
  v_org uuid; v_token text; v_new_token text; v_refresh_token text;
BEGIN
  SELECT org_id INTO v_org FROM public.billing_control_accounts WHERE username='CI-RESELLER-LOGIN' LIMIT 1;
  IF v_org IS NULL THEN RAISE EXCEPTION 'CI_RESELLER_ACCOUNT_MISSING'; END IF;

  v_login:=api.billing_login('CI-RESELLER-LOGIN','CI-Reseller-New-Pass-2026');
  v_token:=v_login->>'token';
  v_refresh_token:=v_login->>'refresh_token';
  IF coalesce(v_token,'')='' OR coalesce(v_refresh_token,'')='' THEN
    RAISE EXCEPTION 'RESELLER_LOGIN_DID_NOT_RETURN_REFRESH_TOKEN';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.billing_control_sessions
    WHERE token_hash=encode(extensions.digest(v_token,'sha256'),'hex')
      AND refresh_token_hash=encode(extensions.digest(v_refresh_token,'sha256'),'hex')
      AND expires_at>now()+interval '11 hours'
      AND refresh_expires_at>now()+interval '29 days'
      AND revoked_at IS NULL
  ) THEN RAISE EXCEPTION 'RESELLER_REFRESH_TOKEN_HASH_OR_EXPIRY_INVALID'; END IF;

  v_context:=api.billing_context(v_token);
  IF v_context->>'role' IS DISTINCT FROM 'RESELLER_ADMIN'
     OR v_context->>'org_id' IS DISTINCT FROM v_org::text THEN
    RAISE EXCEPTION 'RESELLER_CONTEXT_AFTER_LOGIN_FAILED';
  END IF;
  SELECT count(*) INTO v_count FROM api.billing_devices(v_token,v_org);
  IF v_count<1 THEN RAISE EXCEPTION 'RESELLER_DEVICE_LIST_FAILED'; END IF;
  SELECT count(*) INTO v_count FROM api.billing_active_sessions(v_token,v_org);
  IF v_count<0 THEN RAISE EXCEPTION 'RESELLER_ACTIVE_SESSION_LIST_FAILED'; END IF;

  v_refresh:=api.billing_refresh_session(v_refresh_token);
  v_new_token:=v_refresh->>'token';
  IF coalesce(v_new_token,'')='' OR v_refresh->>'refresh_token' IS NOT DISTINCT FROM v_refresh_token THEN
    RAISE EXCEPTION 'RESELLER_REFRESH_ROTATION_FAILED';
  END IF;
  BEGIN
    PERFORM api.billing_context(v_token);
    RAISE EXCEPTION 'EXPECTED_OLD_RESELLER_TOKEN_REJECTION_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error<>'BILLING_SESSION_EXPIRED' THEN RAISE; END IF;
  END;
  v_context:=api.billing_context(v_new_token);
  IF v_context->>'role' IS DISTINCT FROM 'RESELLER_ADMIN' THEN
    RAISE EXCEPTION 'RESELLER_CONTEXT_AFTER_REFRESH_FAILED';
  END IF;
  PERFORM api.billing_logout(v_new_token);
  BEGIN
    PERFORM api.billing_refresh_session(v_refresh->>'refresh_token');
    RAISE EXCEPTION 'EXPECTED_REVOKED_RESELLER_REFRESH_REJECTION_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error=MESSAGE_TEXT;
    IF v_error<>'BILLING_SESSION_EXPIRED' THEN RAISE; END IF;
  END;
END;
$$;
SELECT 'PASS: Reseller hashed access/refresh tokens, 30-day refresh rotation, device/session reads and logout revocation' AS result;
