-- Admin reseller workspace and Billing Control account CRUD regressions.
-- Synthetic data only; executed in a disposable CI PostgreSQL database.
DO $$
DECLARE
  v_owner_org uuid;
  v_reseller_org uuid;
  v_account_id uuid;
  v_owner_token text;
  v_reseller_token text;
  v_login jsonb;
  v_created jsonb;
  v_updated jsonb;
  v_deleted jsonb;
  v_context jsonb;
  v_count integer;
BEGIN
  SELECT org_id INTO v_owner_org
  FROM public.admin_accounts
  WHERE username='CI-OWNER' AND status='active' LIMIT 1;
  IF v_owner_org IS NULL THEN RAISE EXCEPTION 'CI_OWNER_ORG_MISSING'; END IF;

  v_login := api.admin_login('CI-OWNER','CI-Admin-New-Password-2026');
  v_owner_token := v_login->>'token';

  v_created := api.create_reseller(v_owner_token,'CI Managed Reseller','ci-managed-reseller');
  v_reseller_org := (v_created->>'org_id')::uuid;
  IF (v_created->>'parent_org_id')::uuid IS DISTINCT FROM v_owner_org
     OR NOT EXISTS(SELECT 1 FROM public.organizations WHERE id=v_reseller_org AND kind='reseller') THEN
    RAISE EXCEPTION 'ADMIN_CREATE_RESELLER_FAILED';
  END IF;

  v_created := api.dashboard_billing_user(
    v_owner_token,'create','CI-MANAGED-RESELLER','CI-Managed-Password-2026',
    'active','RESELLER_ADMIN',v_reseller_org,'CI Managed Reseller',NULL
  );
  v_account_id := (v_created->>'id')::uuid;
  IF coalesce((v_created->>'ok')::boolean,false) IS NOT TRUE
     OR v_account_id IS NULL
     OR NOT EXISTS(
       SELECT 1 FROM public.billing_control_accounts
       WHERE id=v_account_id AND status='active'
         AND password_hash IS NOT NULL
         AND extensions.crypt('CI-Managed-Password-2026',password_hash)=password_hash
     ) THEN
    RAISE EXCEPTION 'ADMIN_CREATE_BILLING_USER_FAILED';
  END IF;

  SELECT count(*) INTO v_count FROM api.dashboard_billing_users(v_owner_token) WHERE id=v_account_id;
  IF v_count<>1 THEN RAISE EXCEPTION 'ADMIN_LIST_BILLING_USERS_FAILED'; END IF;

  v_login := api.billing_login('CI-MANAGED-RESELLER','CI-Managed-Password-2026');
  v_reseller_token := v_login->>'token';
  v_context := api.billing_context(v_reseller_token);
  IF v_context->>'role' IS DISTINCT FROM 'RESELLER_ADMIN'
     OR v_context->>'org_id' IS DISTINCT FROM v_reseller_org::text THEN
    RAISE EXCEPTION 'ADMIN_CREATED_RESELLER_LOGIN_OR_SCOPE_FAILED';
  END IF;

  v_updated := api.dashboard_billing_user(
    v_owner_token,'update','CI-MANAGED-RESELLER','CI-Managed-Password-New-2026',
    'disabled','RESELLER_ADMIN',v_reseller_org,'CI Managed Reseller Updated',v_account_id
  );
  IF v_updated->>'status' IS DISTINCT FROM 'disabled'
     OR EXISTS(SELECT 1 FROM public.billing_control_sessions
       WHERE billing_account_id=v_account_id AND revoked_at IS NULL) THEN
    RAISE EXCEPTION 'ADMIN_DISABLE_RESELLER_OR_REVOKE_SESSION_FAILED';
  END IF;

  v_deleted := api.dashboard_billing_user(
    v_owner_token,'delete',NULL,NULL,'active','RESELLER_ADMIN',NULL,NULL,v_account_id
  );
  IF coalesce((v_deleted->>'deleted')::boolean,false) IS NOT TRUE
     OR EXISTS(SELECT 1 FROM public.billing_control_accounts WHERE id=v_account_id) THEN
    RAISE EXCEPTION 'ADMIN_DELETE_BILLING_USER_FAILED';
  END IF;

  PERFORM api.admin_logout(v_owner_token);
END;
$$;
SELECT 'PASS: Admin reseller workspace, Billing Control user CRUD, reseller login/org scope and session revocation' AS result;
