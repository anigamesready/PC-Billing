DO $$
DECLARE
  v_org uuid; v_device uuid; v_rental uuid; v_token text;
  v_login jsonb; v_enroll jsonb; v_report jsonb; v_month jsonb; v_compact jsonb; v_theme jsonb; v_cmd jsonb; v_status jsonb;
BEGIN
  SELECT org_id INTO v_org FROM public.admin_accounts WHERE username='CI-OWNER' AND status='active' LIMIT 1;
  v_login:=api.admin_login('CI-OWNER','CI-Admin-New-Password-2026'); v_token:=v_login->>'token';
  v_enroll:=api.create_enrollment(v_token,v_org,'CI Enroll',30);
  IF coalesce(v_enroll->>'code','')='' OR NOT EXISTS(
    SELECT 1 FROM public.device_enrollments WHERE org_id=v_org
      AND code_hash=encode(extensions.digest(v_enroll->>'code','sha256'),'hex')
  ) THEN RAISE EXCEPTION 'ENROLLMENT_FAILED'; END IF;

  INSERT INTO public.devices(org_id,client_id,device_name,status,last_heartbeat_at,last_seen_at)
  VALUES(v_org,'CI-ADMIN-UI-PC','CI Admin UI PC','online',now(),now()) RETURNING id INTO v_device;
  INSERT INTO public.device_tokens(device_id,token_hash)
  VALUES(v_device,encode(extensions.digest('CI-ADMIN-UI-TOKEN','sha256'),'hex'));
  PERFORM api.device_heartbeat('CI-ADMIN-UI-TOKEN','ci',jsonb_build_object('rentalSyncReady',true));
  INSERT INTO public.rental_accounts(org_id,device_id,code,category,remaining_seconds,status,client_label)
  VALUES(v_org,v_device,'CI-ADMIN-UI-RENTAL','reguler',3600,'active','CI Report Member') RETURNING id INTO v_rental;
  INSERT INTO public.rental_sessions(org_id,device_id,rental_account_id,code,session_type,started_at,ended_at,status)
  VALUES(v_org,v_device,v_rental,'CI-ADMIN-UI-RENTAL','rental',now()-interval '20 minutes',now()-interval '10 minutes','ended');
  INSERT INTO public.rental_sessions(org_id,device_id,rental_account_id,code,session_type,started_at,ended_at,status)
  VALUES(v_org,v_device,v_rental,'CI-ADMIN-UI-RENTAL','rental',now()-interval '8 minutes',now()-interval '2 minutes','ended');

  v_report:=api.report_detailed_usage_page(v_token,v_org,now()-interval '1 day',now()+interval '1 minute',1,NULL,NULL);
  IF jsonb_array_length(v_report->'rows')<>1 OR coalesce((v_report->>'has_more')::boolean,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'DETAILED_USAGE_PAGE_FAILED';
  END IF;
  v_report:=api.report_detailed_usage_page(v_token,v_org,now()-interval '1 day',now()+interval '1 minute',1,
    (v_report->'next_cursor'->>'started_at')::timestamptz,(v_report->'next_cursor'->>'session_id')::uuid);
  IF jsonb_array_length(v_report->'rows')<>1 THEN RAISE EXCEPTION 'DETAILED_USAGE_CURSOR_FAILED'; END IF;

  v_month:=api.report_monthly_rental_summary(v_token,v_org,now()-interval '30 days',now()+interval '1 minute');
  IF v_month->>'timezone' IS DISTINCT FROM 'Asia/Jakarta'
     OR jsonb_typeof(v_month->'rows') IS DISTINCT FROM 'array'
     OR jsonb_typeof(v_month->'daily') IS DISTINCT FROM 'array' THEN RAISE EXCEPTION 'MONTHLY_SUMMARY_FAILED'; END IF;
  v_compact:=api.report_summary_compact(v_token,v_org,now()-interval '1 day',now()+interval '1 minute');
  IF (v_compact->>'sessions')::integer<2 THEN RAISE EXCEPTION 'COMPACT_SUMMARY_FAILED'; END IF;

  v_theme:=api.save_theme(v_token,v_org,'CI Local Theme','CI Brand','CI Subtitle','#123456','#654321','#111827',NULL,NULL,NULL);
  IF coalesce((v_theme->>'ok')::boolean,false) IS NOT TRUE THEN RAISE EXCEPTION 'SAVE_THEME_FAILED'; END IF;

  v_cmd:=api.admin_command(v_token,v_org,v_device,'refresh',jsonb_build_object('source','ci-admin-ui'));
  v_status:=api.admin_command_status(v_token,v_org,(v_cmd->>'command_id')::uuid);
  IF v_status->>'status' IS DISTINCT FROM 'queued' THEN RAISE EXCEPTION 'COMMAND_STATUS_FAILED'; END IF;
  PERFORM api.admin_logout(v_token);
END;
$$;
SELECT 'PASS: Admin enrollment, paged/monthly/compact reports, theme save and command status' AS result;
