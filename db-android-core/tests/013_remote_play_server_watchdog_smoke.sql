-- Server-side Remote Play watchdog must recover sessions when either/both heartbeats disappear.
-- Runs only against a fresh disposable PostgreSQL database in CI.
DO $$
DECLARE
  v_org uuid := gen_random_uuid();
  v_host_stale_device uuid := gen_random_uuid();
  v_client_stale_device uuid := gen_random_uuid();
  v_healthy_device uuid := gen_random_uuid();
  v_host_stale_rental uuid := gen_random_uuid();
  v_client_stale_rental uuid := gen_random_uuid();
  v_healthy_rental uuid := gen_random_uuid();
  v_host_stale_client uuid := gen_random_uuid();
  v_client_stale_client uuid := gen_random_uuid();
  v_healthy_client uuid := gen_random_uuid();
  v_host_stale_session uuid := gen_random_uuid();
  v_client_stale_session uuid := gen_random_uuid();
  v_healthy_session uuid := gen_random_uuid();
  result jsonb;
BEGIN
  INSERT INTO public.organizations(id,name,slug,kind)
  VALUES(v_org,'Remote Play Watchdog CI','remote-play-watchdog-'||replace(v_org::text,'-',''),'owner');

  INSERT INTO public.devices(id,org_id,client_id,device_name,status)
  VALUES
    (v_host_stale_device,v_org,'RP-WD-HOST-'||replace(v_host_stale_device::text,'-',''),'Host heartbeat stale','online'),
    (v_client_stale_device,v_org,'RP-WD-CLIENT-'||replace(v_client_stale_device::text,'-',''),'Client heartbeat stale','online'),
    (v_healthy_device,v_org,'RP-WD-HEALTHY-'||replace(v_healthy_device::text,'-',''),'Healthy session','online');

  INSERT INTO public.rental_accounts(id,org_id,code,category,remaining_seconds,status,client_label)
  VALUES
    (v_host_stale_rental,v_org,'RP-WD-HOST-'||replace(v_host_stale_rental::text,'-',''),'remote_play',7200,'active','Host stale CI'),
    (v_client_stale_rental,v_org,'RP-WD-CLIENT-'||replace(v_client_stale_rental::text,'-',''),'remote_play',7200,'active','Client stale CI'),
    (v_healthy_rental,v_org,'RP-WD-HEALTHY-'||replace(v_healthy_rental::text,'-',''),'remote_play',7200,'active','Healthy CI');

  INSERT INTO remote_play.client_sessions(id,rental_account_id,token_hash,refresh_token_hash,client_install_id,expires_at,refresh_expires_at)
  VALUES
    (v_host_stale_client,v_host_stale_rental,encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),
      encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),'wd-host-stale',now()+interval '12 hours',now()+interval '30 days'),
    (v_client_stale_client,v_client_stale_rental,encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),
      encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),'wd-client-stale',now()+interval '12 hours',now()+interval '30 days'),
    (v_healthy_client,v_healthy_rental,encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),
      encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),'wd-healthy',now()+interval '12 hours',now()+interval '30 days');

  INSERT INTO remote_play.host_permissions(device_id,org_id,enabled)
  VALUES
    (v_host_stale_device,v_org,true),
    (v_client_stale_device,v_org,true),
    (v_healthy_device,v_org,true);

  INSERT INTO remote_play.host_registrations(device_id,org_id,token_hash,agent_version,sunshine_ready,media_address,last_heartbeat_at)
  VALUES
    (v_host_stale_device,v_org,encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),'ci',true,'100.96.1.10'::inet,now()-interval '2 minutes'),
    (v_client_stale_device,v_org,encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),'ci',true,'100.96.1.11'::inet,now()),
    (v_healthy_device,v_org,encode(extensions.digest(gen_random_uuid()::text,'sha256'),'hex'),'ci',true,'100.96.1.12'::inet,now());

  INSERT INTO remote_play.sessions(id,org_id,rental_account_id,device_id,client_session_id,status,
    started_at,stream_started_at,deadline_at,last_client_heartbeat_at,starting_balance_seconds,idempotency_key)
  VALUES
    (v_host_stale_session,v_org,v_host_stale_rental,v_host_stale_device,v_host_stale_client,'active',
      now()-interval '30 seconds',now()-interval '30 seconds',now()+interval '1 hour',now(),7200,'wd-host-'||v_host_stale_session::text),
    (v_client_stale_session,v_org,v_client_stale_rental,v_client_stale_device,v_client_stale_client,'active',
      now()-interval '2 minutes',now()-interval '2 minutes',now()+interval '1 hour',now()-interval '2 minutes',7200,'wd-client-'||v_client_stale_session::text),
    (v_healthy_session,v_org,v_healthy_rental,v_healthy_device,v_healthy_client,'active',
      now()-interval '30 seconds',now()-interval '30 seconds',now()+interval '1 hour',now(),7200,'wd-ok-'||v_healthy_session::text);

  result := api.remote_play_watchdog_sweep();
  IF coalesce((result->>'ok')::boolean,false) IS NOT TRUE
     OR coalesce((result->>'settled_sessions')::integer,0) <> 2 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SERVER_WATCHDOG_DID_NOT_SETTLE_TWO_STALE_SESSIONS: %',result;
  END IF;

  IF NOT EXISTS(SELECT 1 FROM remote_play.sessions WHERE id=v_host_stale_session
      AND settled_at IS NOT NULL AND status='ended' AND end_reason='host_heartbeat_timeout') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SERVER_WATCHDOG_MISSED_STALE_HOST';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.sessions WHERE id=v_client_stale_session
      AND settled_at IS NOT NULL AND status='ended' AND end_reason='client_heartbeat_timeout') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SERVER_WATCHDOG_MISSED_STALE_CLIENT';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.sessions WHERE id=v_healthy_session
      AND settled_at IS NULL AND status='active') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SERVER_WATCHDOG_SETTLED_HEALTHY_SESSION';
  END IF;

  IF (SELECT count(*) FROM remote_play.commands
      WHERE session_id IN (v_host_stale_session,v_client_stale_session)
        AND command='stop_stream' AND status='queued') <> 2 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SERVER_WATCHDOG_STOP_COMMAND_MISSING';
  END IF;

  result := api.remote_play_watchdog_sweep();
  IF coalesce((result->>'settled_sessions')::integer,-1) <> 0 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SERVER_WATCHDOG_NOT_IDEMPOTENT: %',result;
  END IF;
END;
$$;

SELECT 'PASS: server-side Remote Play watchdog settles stale host/client sessions, preserves healthy sessions and is idempotent' AS result;
