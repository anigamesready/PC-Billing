-- DB Android Billing/Reseller authentication and rental regression tests.
-- Synthetic disposable CI rows only. Never run against Supabase production or a user database.
DO $$
DECLARE
  v_org uuid;
  v_other_org uuid;
  v_device uuid;
  v_account uuid;
  v_rental uuid;
  v_login jsonb;
  v_context jsonb;
  v_created jsonb;
  v_edited jsonb;
  v_deleted jsonb;
  v_token text;
  v_rate jsonb;
  v_count integer;
  v_session uuid;
  v_error text;
  i integer;
BEGIN
  -- Two separate orgs prove the reseller token cannot cross tenant boundaries.
  INSERT INTO public.organizations(name,slug,kind,status)
  VALUES ('CI Reseller Tenant','ci-reseller-tenant','reseller','active')
  RETURNING id INTO v_org;
  INSERT INTO public.organizations(name,slug,kind,status)
  VALUES ('CI Other Tenant','ci-other-tenant','reseller','active')
  RETURNING id INTO v_other_org;

  INSERT INTO public.devices(org_id,client_id,device_name,status)
  VALUES(v_org,'CI-RESELLER-PC','CI Reseller PC','offline')
  RETURNING id INTO v_device;

  INSERT INTO public.billing_control_accounts(
    username,role,org_id,status,password_hash,must_change_password
  )
  VALUES(
    'CI-RESELLER-LOGIN','RESELLER_ADMIN',v_org,'active',
    extensions.crypt('CI-Reseller-Pass-2026',extensions.gen_salt('bf')),false
  )
  RETURNING id INTO v_account;

  -- Username/IP rate-limit ledger is consumed independently of billing_login,
  -- so invalid-credential exceptions cannot roll back the rate counter.
  FOR i IN 1..5 LOOP
    v_rate := api.admin_login_rate_limit_consume(repeat('b',64));
    IF coalesce((v_rate->>'allowed')::boolean,false) IS NOT TRUE THEN
      RAISE EXCEPTION 'LOGIN_RATE_LIMIT_REJECTED_TOO_EARLY';
    END IF;
  END LOOP;
  v_rate := api.admin_login_rate_limit_consume(repeat('b',64));
  IF coalesce((v_rate->>'allowed')::boolean,true) IS NOT FALSE THEN
    RAISE EXCEPTION 'LOGIN_RATE_LIMIT_DID_NOT_BLOCK_SIXTH_ATTEMPT';
  END IF;
  PERFORM api.admin_login_rate_limit_clear(ARRAY[repeat('b',64)]);

  -- Valid login issues a 12-hour opaque token. Only the SHA-256 digest is stored.
  v_login := api.billing_login('CI-RESELLER-LOGIN','CI-Reseller-Pass-2026');
  v_token := v_login->>'token';
  IF coalesce((v_login->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce(v_token,'') = ''
     OR v_login->>'role' IS DISTINCT FROM 'RESELLER_ADMIN'
     OR v_login->>'org_id' IS DISTINCT FROM v_org::text THEN
    RAISE EXCEPTION 'RESELLER_LOGIN_RESPONSE_INVALID';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.billing_control_sessions s
    WHERE s.billing_account_id=v_account
      AND s.token_hash=encode(extensions.digest(v_token,'sha256'),'hex')
      AND s.revoked_at IS NULL
      AND s.expires_at > now()+interval '11 hours'
  ) THEN RAISE EXCEPTION 'RESELLER_SESSION_NOT_HASHED_OR_12H'; END IF;

  v_context := api.billing_context(v_token);
  IF v_context->>'org_id' IS DISTINCT FROM v_org::text
     OR v_context->>'role' IS DISTINCT FROM 'RESELLER_ADMIN' THEN
    RAISE EXCEPTION 'RESELLER_CONTEXT_INVALID';
  END IF;

  -- Reseller list is limited to own org and excludes the special free-test code.
  IF (SELECT count(*) FROM api.billing_reseller_rental_accounts_global(v_token,v_org)) <> 0 THEN
    RAISE EXCEPTION 'RESELLER_LIST_NOT_EMPTY_BEFORE_CREATE';
  END IF;
  BEGIN
    PERFORM * FROM api.billing_reseller_rental_accounts_global(v_token,v_other_org);
    RAISE EXCEPTION 'EXPECTED_CROSS_ORG_READ_DENIAL_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'ORG_ACCESS_DENIED' THEN RAISE; END IF;
  END;

  -- Create is device-independent, unique by normalized org/code, and audited.
  v_created := api.billing_reseller_create_rental_global(
    v_token,v_org,'ci-reseller-rental','reguler',30,'CI Member',now()+interval '30 days'
  );
  v_rental := (v_created->>'id')::uuid;
  IF v_created->>'code' IS DISTINCT FROM 'CI-RESELLER-RENTAL'
     OR (v_created->>'remaining_seconds')::bigint <> 1800
     OR v_created->>'device_id' IS DISTINCT FROM NULL THEN
    RAISE EXCEPTION 'RESELLER_CREATE_RESPONSE_INVALID';
  END IF;

  BEGIN
    PERFORM api.billing_reseller_create_rental_global(
      v_token,v_org,' ci-reseller-rental ','reguler',30,'Duplicate',now()+interval '30 days'
    );
    RAISE EXCEPTION 'EXPECTED_DUPLICATE_RENTAL_REJECT_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'CODE_ALREADY_EXISTS' THEN RAISE; END IF;
  END;

  IF (SELECT count(*) FROM api.billing_reseller_rental_accounts_global(v_token,v_org)
      WHERE id=v_rental) <> 1 THEN
    RAISE EXCEPTION 'RESELLER_LIST_DID_NOT_RETURN_CREATED_RENTAL';
  END IF;

  -- V1.0.6 UI status contract is stored as lower-case DB values.
  v_edited := api.billing_reseller_edit_rental_global(
    v_token,v_org,v_rental,'mingguan',45,'CI Member', 'disabled', now()+interval '30 days'
  );
  IF v_edited->>'status' IS DISTINCT FROM 'disabled'
     OR (v_edited->>'remaining_seconds')::bigint <> 2700 THEN
    RAISE EXCEPTION 'RESELLER_DISABLE_TRANSITION_FAILED';
  END IF;
  v_edited := api.billing_reseller_edit_rental_global(
    v_token,v_org,v_rental,'bulanan',0,'CI Member', 'expired', NULL
  );
  IF v_edited->>'status' IS DISTINCT FROM 'expired'
     OR (v_edited->>'remaining_seconds')::bigint <> 0 THEN
    RAISE EXCEPTION 'RESELLER_EXPIRED_TRANSITION_FAILED';
  END IF;
  v_edited := api.billing_reseller_edit_rental_global(
    v_token,v_org,v_rental,'reguler',20,'CI Member', 'active', now()+interval '30 days'
  );
  IF v_edited->>'status' IS DISTINCT FROM 'active'
     OR (v_edited->>'remaining_seconds')::bigint <> 1200 THEN
    RAISE EXCEPTION 'RESELLER_ACTIVE_TRANSITION_FAILED';
  END IF;

  -- Any attempt to edit or delete while a timer is active/paused must be blocked.
  INSERT INTO public.rental_sessions(
    org_id,device_id,rental_account_id,code,session_type,started_at,deadline_at,status
  )
  VALUES(v_org,v_device,v_rental,'CI-RESELLER-RENTAL','rental',now(),now()+interval '20 minutes','active')
  RETURNING id INTO v_session;
  BEGIN
    PERFORM api.billing_reseller_edit_rental_global(
      v_token,v_org,v_rental,'reguler',15,'CI Member','active',now()+interval '30 days'
    );
    RAISE EXCEPTION 'EXPECTED_ACTIVE_SESSION_EDIT_GUARD_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RENTAL_ACTIVE_TIMER_LOCKED' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM api.billing_reseller_delete_rental_global(v_token,v_org,v_rental);
    RAISE EXCEPTION 'EXPECTED_ACTIVE_SESSION_DELETE_GUARD_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RENTAL_ACTIVE_TIMER_LOCKED' THEN RAISE; END IF;
  END;
  UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=v_session;

  -- Even with no open timer, a live offline lease blocks deletion.
  INSERT INTO public.rental_offline_leases(rental_account_id,org_id,device_id,lease_until)
  VALUES(v_rental,v_org,v_device,now()+interval '10 minutes');
  BEGIN
    PERFORM api.billing_reseller_delete_rental_global(v_token,v_org,v_rental);
    RAISE EXCEPTION 'EXPECTED_OFFLINE_LEASE_DELETE_GUARD_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RENTAL_ACTIVE_OFFLINE_LEASE' THEN RAISE; END IF;
  END;
  DELETE FROM public.rental_offline_leases WHERE rental_account_id=v_rental;

  -- A valid delete succeeds without a device assignment or PC-online prerequisite.
  v_deleted := api.billing_reseller_delete_rental_global(v_token,v_org,v_rental);
  IF coalesce((v_deleted->>'ok')::boolean,false) IS NOT TRUE
     OR (SELECT count(*) FROM public.rental_accounts WHERE id=v_rental) <> 0 THEN
    RAISE EXCEPTION 'RESELLER_DELETE_FAILED';
  END IF;

  -- Password change uses current password + minimum length and is auditable.
  IF coalesce((api.billing_change_password(v_token,'CI-Reseller-Pass-2026','CI-Reseller-New-Pass-2026')->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'RESELLER_PASSWORD_CHANGE_FAILED';
  END IF;
  BEGIN
    PERFORM api.billing_login('CI-RESELLER-LOGIN','CI-Reseller-Pass-2026');
    RAISE EXCEPTION 'EXPECTED_OLD_PASSWORD_REJECTION_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'INVALID_CREDENTIALS' THEN RAISE; END IF;
  END;
  v_login := api.billing_login('CI-RESELLER-LOGIN','CI-Reseller-New-Pass-2026');
  IF coalesce((v_login->>'ok')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'NEW_RESELLER_PASSWORD_LOGIN_FAILED';
  END IF;

  -- Logout revokes the session; context must not remain valid.
  PERFORM api.billing_logout(v_login->>'token');
  BEGIN
    PERFORM api.billing_context(v_login->>'token');
    RAISE EXCEPTION 'EXPECTED_REVOKED_SESSION_REJECTION_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'BILLING_SESSION_EXPIRED' THEN RAISE; END IF;
  END;
END;
$$;

SELECT 'PASS: Billing/Reseller login, hashed 12h sessions, login rate limit, org isolation, rental CRUD/status lifecycle, active-session/offline-lease guards, password change and logout' AS result;
