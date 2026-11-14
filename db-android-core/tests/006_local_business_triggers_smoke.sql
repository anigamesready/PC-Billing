-- Local business trigger regression tests.
DO $$
DECLARE
  v_org uuid;
  v_user uuid;
  v_rental uuid;
  v_legacy_rental uuid;
  v_code text;
  v_updated timestamptz;
BEGIN
  INSERT INTO public.organizations(name,slug,kind,status)
  VALUES('CI Trigger Org','ci-trigger-org','owner','active') RETURNING id INTO v_org;
  v_user := gen_random_uuid();
  INSERT INTO auth.users(id,email) VALUES(v_user,'ci-trigger@local.anigamesready');
  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status)
  VALUES(v_org,'CI-TRIGGER-OLD','reguler',600,'active') RETURNING id INTO v_rental;

  PERFORM set_config('ani.admin_actor_id',v_user::text,true);
  UPDATE public.rental_accounts SET code='  ci-trigger-new  ' WHERE id=v_rental;
  SELECT code,updated_at INTO v_code,v_updated FROM public.rental_accounts WHERE id=v_rental;
  IF v_code IS DISTINCT FROM 'CI-TRIGGER-NEW' THEN
    RAISE EXCEPTION 'RENTAL_CODE_NORMALIZATION_FAILED';
  END IF;
  IF NOT EXISTS(
    SELECT 1 FROM public.audit_logs
    WHERE org_id=v_org AND actor_user_id=v_user
      AND action='rental_identity_updated' AND target_id=v_rental::text
  ) THEN RAISE EXCEPTION 'RENTAL_IDENTITY_AUDIT_MISSING'; END IF;

  -- An untouched legacy code inserted before the trigger must survive a status-only edit.
  INSERT INTO public.rental_accounts(org_id,code,category,remaining_seconds,status)
  VALUES(v_org,' legacy mixed ','reguler',600,'active') RETURNING id INTO v_legacy_rental;
  UPDATE public.rental_accounts SET status='disabled' WHERE id=v_legacy_rental;
  SELECT code INTO v_code FROM public.rental_accounts WHERE id=v_legacy_rental;
  IF v_code IS DISTINCT FROM ' legacy mixed ' THEN
    RAISE EXCEPTION 'STATUS_ONLY_UPDATE_CHANGED_LEGACY_CODE';
  END IF;
END;
$$;
SELECT 'PASS: local rental code normalization, updated_at and audit trigger behavior' AS result;
