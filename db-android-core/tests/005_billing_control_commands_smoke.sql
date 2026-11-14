-- Billing Control token-authenticated command regression tests.
-- Synthetic disposable CI data only.
DO $$
DECLARE
  v_org uuid;
  v_device uuid;
  v_account uuid;
  v_reseller uuid;
  v_login jsonb;
  v_reseller_login jsonb;
  v_command jsonb;
  v_status jsonb;
  v_error text;
BEGIN
  INSERT INTO public.organizations(name,slug,kind,status)
  VALUES('CI Billing Control','ci-billing-control','owner','active') RETURNING id INTO v_org;
  INSERT INTO public.devices(org_id,client_id,device_name,status,last_heartbeat_at,last_seen_at)
  VALUES(v_org,'CI-BILLING-PC','CI Billing PC','online',now(),now()) RETURNING id INTO v_device;

  INSERT INTO public.billing_control_accounts(username,role,org_id,status,password_hash,must_change_password)
  VALUES('CI-BILLING-SUPER','SUPER_ADMIN',v_org,'active',
    extensions.crypt('CI-Billing-Strong-Password-2026',extensions.gen_salt('bf')),false)
  RETURNING id INTO v_account;

  v_login := api.billing_login('CI-BILLING-SUPER','CI-Billing-Strong-Password-2026');
  IF coalesce((v_login->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce(v_login->>'token','')=''
     OR v_login->>'role' IS DISTINCT FROM 'SUPER_ADMIN' THEN
    RAISE EXCEPTION 'BILLING_SUPER_ADMIN_LOGIN_FAILED';
  END IF;

  v_command := api.billing_command(v_login->>'token',v_org,v_device,'restart_billing',
    jsonb_build_object('source','ci-billing-control'));
  IF coalesce((v_command->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce(v_command->>'command_id','')='' THEN
    RAISE EXCEPTION 'BILLING_CONTROL_COMMAND_FAILED';
  END IF;
  v_status := api.billing_command_status(v_login->>'token',(v_command->>'command_id')::uuid);
  IF v_status->>'status' IS DISTINCT FROM 'queued'
     OR v_status->>'command' IS DISTINCT FROM 'restart_billing' THEN
    RAISE EXCEPTION 'BILLING_CONTROL_COMMAND_STATUS_FAILED';
  END IF;

  INSERT INTO public.billing_control_accounts(username,role,org_id,status,password_hash,must_change_password)
  VALUES('CI-BILLING-RESELLER','RESELLER_ADMIN',v_org,'active',
    extensions.crypt('CI-Reseller-Strong-Password-2026',extensions.gen_salt('bf')),false)
  RETURNING id INTO v_reseller;
  v_reseller_login := api.billing_login('CI-BILLING-RESELLER','CI-Reseller-Strong-Password-2026');
  BEGIN
    PERFORM api.billing_command(v_reseller_login->>'token',v_org,v_device,'restart_billing','{}'::jsonb);
    RAISE EXCEPTION 'EXPECTED_RESELLER_COMMAND_DENIAL_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RESELLER_FEATURE_NOT_AVAILABLE' THEN RAISE; END IF;
  END;
  BEGIN
    PERFORM api.billing_command_status(v_reseller_login->>'token',(v_command->>'command_id')::uuid);
    RAISE EXCEPTION 'EXPECTED_RESELLER_COMMAND_STATUS_DENIAL_NOT_RAISED';
  EXCEPTION WHEN OTHERS THEN
    GET STACKED DIAGNOSTICS v_error = MESSAGE_TEXT;
    IF v_error <> 'RESELLER_FEATURE_NOT_AVAILABLE' THEN RAISE; END IF;
  END;
END;
$$;
SELECT 'PASS: Billing Control SUPER_ADMIN can issue and verify PC commands; Reseller cannot access Windows control' AS result;
