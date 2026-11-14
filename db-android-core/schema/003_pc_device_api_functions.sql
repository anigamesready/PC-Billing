-- ANI GAMES READY DB ANDROID — PC device API function port
-- Source: Supabase Primary DB1 live routine definitions, read-only audit 2026-11-14.
-- Source project/repo contract is documented in db-android-core/docs/DB1-LIVE-CONTRACT-AUDIT-2026-11-14.md.
-- Contains the 18 token-authenticated PC/device routines used by ani-games-api v35.
-- These routines were screened: no auth.uid(), auth.users, DB1/DB2 route/sync, Supabase HTTP, relay, Telegram,
-- or shutdown scheduler dependency. pgcrypto references are explicit under extensions.*.
-- Apply only after 000_prerequisites.sql and 002_core_business_schema.sql on a fresh, disposable staging DB.
-- This does not create or import customer rows, password hashes, device tokens, or secrets.
--
-- Local differences:
-- * Local private.admin_feature_settings starts with free_test_10m_enabled=false (safe default).
-- * PC command 'schedule_shutdown' remains present in the historical CHECK constraint for compatibility,
--   but new inserts are rejected by the guard below, matching the deployed DB1 safety trigger.
-- * DB1/DB2 router and server-side Blynk/WoL relay endpoints are intentionally not included.
BEGIN;

CREATE TABLE IF NOT EXISTS private.admin_feature_settings (
  feature_key text PRIMARY KEY,
  enabled boolean NOT NULL DEFAULT false,
  updated_at timestamptz NOT NULL DEFAULT now(),
  updated_by uuid
);
INSERT INTO private.admin_feature_settings(feature_key, enabled)
VALUES ('free_test_10m_enabled', false)
ON CONFLICT (feature_key) DO NOTHING;

CREATE OR REPLACE FUNCTION private.is_free_test_10m_enabled()
RETURNS boolean
LANGUAGE sql
STABLE
SECURITY DEFINER
SET search_path TO 'private', 'pg_catalog'
AS $function$
  SELECT COALESCE((
    SELECT s.enabled
    FROM private.admin_feature_settings AS s
    WHERE s.feature_key = 'free_test_10m_enabled'
    LIMIT 1
  ), false);
$function$;

CREATE OR REPLACE FUNCTION private.guard_free_test_10m_session()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_catalog'
AS $function$
BEGIN
  IF NEW.code = '__TEST10__' AND NEW.status IN ('active', 'paused') THEN
    IF TG_OP = 'INSERT' THEN
      IF NOT private.is_free_test_10m_enabled() THEN
        RAISE EXCEPTION 'FREE_TEST_DISABLED';
      END IF;
    ELSE
      IF (OLD.code IS DISTINCT FROM '__TEST10__' OR OLD.status NOT IN ('active', 'paused'))
         AND NOT private.is_free_test_10m_enabled() THEN
        RAISE EXCEPTION 'FREE_TEST_DISABLED';
      END IF;
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION private.guard_free_test_10m_trial_request()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'private', 'pg_catalog'
AS $function$
BEGIN
  IF NOT private.is_free_test_10m_enabled() THEN
    RAISE EXCEPTION 'FREE_TEST_DISABLED';
  END IF;
  RETURN NEW;
END;
$function$;

-- Recreate only these three business/safety triggers. No DB1/DB2 quiesce or before-image triggers.
DROP TRIGGER IF EXISTS guard_free_test_10m_session ON public.rental_sessions;
CREATE TRIGGER guard_free_test_10m_session
BEFORE INSERT OR UPDATE ON public.rental_sessions
FOR EACH ROW EXECUTE FUNCTION private.guard_free_test_10m_session();

DROP TRIGGER IF EXISTS guard_free_test_10m_trial_request ON public.device_trial_requests;
CREATE TRIGGER guard_free_test_10m_trial_request
BEFORE INSERT ON public.device_trial_requests
FOR EACH ROW EXECUTE FUNCTION private.guard_free_test_10m_trial_request();

CREATE OR REPLACE FUNCTION private.reject_shutdown_timer_scheduling()
RETURNS trigger
LANGUAGE plpgsql
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
BEGIN
  IF NEW.command = 'schedule_shutdown' THEN
    RAISE EXCEPTION 'SHUTDOWN_TIMER_DISABLED';
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS reject_shutdown_timer_scheduling ON public.device_commands;
CREATE TRIGGER reject_shutdown_timer_scheduling
BEFORE INSERT ON public.device_commands
FOR EACH ROW EXECUTE FUNCTION private.reject_shutdown_timer_scheduling();

-- Exact DB1 function bodies begin here. The schema/function behavior is preserved;
-- only dependencies intentionally excluded from the local single-server design were screened out.
CREATE OR REPLACE FUNCTION api.device_ack(p_token text, p_command_id uuid, p_status text, p_result jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  normalized_status text;
  command_row public.device_commands%ROWTYPE;
BEGIN
  IF pg_column_size(coalesce(p_result, '{}'::jsonb)) > 32768 THEN
    RAISE EXCEPTION 'COMMAND_RESULT_TOO_LARGE';
  END IF;

  SELECT d.id, d.org_id INTO did, oid
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;

  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  normalized_status := CASE
    WHEN p_status IN ('acknowledged','completed','failed','expired') THEN p_status
    ELSE 'acknowledged'
  END;

  SELECT * INTO command_row
  FROM public.device_commands
  WHERE id = p_command_id
    AND device_id = did
  FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'COMMAND_NOT_FOUND'; END IF;

  -- Duplicate ACK/retry: same state must not emit another log or audit row.
  IF command_row.status = normalized_status THEN
    RETURN jsonb_build_object(
      'ok', true,
      'command_id', p_command_id,
      'status', command_row.status,
      'duplicate', true
    );
  END IF;

  -- Terminal states are monotonic. A stale acknowledgement must never roll
  -- completed/failed/expired commands back to acknowledged or another terminal state.
  IF command_row.status IN ('completed','failed','expired') THEN
    RETURN jsonb_build_object(
      'ok', true,
      'command_id', p_command_id,
      'status', command_row.status,
      'duplicate', true,
      'ignored', true,
      'status_conflict', true
    );
  END IF;

  UPDATE public.device_commands
  SET status = normalized_status,
      acknowledged_at = CASE
        WHEN normalized_status = 'acknowledged' THEN coalesce(acknowledged_at, now())
        ELSE acknowledged_at
      END,
      completed_at = CASE
        WHEN normalized_status IN ('completed','failed','expired') THEN coalesce(completed_at, now())
        ELSE completed_at
      END,
      result = coalesce(p_result, '{}'::jsonb)
  WHERE id = p_command_id
    AND device_id = did;

  INSERT INTO public.device_command_logs(command_id, org_id, device_id, status, result)
  VALUES (p_command_id, oid, did, normalized_status, coalesce(p_result, '{}'::jsonb));

  INSERT INTO public.audit_logs(org_id, actor_device_id, action, target_type, target_id, payload)
  VALUES (
    oid, did, 'device_command_ack', 'device_command', p_command_id::text,
    jsonb_build_object('status', normalized_status, 'result', p_result)
  );

  RETURN jsonb_build_object(
    'ok', true,
    'command_id', p_command_id,
    'status', normalized_status,
    'duplicate', false
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.device_disconnect(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  revoked_count integer := 0;
  token_digest text;
  token_was_revoked timestamptz;
BEGIN
  IF coalesce(trim(p_token), '') = '' THEN
    RAISE EXCEPTION 'INVALID_DEVICE_TOKEN';
  END IF;

  token_digest := encode(extensions.digest(p_token, 'sha256'), 'hex');

  SELECT t.device_id, t.revoked_at
  INTO did, token_was_revoked
  FROM public.device_tokens t
  WHERE t.token_hash = token_digest
  ORDER BY t.created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF did IS NULL THEN
    RAISE EXCEPTION 'INVALID_DEVICE_TOKEN';
  END IF;

  -- Idempotent replay: a revoked token must not force a newly active device offline
  -- or generate repeated audit rows.
  IF token_was_revoked IS NOT NULL THEN
    RETURN jsonb_build_object(
      'ok', true,
      'device_id', did,
      'revoked_tokens', 0,
      'already_disconnected', true
    );
  END IF;

  SELECT d.org_id INTO oid
  FROM public.devices d
  WHERE d.id = did;

  UPDATE public.device_tokens
  SET revoked_at = now()
  WHERE device_id = did
    AND token_hash = token_digest
    AND revoked_at IS NULL;

  GET DIAGNOSTICS revoked_count = ROW_COUNT;

  -- Defensive idempotency if a concurrent revoke won the race.
  IF revoked_count = 0 THEN
    RETURN jsonb_build_object(
      'ok', true,
      'device_id', did,
      'revoked_tokens', 0,
      'already_disconnected', true
    );
  END IF;

  UPDATE public.devices
  SET status = 'offline',
      power_state = 'unknown',
      metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('pairingDisconnectedAt', now())
  WHERE id = did;

  INSERT INTO public.audit_logs(org_id, actor_device_id, action, target_type, target_id, payload)
  VALUES (
    oid, did, 'device_pairing_disconnected', 'device', did::text,
    jsonb_build_object('revoked_tokens', revoked_count, 'source', 'pc-client-disconnect')
  );

  RETURN jsonb_build_object(
    'ok', true,
    'device_id', did,
    'revoked_tokens', revoked_count,
    'already_disconnected', false
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.device_emit_admin_alert(p_token text, p_event_id text, p_event_type text, p_message text, p_payload jsonb DEFAULT '{}'::jsonb, p_occurred_at timestamp with time zone DEFAULT now())
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  device_row public.devices%ROWTYPE;
  event_id uuid;
  safe_message text;
  safe_payload jsonb;
BEGIN
  IF pg_column_size(coalesce(p_payload, '{}'::jsonb)) > 16384 THEN RAISE EXCEPTION 'ADMIN_ALERT_PAYLOAD_TOO_LARGE'; END IF;
  IF coalesce(trim(p_token), '') = '' THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF coalesce(trim(p_event_id), '') = '' OR length(p_event_id) > 120 THEN RAISE EXCEPTION 'INVALID_EVENT_ID'; END IF;
  IF p_event_type NOT IN ('session_expired', 'session_stopped') THEN RAISE EXCEPTION 'INVALID_ADMIN_ALERT_TYPE'; END IF;
  safe_message := left(regexp_replace(coalesce(p_message, ''), '[[:cntrl:]]', ' ', 'g'), 240);
  IF safe_message = '' THEN RAISE EXCEPTION 'EMPTY_ADMIN_ALERT_MESSAGE'; END IF;

  SELECT d.* INTO device_row
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(trim(p_token), 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  safe_payload := CASE WHEN jsonb_typeof(coalesce(p_payload, '{}'::jsonb)) = 'object'
    THEN coalesce(p_payload, '{}'::jsonb) ELSE '{}'::jsonb END;

  INSERT INTO public.admin_alert_events(
    org_id, device_id, source_event_id, event_type, message, payload, occurred_at
  )
  VALUES(
    device_row.org_id, device_row.id, trim(p_event_id), p_event_type, safe_message,
    safe_payload, coalesce(p_occurred_at, now())
  )
  ON CONFLICT (device_id, source_event_id) DO NOTHING
  RETURNING id INTO event_id;

  -- Keep this small event table bounded. This cleanup is event-triggered, not a timer/log loop.
  DELETE FROM public.admin_alert_events
  WHERE created_at < now() - interval '30 days';

  RETURN jsonb_build_object('accepted', true, 'duplicate', event_id IS NULL);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_end_rental_session(p_token text, p_code text, p_remaining_seconds bigint, p_source_event_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,''))); s public.rental_sessions%ROWTYPE;
  secs bigint:=greatest(0,coalesce(p_remaining_seconds,0)); rid uuid;
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF nullif(trim(p_source_event_id),'') IS NOT NULL AND EXISTS(
    SELECT 1 FROM public.rental_sessions WHERE org_id=oid AND source_event_id=p_source_event_id
  ) THEN RETURN jsonb_build_object('ok',true,'idempotent',true); END IF;
  SELECT * INTO s FROM public.rental_sessions WHERE org_id=oid AND device_id=did AND code=c
    AND status IN ('active','paused') ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF NOT FOUND THEN
    SELECT id INTO rid FROM public.rental_accounts WHERE org_id=oid AND upper(trim(code))=c
      AND (device_id=did OR (metadata->>'source'='pc-sync' AND metadata->>'originDeviceId'=did::text)) FOR UPDATE;
    IF rid IS NOT NULL AND NOT EXISTS(SELECT 1 FROM public.rental_sessions WHERE rental_account_id=rid AND status IN ('active','paused')) THEN
      UPDATE public.rental_accounts SET remaining_seconds=secs,status=CASE WHEN secs=0 THEN 'expired' ELSE status END,updated_at=now() WHERE id=rid;
      DELETE FROM public.rental_offline_leases WHERE rental_account_id=rid AND device_id=did;
    END IF;
    RETURN jsonb_build_object('ok',true,'idempotent',true,'no_session',true);
  END IF;
  rid:=s.rental_account_id;
  IF rid IS NOT NULL THEN
    UPDATE public.rental_accounts SET remaining_seconds=secs,
      status=CASE WHEN secs=0 THEN 'expired' ELSE status END,updated_at=now()
    WHERE id=rid AND org_id=oid;
    DELETE FROM public.rental_offline_leases WHERE rental_account_id=rid AND device_id=did;
  END IF;
  UPDATE public.rental_sessions SET status='ended',ended_at=now(),last_client_at=now(),
    last_client_remaining_seconds=secs,source_event_id=coalesce(nullif(trim(p_source_event_id),''),source_event_id)
  WHERE id=s.id;
  INSERT INTO public.audit_logs(org_id,actor_user_id,action,target_type,target_id,payload)
  VALUES(oid,NULL,'device_end_rental_session','rental_session',s.id,jsonb_build_object('code',c,'remaining_seconds',secs,'device_id',did));
  RETURN jsonb_build_object('ok',true,'session_id',s.id,'rental_account_id',rid,'remaining_seconds',secs,'status','ended');
END
$function$;

CREATE OR REPLACE FUNCTION api.device_finalize_trial(p_token text, p_command_id uuid, p_status text, p_result jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  req public.device_trial_requests%rowtype;
  existing_session public.rental_sessions%rowtype;
  sid uuid;
  org uuid;
  reused boolean := false;
BEGIN
  IF pg_column_size(coalesce(p_result, '{}'::jsonb)) > 32768 THEN RAISE EXCEPTION 'TRIAL_RESULT_TOO_LARGE'; END IF;
  SELECT dt.device_id INTO did
  FROM public.device_tokens dt
  WHERE dt.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND dt.revoked_at IS NULL
  LIMIT 1;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  SELECT * INTO req
  FROM public.device_trial_requests
  WHERE command_id = p_command_id
    AND device_id = did
    AND status = 'queued'
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok', true, 'ignored', true, 'reason', 'TRIAL_REQUEST_NOT_QUEUED');
  END IF;

  SELECT d.org_id INTO org FROM public.devices d WHERE d.id = did;

  IF p_status <> 'completed' THEN
    UPDATE public.device_trial_requests
    SET status = 'failed',
        finished_at = now(),
        result = coalesce(p_result, '{}'::jsonb)
    WHERE id = req.id;
    RETURN jsonb_build_object('ok', true, 'trial_request_id', req.id, 'status', 'failed');
  END IF;

  -- Heartbeat can create the __TEST10__ session before the final ACK reaches
  -- the server. Adopt that session instead of treating our own trial as conflict.
  SELECT * INTO existing_session
  FROM public.rental_sessions s
  WHERE s.device_id = did
    AND s.status IN ('active', 'paused')
  ORDER BY s.started_at DESC
  LIMIT 1
  FOR UPDATE;

  IF FOUND THEN
    IF existing_session.code <> '__TEST10__' OR existing_session.session_type <> 'free_test' THEN
      UPDATE public.device_trial_requests
      SET status = 'failed',
          finished_at = now(),
          result = coalesce(p_result, '{}'::jsonb) || jsonb_build_object('error', 'SESSION_CONFLICT_AFTER_QUEUE')
      WHERE id = req.id;
      RETURN jsonb_build_object('ok', false, 'error', 'SESSION_CONFLICT_AFTER_QUEUE');
    END IF;

    IF existing_session.deadline_at IS NOT NULL AND existing_session.deadline_at <= now() THEN
      -- An expired stale free-test session must not be reused by a new trial request.
      UPDATE public.rental_sessions
      SET status = 'ended',
          ended_at = coalesce(ended_at, now()),
          last_client_at = now(),
          last_client_remaining_seconds = 0,
          recovery_reason = coalesce(recovery_reason, 'expired_free_test_replaced')
      WHERE id = existing_session.id;
    ELSE
      sid := existing_session.id;
      reused := true;
    END IF;
  END IF;

  IF sid IS NULL THEN
    INSERT INTO public.rental_sessions(
      org_id, device_id, code, session_type, started_at, deadline_at, status, metadata
    ) VALUES (
      org, did, '__TEST10__', 'free_test', now(), now() + interval '10 minutes',
      'active', jsonb_build_object('source', 'web_admin', 'trial_request_id', req.id)
    )
    RETURNING id INTO sid;
  END IF;

  -- The billing record is idempotent if heartbeat and ACK race.
  IF NOT EXISTS (
    SELECT 1 FROM public.billing_transactions bt
    WHERE bt.rental_session_id = sid AND bt.transaction_type = 'free_test'
  ) THEN
    INSERT INTO public.billing_transactions(
      org_id, device_id, rental_session_id, transaction_type, amount, duration_seconds,
      actor_user_id, reference, metadata
    ) VALUES (
      org, did, sid, 'free_test', 0, 600, req.created_by, 'ADMIN-TRIAL',
      jsonb_build_object('source', 'web_admin', 'trial_request_id', req.id)
    )
    ON CONFLICT (rental_session_id)
      WHERE transaction_type = 'free_test' AND rental_session_id IS NOT NULL
    DO NOTHING;
  END IF;

  UPDATE public.device_trial_requests
  SET status = 'started',
      session_id = sid,
      started_at = coalesce(existing_session.started_at, now()),
      finished_at = now(),
      result = coalesce(p_result, '{}'::jsonb)
        || jsonb_build_object('reused_heartbeat_session', reused)
  WHERE id = req.id;

  RETURN jsonb_build_object(
    'ok', true, 'trial_request_id', req.id, 'session_id', sid, 'reused_session', reused
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.device_free_test_policy(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'private', 'pg_catalog'
AS $function$
DECLARE
  token_device_id uuid;
  is_enabled boolean;
BEGIN
  IF COALESCE(btrim(p_token), '') = '' THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  SELECT t.device_id INTO token_device_id
  FROM public.device_tokens t
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;

  IF token_device_id IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  is_enabled := private.is_free_test_10m_enabled();
  RETURN jsonb_build_object(
    'ok', true,
    'enabled', is_enabled,
    'contact_phone', '082298316902',
    'message', CASE
      WHEN is_enabled THEN 'FREE_TEST_ALLOWED'
      ELSE 'Silahkan hubungi admin untuk melakukan tes 082298316902'
    END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.device_heartbeat(p_token text, p_app_version text, p_metadata jsonb DEFAULT '{}'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  d public.devices%rowtype;
  commands jsonb;
  rental_rows jsonb;
  active_code text;
  paused_code text;
  active_remaining bigint;
  paused_remaining bigint;
  active_category text;
  active_expiry timestamptz;
  active_label text;
  target_code text;
  target_status text;
  target_remaining bigint;
  target_category text;
  target_expiry timestamptz;
  target_label text;
  rid uuid;
  tid uuid;
  open_sid uuid;
  open_code text;
  open_status text;
  open_account_id uuid;
  open_remaining bigint;
  open_last_client_at timestamptz;
  open_theme_id uuid;
  state_changed boolean := false;
  liveness_due boolean := false;
  free_test_blocked boolean := false;
BEGIN
  -- HEARTBEAT_EVENT_WRITE_OPTIMIZATION_V1
  IF jsonb_typeof(coalesce(p_metadata, '{}'::jsonb)) <> 'object' THEN RAISE EXCEPTION 'DEVICE_METADATA_MUST_BE_OBJECT'; END IF;
  IF pg_column_size(coalesce(p_metadata, '{}'::jsonb)) > 32768 THEN RAISE EXCEPTION 'DEVICE_METADATA_TOO_LARGE'; END IF;
  IF length(coalesce(p_app_version, '')) > 120 THEN RAISE EXCEPTION 'DEVICE_APP_VERSION_TOO_LONG'; END IF;

  SELECT d0.* INTO d
  FROM public.device_tokens t
  JOIN public.devices d0 ON d0.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL;

  IF d.id IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  state_changed :=
       d.status IS DISTINCT FROM 'online'
    OR d.power_state IS DISTINCT FROM 'online'
    OR d.app_version IS DISTINCT FROM coalesce(p_app_version, d.app_version)
    OR coalesce(d.metadata->>'clientId','') IS DISTINCT FROM coalesce(p_metadata->>'clientId','')
    OR coalesce(d.metadata->>'rentalSyncReady','') IS DISTINCT FROM coalesce(p_metadata->>'rentalSyncReady','')
    OR coalesce(d.metadata->>'activeCode','') IS DISTINCT FROM coalesce(p_metadata->>'activeCode','')
    OR coalesce(d.metadata->>'pausedCode','') IS DISTINCT FROM coalesce(p_metadata->>'pausedCode','')
    OR coalesce(d.metadata->>'activeCategory','') IS DISTINCT FROM coalesce(p_metadata->>'activeCategory','')
    OR coalesce(d.metadata->>'activeExpiryDate','') IS DISTINCT FROM coalesce(p_metadata->>'activeExpiryDate','')
    OR coalesce(d.metadata->>'activeClientLabel','') IS DISTINCT FROM coalesce(p_metadata->>'activeClientLabel','')
    OR coalesce(d.metadata #>> '{shutdownTimer,state}','') IS DISTINCT FROM coalesce(p_metadata #>> '{shutdownTimer,state}','')
    OR coalesce(d.metadata #>> '{shutdownTimer,scheduleId}','') IS DISTINCT FROM coalesce(p_metadata #>> '{shutdownTimer,scheduleId}','')
    OR coalesce(d.metadata #>> '{shutdownTimer,deadlineAt}','') IS DISTINCT FROM coalesce(p_metadata #>> '{shutdownTimer,deadlineAt}','');

  liveness_due := d.last_heartbeat_at IS NULL
    OR d.last_heartbeat_at <= now() - interval '30 seconds';

  IF state_changed OR liveness_due OR d.last_seen_at IS NULL THEN
    UPDATE public.devices
    SET status = 'online',
        power_state = 'online',
        app_version = coalesce(p_app_version, app_version),
        last_seen_at = now(),
        last_heartbeat_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || coalesce(p_metadata, '{}'::jsonb)
    WHERE id = d.id;
  END IF;

  -- Historical heartbeat table is event-only; stable polling cycles do not create log rows.
  IF state_changed OR d.last_heartbeat_at IS NULL THEN
    INSERT INTO public.device_heartbeats(device_id, org_id, app_version, metadata)
    VALUES (d.id, d.org_id, p_app_version, coalesce(p_metadata, '{}'::jsonb));
  END IF;

  active_code := upper(nullif(trim(p_metadata->>'activeCode'), ''));
  paused_code := upper(nullif(trim(p_metadata->>'pausedCode'), ''));
  active_remaining := greatest(0, coalesce((p_metadata->>'activeRemainingSeconds')::bigint, 0));
  paused_remaining := greatest(0, coalesce((p_metadata->>'pausedRemainingSeconds')::bigint, 0));
  active_category := coalesce(nullif(trim(p_metadata->>'activeCategory'), ''), 'reguler');
  active_expiry := nullif(p_metadata->>'activeExpiryDate', '')::timestamptz;
  active_label := nullif(trim(p_metadata->>'activeClientLabel'), '');
  target_code := coalesce(active_code, paused_code);
  target_status := CASE WHEN active_code IS NOT NULL THEN 'active'
                        WHEN paused_code IS NOT NULL THEN 'paused' ELSE NULL END;
  target_remaining := CASE WHEN active_code IS NOT NULL THEN active_remaining
                            WHEN paused_code IS NOT NULL THEN paused_remaining ELSE 0 END;
  target_category := active_category;
  target_expiry := active_expiry;
  target_label := active_label;

  SELECT s.id, s.code, s.status, s.rental_account_id,
         s.last_client_remaining_seconds, s.last_client_at, s.theme_id
  INTO open_sid, open_code, open_status, open_account_id,
       open_remaining, open_last_client_at, open_theme_id
  FROM public.rental_sessions s
  WHERE s.device_id = d.id AND s.status IN ('active', 'paused')
  ORDER BY s.started_at DESC
  LIMIT 1 FOR UPDATE;

  IF target_code = '__TEST10__'
     AND NOT private.is_free_test_10m_enabled()
     AND (open_sid IS NULL OR open_code IS DISTINCT FROM '__TEST10__') THEN
    free_test_blocked := true;
  END IF;

  -- Do not roll back device liveness/command delivery when a stale client reports a denied test.
  -- Existing test sessions may finish; the trigger remains the authorization boundary for any new test-session insert.
  IF NOT free_test_blocked AND (coalesce(p_metadata->>'localPendingActiveCode','') = '' OR p_metadata->>'localPendingActiveCode' IS DISTINCT FROM target_code) AND NOT EXISTS (
    SELECT 1 FROM public.rental_accounts ra
    JOIN public.rental_offline_leases l ON l.rental_account_id = ra.id
    WHERE ra.org_id = d.org_id AND upper(trim(ra.code)) = target_code
      AND l.device_id <> d.id AND l.lease_until > now()
  ) THEN
  IF target_code IS NULL THEN
    IF open_sid IS NOT NULL THEN
      UPDATE public.rental_sessions
      SET status = 'ended',
          ended_at = now(),
          last_client_at = now(),
          last_client_remaining_seconds = 0
      WHERE id = open_sid;
    END IF;
  ELSE
    -- The 10-minute trial is a session, not a customer rental account.
    -- Do not create or update a visible rental_accounts row for __TEST10__.
    IF target_code = '__TEST10__' THEN
      rid := NULL;
      SELECT theme_id INTO tid FROM public.organizations WHERE id = d.org_id;
    ELSE
      SELECT ra.id, ra.theme_id INTO rid, tid
      FROM public.rental_accounts ra
      WHERE ra.org_id = d.org_id
        AND ra.code = target_code
        
      ORDER BY ra.created_at DESC
      LIMIT 1;

      IF rid IS NULL THEN
        SELECT theme_id INTO tid FROM public.organizations WHERE id = d.org_id;
        INSERT INTO public.rental_accounts(
          org_id, device_id, code, category, remaining_seconds, expiry_at, status,
          client_label, theme_id, metadata
        ) VALUES (
          d.org_id, d.id, target_code, target_category, target_remaining, target_expiry,
          'active', target_label, tid, jsonb_build_object('source', 'pc-heartbeat')
        )
        RETURNING id INTO rid;
      ELSE
        UPDATE public.rental_accounts
        SET remaining_seconds = target_remaining, updated_at = now()
        WHERE id = rid
          AND ((open_sid IS NOT NULL AND open_code = target_code AND open_account_id = rid)
            OR EXISTS (SELECT 1 FROM public.rental_offline_leases l WHERE l.rental_account_id = rid AND l.device_id = d.id AND l.lease_until > now()))
          AND remaining_seconds IS DISTINCT FROM target_remaining
          AND (abs(coalesce(remaining_seconds,0)-target_remaining) >= 30 OR target_remaining <= 30 OR coalesce(remaining_seconds,0) <= 30);
      END IF;
    END IF;

    IF open_sid IS NULL THEN
      INSERT INTO public.rental_sessions(
        org_id, device_id, rental_account_id, code, session_type, started_at,
        deadline_at, status, last_client_at, metadata, last_client_remaining_seconds, theme_id
      ) VALUES (
        d.org_id, d.id, rid, target_code,
        CASE WHEN target_code = '__TEST10__' THEN 'free_test' ELSE 'rental' END,
        now(), now() + make_interval(secs => target_remaining), target_status, now(),
        jsonb_build_object('source', 'pc-heartbeat'), target_remaining, tid
      );
    ELSIF open_code = target_code THEN
      IF open_status IS DISTINCT FROM target_status
         OR open_account_id IS DISTINCT FROM rid
         OR open_theme_id IS DISTINCT FROM tid
         OR (
           open_remaining IS DISTINCT FROM target_remaining
           AND (
             abs(coalesce(open_remaining,0)-target_remaining) >= 30
             OR target_remaining <= 30
             OR coalesce(open_remaining,0) <= 30
           )
         )
         OR open_last_client_at IS NULL
         OR open_last_client_at <= now() - interval '60 seconds' THEN
        UPDATE public.rental_sessions
        SET rental_account_id = rid,
            status = target_status,
            last_client_at = now(),
            deadline_at = now() + make_interval(secs => target_remaining),
            last_client_remaining_seconds = target_remaining,
            metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('source', 'pc-heartbeat'),
            theme_id = tid
        WHERE id = open_sid;
      END IF;
    ELSE
      UPDATE public.rental_sessions
      SET status = 'ended', ended_at = now(), last_client_at = now()
      WHERE id = open_sid;

      INSERT INTO public.rental_sessions(
        org_id, device_id, rental_account_id, code, session_type, started_at,
        deadline_at, status, last_client_at, metadata, last_client_remaining_seconds, theme_id
      ) VALUES (
        d.org_id, d.id, rid, target_code,
        CASE WHEN target_code = '__TEST10__' THEN 'free_test' ELSE 'rental' END,
        now(), now() + make_interval(secs => target_remaining), target_status, now(),
        jsonb_build_object('source', 'pc-heartbeat'), target_remaining, tid
      );
    END IF;
  END IF;
  END IF;

  WITH claimed AS (
    UPDATE public.device_commands c
    SET status = 'acknowledged',
        acknowledged_at = now(),
        delivered_at = now(),
        delivery_attempts = coalesce(delivery_attempts, 0) + 1
    WHERE c.device_id = d.id AND c.status = 'queued'
    RETURNING c.*
  )
  SELECT coalesce(jsonb_agg(to_jsonb(claimed) ORDER BY claimed.created_at), '[]'::jsonb)
  INTO commands
  FROM claimed;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.updated_at, r.id), '[]'::jsonb)
  INTO rental_rows
  FROM public.rental_accounts r
  WHERE r.org_id = d.org_id
    AND r.code = target_code
    AND upper(r.code) <> '__TEST10__';

  RETURN jsonb_build_object(
    'device_id', d.id,
    'org_id', d.org_id,
    'commands', commands,
    'rental_accounts', rental_rows,
    'server_time', now(),
    'power_state', 'online',
    'free_test_disabled', free_test_blocked,
    'free_test_message', CASE WHEN free_test_blocked
      THEN 'Silahkan hubungi admin untuk melakukan tes 082298316902'
      ELSE NULL END
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.device_pairing_rate_limit_clear(p_key_hashes text[])
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v_deleted integer := 0;
BEGIN
  IF p_key_hashes IS NULL OR cardinality(p_key_hashes) < 1 OR cardinality(p_key_hashes) > 4
     OR EXISTS (
       SELECT 1 FROM unnest(p_key_hashes) AS x(k)
       WHERE x.k IS NULL OR x.k !~ '^[0-9a-f]{64}$'
     ) THEN
    RAISE EXCEPTION 'RATE_LIMIT_KEYS_INVALID';
  END IF;

  DELETE FROM public.device_pairing_rate_limits
  WHERE key_hash = ANY(p_key_hashes);
  GET DIAGNOSTICS v_deleted = ROW_COUNT;
  RETURN jsonb_build_object('ok', true, 'cleared', v_deleted);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_pairing_rate_limit_consume(p_key_hash text, p_max_attempts integer DEFAULT 5)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  v public.device_pairing_rate_limits%ROWTYPE;
  v_next integer;
  v_locked_until timestamptz;
BEGIN
  IF p_key_hash IS NULL OR p_key_hash !~ '^[0-9a-f]{64}$' THEN
    RAISE EXCEPTION 'RATE_LIMIT_KEY_INVALID';
  END IF;
  IF p_max_attempts IS NULL OR p_max_attempts < 1 OR p_max_attempts > 100 THEN
    RAISE EXCEPTION 'RATE_LIMIT_MAX_ATTEMPTS_INVALID';
  END IF;

  INSERT INTO public.device_pairing_rate_limits(key_hash, attempt_count, window_started_at, updated_at)
  VALUES (p_key_hash, 0, now(), now())
  ON CONFLICT (key_hash) DO NOTHING;

  SELECT * INTO v
  FROM public.device_pairing_rate_limits
  WHERE key_hash = p_key_hash
  FOR UPDATE;

  IF v.locked_until IS NOT NULL AND v.locked_until > now() THEN
    RETURN jsonb_build_object(
      'allowed', false,
      'retry_after_seconds', greatest(1, ceil(extract(epoch FROM (v.locked_until - now())))::integer)
    );
  END IF;

  IF v.window_started_at <= now() - interval '15 minutes'
     OR (v.locked_until IS NOT NULL AND v.locked_until <= now()) THEN
    UPDATE public.device_pairing_rate_limits
    SET attempt_count = 1,
        window_started_at = now(),
        locked_until = NULL,
        updated_at = now()
    WHERE key_hash = p_key_hash;
    RETURN jsonb_build_object('allowed', true, 'remaining_attempts', p_max_attempts - 1);
  END IF;

  v_next := least(p_max_attempts, v.attempt_count + 1);
  v_locked_until := CASE WHEN v_next >= p_max_attempts THEN now() + interval '15 minutes' ELSE NULL END;

  UPDATE public.device_pairing_rate_limits
  SET attempt_count = v_next,
      locked_until = v_locked_until,
      updated_at = now()
  WHERE key_hash = p_key_hash;

  RETURN jsonb_build_object(
    'allowed', true,
    'remaining_attempts', greatest(0, p_max_attempts - v_next)
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.device_pull_sync(p_token text, p_cursor timestamp with time zone DEFAULT NULL::timestamp with time zone)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE did uuid; oid uuid; rows jsonb; ts timestamptz:=now();
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.updated_at,r.id),'[]'::jsonb)
  INTO rows FROM public.rental_accounts r
  WHERE p_cursor IS NOT NULL AND r.org_id=oid AND upper(r.code)<>'__TEST10__'
    AND r.updated_at>=p_cursor;
  RETURN jsonb_build_object('serverTime',ts,'deviceId',did,'rentalAccounts',coalesce(rows,'[]'::jsonb),'cursor',ts,
    'fullSnapshot',false,'scope','organization-delta');
END
$function$;

CREATE OR REPLACE FUNCTION api.device_release_rental_lease(p_token text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,''))); rid uuid; removed integer;
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  SELECT id INTO rid FROM public.rental_accounts WHERE org_id=oid AND upper(trim(code))=c;
  IF rid IS NULL THEN RETURN jsonb_build_object('ok',true,'released',false); END IF;
  IF EXISTS(SELECT 1 FROM public.rental_sessions WHERE rental_account_id=rid AND status IN ('active','paused')) THEN
    RETURN jsonb_build_object('ok',true,'released',false,'active_session',true);
  END IF;
  DELETE FROM public.rental_offline_leases WHERE rental_account_id=rid AND device_id=did;
  GET DIAGNOSTICS removed = ROW_COUNT;
  RETURN jsonb_build_object('ok',true,'released',removed>0);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_rental_lookup(p_token text, p_code text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,'')));
  r public.rental_accounts%ROWTYPE; l public.rental_offline_leases%ROWTYPE;
  s public.rental_sessions%ROWTYPE; remaining bigint; until_at timestamptz;
BEGIN
  SELECT d.id,d.org_id INTO did,oid
  FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF c='' OR c='__TEST10__' THEN RAISE EXCEPTION 'RENTAL_CODE_INVALID'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(oid::text||':'||c,0));
  SELECT * INTO r FROM public.rental_accounts
  WHERE org_id=oid AND upper(trim(code))=c FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF r.status<>'active' THEN RAISE EXCEPTION 'RENTAL_NOT_ACTIVE'; END IF;
  IF r.expiry_at IS NOT NULL AND r.expiry_at<=now() THEN RAISE EXCEPTION 'RENTAL_EXPIRED'; END IF;
  IF r.remaining_seconds<=0 AND NOT EXISTS(SELECT 1 FROM public.rental_sessions ps WHERE ps.rental_account_id=r.id AND ps.status='paused' AND coalesce(ps.last_client_remaining_seconds,0)>0) THEN RAISE EXCEPTION 'RENTAL_TIME_EXHAUSTED'; END IF;
  SELECT * INTO s FROM public.rental_sessions
   WHERE rental_account_id=r.id AND status IN ('active','paused')
   ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND s.status='active' AND s.deadline_at IS NOT NULL AND s.deadline_at<=now() THEN
    UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=s.id;
    UPDATE public.rental_accounts SET remaining_seconds=0,status='expired',updated_at=now() WHERE id=r.id;
    DELETE FROM public.rental_offline_leases WHERE rental_account_id=r.id;
    RETURN jsonb_build_object('ok',false,'error','RENTAL_TIME_EXHAUSTED');
  END IF;
  IF FOUND AND s.device_id<>did THEN RAISE EXCEPTION 'RENTAL_ACTIVE_ON_OTHER_PC'; END IF;
  SELECT * INTO l FROM public.rental_offline_leases WHERE rental_account_id=r.id FOR UPDATE;
  IF FOUND AND l.lease_until>now() AND l.device_id<>did THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  IF FOUND AND l.lease_until>now() AND l.device_id=did THEN
    IF s.status='active' AND s.deadline_at IS NOT NULL THEN until_at:=greatest(l.lease_until,s.deadline_at+make_interval(secs=>1800));
    ELSIF s.status='paused' THEN until_at:=now()+make_interval(secs=>greatest(0,coalesce(s.last_client_remaining_seconds,r.remaining_seconds))+1800);
    ELSE until_at:=now()+make_interval(secs=>greatest(0,r.remaining_seconds)+1800); END IF;
  ELSE
    remaining:=CASE WHEN s.status='active' AND s.deadline_at IS NOT NULL
      THEN greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint)
      WHEN s.status='paused' THEN greatest(0,coalesce(s.last_client_remaining_seconds,r.remaining_seconds))
      ELSE greatest(0,r.remaining_seconds) END;
    until_at:=now()+make_interval(secs=>remaining + 1800);
  END IF;
  IF until_at<=now() THEN RAISE EXCEPTION 'RENTAL_TIME_EXHAUSTED'; END IF;
  INSERT INTO public.rental_offline_leases(rental_account_id,org_id,device_id,lease_until,created_at,updated_at)
  VALUES(r.id,oid,did,until_at,now(),now())
  ON CONFLICT(rental_account_id) DO UPDATE
   SET org_id=EXCLUDED.org_id,device_id=EXCLUDED.device_id,lease_until=EXCLUDED.lease_until,updated_at=now()
   WHERE public.rental_offline_leases.device_id=did OR public.rental_offline_leases.lease_until<=now();
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  RETURN jsonb_build_object('ok',true,'id',r.id,'org_id',oid,'device_id',did,'code',r.code,
    'category',r.category,'remaining_seconds',CASE WHEN s.status='active' AND s.deadline_at IS NOT NULL
      THEN greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint)
      WHEN s.status='paused' THEN greatest(0,coalesce(s.last_client_remaining_seconds,r.remaining_seconds)) ELSE r.remaining_seconds END,
    'expiry_at',r.expiry_at,'status',r.status,'client_label',r.client_label,
    'updated_at',r.updated_at,'offline_lease_until',until_at,'session_id',s.id);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_rentals_snapshot(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  d public.devices%rowtype;
  rows jsonb;
BEGIN
  SELECT d0.* INTO d
  FROM public.device_tokens t
  JOIN public.devices d0 ON d0.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL;

  IF d.id IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  SELECT coalesce(jsonb_agg(to_jsonb(r) ORDER BY r.updated_at, r.id), '[]'::jsonb)
  INTO rows
  FROM public.rental_accounts r
  WHERE r.org_id = d.org_id
    AND r.device_id = d.id
    AND upper(r.code) <> '__TEST10__';

  RETURN jsonb_build_object(
    'ok', true,
    'device_id', d.id,
    'org_id', d.org_id,
    'rental_accounts', rows,
    'count', jsonb_array_length(rows),
    'server_time', now()
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.device_start_rental_session(p_token text, p_code text, p_source_event_id text DEFAULT NULL::text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  did uuid; oid uuid; c text:=upper(trim(coalesce(p_code,'')));
  r public.rental_accounts%ROWTYPE; s public.rental_sessions%ROWTYPE;
  lease public.rental_offline_leases%ROWTYPE; sid uuid; tid uuid; deadline timestamptz;
BEGIN
  SELECT d.id,d.org_id INTO did,oid
  FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  IF c='' OR c='__TEST10__' THEN RAISE EXCEPTION 'RENTAL_CODE_INVALID'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(oid::text||':'||c,0));
  IF nullif(trim(p_source_event_id),'') IS NOT NULL THEN
    SELECT * INTO s FROM public.rental_sessions WHERE org_id=oid AND source_event_id=p_source_event_id LIMIT 1;
    IF FOUND THEN RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',s.status,'idempotent',true,
      'remaining_seconds',CASE WHEN s.status='paused' THEN greatest(0,coalesce(s.last_client_remaining_seconds,(SELECT ra.remaining_seconds FROM public.rental_accounts ra WHERE ra.id=s.rental_account_id),0)) ELSE greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint) END,
      'deadline_at',CASE WHEN s.status='paused' THEN now()+make_interval(secs=>greatest(0,coalesce(s.last_client_remaining_seconds,(SELECT ra.remaining_seconds FROM public.rental_accounts ra WHERE ra.id=s.rental_account_id),0))) ELSE s.deadline_at END); END IF;
  END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE org_id=oid AND upper(trim(code))=c FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF r.status<>'active' THEN RAISE EXCEPTION 'RENTAL_NOT_ACTIVE'; END IF;
  IF r.expiry_at IS NOT NULL AND r.expiry_at<=now() THEN RAISE EXCEPTION 'RENTAL_EXPIRED'; END IF;
  IF r.remaining_seconds<=0 AND NOT EXISTS(SELECT 1 FROM public.rental_sessions ps WHERE ps.rental_account_id=r.id AND ps.status='paused' AND coalesce(ps.last_client_remaining_seconds,0)>0) THEN RAISE EXCEPTION 'RENTAL_TIME_EXHAUSTED'; END IF;
  SELECT * INTO s FROM public.rental_sessions
  WHERE rental_account_id=r.id AND status IN ('active','paused') ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND THEN
    IF s.device_id<>did THEN RAISE EXCEPTION 'RENTAL_ACTIVE_ON_OTHER_PC'; END IF;
    IF s.status='active' AND s.deadline_at IS NOT NULL AND s.deadline_at<=now() THEN
      UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=s.id;
      UPDATE public.rental_accounts SET remaining_seconds=0,status='expired',updated_at=now() WHERE id=r.id;
      DELETE FROM public.rental_offline_leases WHERE rental_account_id=r.id;
      RETURN jsonb_build_object('ok',false,'error','RENTAL_TIME_EXHAUSTED');
    END IF;
    RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',s.status,'idempotent',true,
      'remaining_seconds',CASE WHEN s.status='paused' THEN greatest(0,coalesce(s.last_client_remaining_seconds,(SELECT ra.remaining_seconds FROM public.rental_accounts ra WHERE ra.id=s.rental_account_id),0)) ELSE greatest(0,ceil(extract(epoch from (s.deadline_at-now())))::bigint) END,
      'deadline_at',CASE WHEN s.status='paused' THEN now()+make_interval(secs=>greatest(0,coalesce(s.last_client_remaining_seconds,(SELECT ra.remaining_seconds FROM public.rental_accounts ra WHERE ra.id=s.rental_account_id),0))) ELSE s.deadline_at END);
  END IF;
  SELECT * INTO lease FROM public.rental_offline_leases WHERE rental_account_id=r.id FOR UPDATE;
  IF FOUND AND lease.lease_until>now() AND lease.device_id<>did THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  SELECT * INTO s FROM public.rental_sessions
   WHERE device_id=did AND status IN ('active','paused') ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND s.code<>c AND (s.status='paused' OR s.deadline_at IS NULL OR s.deadline_at>now()) THEN RAISE EXCEPTION 'ACTIVE_SESSION_EXISTS'; END IF;
  IF FOUND AND s.status='active' AND s.deadline_at IS NOT NULL AND s.deadline_at<=now() THEN
    UPDATE public.rental_sessions SET status='ended',ended_at=now() WHERE id=s.id;
  END IF;
  SELECT theme_id INTO tid FROM public.organizations WHERE id=oid;
  deadline:=now()+make_interval(secs=>r.remaining_seconds);
  INSERT INTO public.rental_sessions(org_id,device_id,rental_account_id,code,session_type,started_at,deadline_at,status,last_client_at,
    last_client_remaining_seconds,source_event_id,theme_id,metadata)
  VALUES(oid,did,r.id,c,'rental',now(),deadline,'active',now(),r.remaining_seconds,nullif(trim(p_source_event_id),''),coalesce(r.theme_id,tid),
    jsonb_build_object('source','global-rental-api')) RETURNING id INTO sid;
  INSERT INTO public.rental_offline_leases(rental_account_id,org_id,device_id,lease_until,created_at,updated_at)
  VALUES(r.id,oid,did,deadline+make_interval(secs=>1800),now(),now())
  ON CONFLICT(rental_account_id) DO UPDATE SET org_id=EXCLUDED.org_id,device_id=EXCLUDED.device_id,
    lease_until=EXCLUDED.lease_until,updated_at=now()
  WHERE public.rental_offline_leases.device_id=did OR public.rental_offline_leases.lease_until<=now();
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC'; END IF;
  RETURN jsonb_build_object('ok',true,'session_id',sid,'rental_account_id',r.id,'code',c,
    'remaining_seconds',r.remaining_seconds,'deadline_at',deadline,'status','active','idempotent',false);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_sync(p_token text, p_events jsonb DEFAULT '[]'::jsonb)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  item jsonb;
  accepted jsonb := '[]'::jsonb;
  conflicts jsonb := '[]'::jsonb;
  sid text;
  inserted_count integer := 0;
  rid uuid;
  tid uuid;
  existing_device_id uuid;
  evtype text;
  c text;
  base_updated timestamptz;
  existing_updated timestamptz;
  existing_source text;
  existing_source_event text;
  existing_source_device text;
BEGIN
  IF jsonb_typeof(coalesce(p_events, '[]'::jsonb)) <> 'array' THEN
    RAISE EXCEPTION 'EVENTS_MUST_BE_ARRAY';
  END IF;
  IF jsonb_array_length(coalesce(p_events, '[]'::jsonb)) > 100
     OR pg_column_size(coalesce(p_events, '[]'::jsonb)) > 524288 THEN
    RAISE EXCEPTION 'EVENT_BATCH_TOO_LARGE';
  END IF;

  SELECT d.id, d.org_id INTO did, oid
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;

  FOR item IN SELECT value FROM jsonb_array_elements(coalesce(p_events, '[]'::jsonb)) LOOP
    sid := nullif(trim(item->>'sourceEventId'), '');
    IF sid IS NULL THEN CONTINUE; END IF;

    evtype := coalesce(nullif(item->>'eventType', ''), 'system');
    c := upper(trim(coalesce(item->>'code', '')));

    IF evtype = 'rental_account_upsert' AND c <> '' THEN
      base_updated := nullif(item->'payload'->>'baseUpdatedAt', '')::timestamptz;

      -- Serialize concurrent upserts for the same organization/code, then inspect
      -- the unique row regardless of device ownership so retries cannot collide.
      PERFORM pg_advisory_xact_lock(hashtextextended(oid::text || ':' || c, 0));

      SELECT id, theme_id, device_id, updated_at, metadata->>'source', metadata->>'sourceEventId', metadata->>'originDeviceId'
      INTO rid, tid, existing_device_id, existing_updated, existing_source, existing_source_event, existing_source_device
      FROM public.rental_accounts
      WHERE org_id = oid AND upper(trim(code)) = c
      LIMIT 1
      FOR UPDATE;

      IF base_updated IS NOT NULL AND existing_updated IS NOT NULL AND existing_updated > base_updated AND existing_source_event IS DISTINCT FROM sid THEN
        INSERT INTO public.rental_sync_conflicts(org_id,device_id,code,source_event_id,reason,event_payload)
        VALUES(oid,did,c,sid,'CLOUD_ROW_CHANGED_SINCE_LOCAL_BASE',item)
        ON CONFLICT(org_id,source_event_id) DO NOTHING;
        conflicts := conflicts || jsonb_build_array(sid);
        CONTINUE;
      END IF;

      -- Existing cloud accounts are authoritative. Only retry an account created
      -- by this same PC sync path; never overwrite an admin/global row or another PC row.
      IF rid IS NOT NULL AND NOT (coalesce(existing_source_device, existing_device_id::text) = did::text AND existing_source = 'pc-sync' AND (base_updated IS NOT NULL OR existing_source_event = sid)) THEN
        INSERT INTO public.rental_sync_conflicts(org_id,device_id,code,source_event_id,reason,event_payload)
        VALUES(oid,did,c,sid,'CODE_ALREADY_EXISTS_IN_SHARED_DB',item)
        ON CONFLICT(org_id,source_event_id) DO NOTHING;
        conflicts := conflicts || jsonb_build_array(sid);
        CONTINUE;
      END IF;

      IF tid IS NULL THEN
        SELECT theme_id INTO tid FROM public.organizations WHERE id = oid;
      END IF;

      IF rid IS NULL THEN
        INSERT INTO public.rental_accounts(
          org_id, device_id, code, category, remaining_seconds, expiry_at,
          status, client_label, theme_id, metadata
        )
        VALUES (
          oid, NULL, c,
          coalesce(nullif(item->>'category', ''), 'reguler'),
          greatest(0, coalesce((item->>'remainingSeconds')::bigint, 0)),
          nullif(item->>'expiryDate', '')::timestamptz,
          'active', nullif(item->>'clientLabel', ''), tid,
          jsonb_build_object('source', 'pc-sync', 'sourceEventId', sid, 'originDeviceId', did)
        )
        RETURNING id INTO rid;
      ELSE
        UPDATE public.rental_accounts
        SET device_id = did,
            category = coalesce(nullif(item->>'category', ''), category),
            remaining_seconds = greatest(0, coalesce((item->>'remainingSeconds')::bigint, 0)),
            expiry_at = nullif(item->>'expiryDate', '')::timestamptz,
            status = 'active',
            client_label = coalesce(nullif(item->>'clientLabel', ''), client_label),
            metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object('sourceEventId', sid, 'originDeviceId', did),
            updated_at = now()
        WHERE id = rid;
      END IF;

      accepted := accepted || jsonb_build_array(sid);
      inserted_count := inserted_count + 1;
      CONTINUE;
    END IF;

    IF evtype = 'rental_account_delete' AND c <> '' THEN
      UPDATE public.rental_accounts
      SET status = 'disabled', updated_at = now()
      WHERE org_id = oid AND device_id = did AND code = c;
      accepted := accepted || jsonb_build_array(sid);
      inserted_count := inserted_count + 1;
      CONTINUE;
    END IF;

    SELECT id, theme_id INTO rid, tid
    FROM public.rental_accounts
    WHERE org_id = oid AND upper(trim(code)) = c AND (device_id IS NULL OR device_id = did)
    ORDER BY CASE WHEN device_id = did THEN 0 ELSE 1 END, created_at DESC
    LIMIT 1;
    IF tid IS NULL THEN
      SELECT theme_id INTO tid FROM public.organizations WHERE id = oid;
    END IF;

    INSERT INTO public.usage_events(
      org_id, device_id, rental_session_id, rental_account_id, theme_id,
      event_type, data_class, occurred_at, duration_seconds, category,
      client_label, payload, source_event_id, reseller_org_id
    )
    VALUES (
      oid, did,
      CASE WHEN nullif(item->>'sessionId', '') IS NULL THEN NULL ELSE (item->>'sessionId')::uuid END,
      rid, tid, evtype,
      coalesce(nullif(item->>'dataClass', ''), 'system'),
      coalesce((item->>'occurredAt')::timestamptz, now()),
      greatest(0, coalesce((item->>'durationSeconds')::integer, 0)),
      nullif(item->>'category', ''), nullif(item->>'clientLabel', ''),
      coalesce(item->'payload', '{}'::jsonb), sid, oid
    )
    ON CONFLICT (org_id, source_event_id)
      WHERE source_event_id IS NOT NULL DO NOTHING;

    IF FOUND THEN inserted_count := inserted_count + 1; END IF;
    accepted := accepted || jsonb_build_array(sid);
  END LOOP;

  UPDATE public.devices SET last_seen_at = now(), status = 'online' WHERE id = did;
  RETURN jsonb_build_object(
    'acceptedSourceEventIds', accepted,
    'conflictSourceEventIds', conflicts,
    'inserted', inserted_count,
    'serverTime', now()
  );
END
$function$;

CREATE OR REPLACE FUNCTION api.device_sync_cursor(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE did uuid; oid uuid; ts timestamptz:=now();
BEGIN
  SELECT d.id,d.org_id INTO did,oid FROM public.device_tokens t JOIN public.devices d ON d.id=t.device_id
  WHERE t.token_hash=encode(extensions.digest(p_token,'sha256'),'hex') AND t.revoked_at IS NULL;
  IF did IS NULL THEN RAISE EXCEPTION 'INVALID_DEVICE_TOKEN'; END IF;
  RETURN jsonb_build_object('ok',true,'deviceId',did,'orgId',oid,'cursor',ts,'serverTime',ts);
END
$function$;

CREATE OR REPLACE FUNCTION api.device_watchdog_poll(p_token text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  did uuid;
  oid uuid;
  command_row public.device_commands%ROWTYPE;
BEGIN
  IF COALESCE(btrim(p_token), '') = '' THEN
    RAISE EXCEPTION 'INVALID_DEVICE_TOKEN';
  END IF;

  SELECT d.id, d.org_id INTO did, oid
  FROM public.device_tokens t
  JOIN public.devices d ON d.id = t.device_id
  WHERE t.token_hash = encode(extensions.digest(p_token, 'sha256'), 'hex')
    AND t.revoked_at IS NULL
  ORDER BY t.created_at DESC
  LIMIT 1;

  IF did IS NULL THEN
    RAISE EXCEPTION 'INVALID_DEVICE_TOKEN';
  END IF;

  SELECT c.* INTO command_row
  FROM public.device_commands c
  WHERE c.device_id = did
    AND c.command = 'restart_billing'
    AND c.created_at >= now() - interval '24 hours'
    AND c.status = 'queued'
  ORDER BY c.created_at, c.id
  LIMIT 1
  FOR UPDATE SKIP LOCKED;

  IF NOT FOUND THEN
    RETURN jsonb_build_object(
      'ok', true,
      'device_id', did,
      'commands', '[]'::jsonb
    );
  END IF;

  UPDATE public.device_commands
  SET status = 'acknowledged',
      acknowledged_at = now(),
      delivered_at = now(),
      delivery_attempts = COALESCE(delivery_attempts, 0) + 1
  WHERE id = command_row.id
  RETURNING * INTO command_row;

  RETURN jsonb_build_object(
    'ok', true,
    'device_id', did,
    'commands', jsonb_build_array(jsonb_build_object(
      'id', command_row.id,
      'command', command_row.command,
      'payload', command_row.payload,
      'status', command_row.status,
      'created_at', command_row.created_at,
      'delivery_attempts', command_row.delivery_attempts
    ))
  );
END;
$function$;

CREATE OR REPLACE FUNCTION api.redeem_device(p_code text, p_client_id text, p_device_name text, p_app_version text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  e public.device_enrollments%ROWTYPE;
  d public.devices%ROWTYPE;
  v_token text;
  v_token_hash text;
  is_existing boolean := false;
  token_rows integer := 0;
  recovery_target uuid := NULL;
BEGIN
  IF coalesce(trim(p_client_id), '') = '' THEN RAISE EXCEPTION 'CLIENT_ID_REQUIRED'; END IF;

  SELECT * INTO e
  FROM public.device_enrollments
  WHERE code_hash = encode(extensions.digest(upper(trim(p_code)), 'sha256'), 'hex')
    AND (expires_at IS NULL OR expires_at > now())
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'INVALID_ENROLLMENT'; END IF;

  IF left(coalesce(e.label, ''), 13) = '__RECOVERY__:' THEN
    BEGIN
      recovery_target := split_part(e.label, ':', 2)::uuid;
    EXCEPTION WHEN invalid_text_representation THEN
      RAISE EXCEPTION 'INVALID_ENROLLMENT';
    END;
    -- Recovery codes are one-use, even if presented again by the same PC.
    IF e.used_at IS NOT NULL THEN RAISE EXCEPTION 'INVALID_ENROLLMENT'; END IF;

    SELECT * INTO d
    FROM public.devices
    WHERE id = recovery_target AND org_id = e.org_id
    FOR UPDATE;
    IF NOT FOUND THEN RAISE EXCEPTION 'RECOVERY_DEVICE_NOT_FOUND'; END IF;
    IF NOT (
      d.client_id = trim(p_client_id)
      OR coalesce(d.metadata->'clientIdAliases', '[]'::jsonb) ? trim(p_client_id)
    ) THEN
      RAISE EXCEPTION 'RECOVERY_DEVICE_ID_MISMATCH';
    END IF;
    is_existing := true;
  ELSE
    -- Existing standard pairing behavior remains unchanged.
    SELECT * INTO d
    FROM public.devices
    WHERE org_id = e.org_id
      AND (client_id = trim(p_client_id) OR coalesce(metadata->'clientIdAliases', '[]'::jsonb) ? trim(p_client_id))
    ORDER BY CASE WHEN client_id = trim(p_client_id) THEN 0 ELSE 1 END, created_at ASC
    LIMIT 1
    FOR UPDATE;
    is_existing := FOUND;
  END IF;

  IF is_existing THEN
    IF e.used_at IS NOT NULL AND e.redeemed_device_id IS NOT NULL AND e.redeemed_device_id <> d.id THEN
      RAISE EXCEPTION 'INVALID_ENROLLMENT';
    END IF;
    UPDATE public.devices
    SET device_name = CASE
          WHEN client_id = trim(p_client_id)
          THEN coalesce(nullif(trim(metadata->>'custom_device_name'), ''), nullif(trim(p_device_name), ''), device_name)
          ELSE device_name
        END,
        app_version = coalesce(nullif(trim(p_app_version), ''), app_version),
        status = 'online',
        last_seen_at = now(),
        metadata = coalesce(metadata, '{}'::jsonb) || jsonb_build_object(
          'last_repaired_at', now(),
          'pairing_mode', CASE WHEN recovery_target IS NOT NULL THEN 'resume-existing-targeted' ELSE 'resume-existing' END
        )
    WHERE id = d.id;
    UPDATE public.device_enrollments
    SET used_at = coalesce(used_at, now()), redeemed_device_id = coalesce(redeemed_device_id, d.id)
    WHERE id = e.id;
  ELSE
    -- Never let a targeted recovery code fall through to the new-device insert path.
    IF recovery_target IS NOT NULL THEN RAISE EXCEPTION 'RECOVERY_DEVICE_NOT_FOUND'; END IF;
    IF e.used_at IS NOT NULL THEN RAISE EXCEPTION 'INVALID_ENROLLMENT'; END IF;
    INSERT INTO public.devices(org_id, client_id, device_name, status, app_version, last_seen_at, metadata)
    VALUES (
      e.org_id, trim(p_client_id), coalesce(nullif(trim(p_device_name), ''), trim(p_client_id)),
      'online', nullif(trim(p_app_version), ''), now(), jsonb_build_object('enrolled_at', now())
    )
    RETURNING * INTO d;
    UPDATE public.device_enrollments SET used_at = now(), redeemed_device_id = d.id WHERE id = e.id;
  END IF;

  v_token := replace(gen_random_uuid()::text || gen_random_uuid()::text, '-', '');
  v_token_hash := encode(extensions.digest(v_token, 'sha256'), 'hex');
  UPDATE public.device_tokens
  SET token_hash = v_token_hash, created_at = now(), revoked_at = NULL
  WHERE device_id = d.id;
  GET DIAGNOSTICS token_rows = ROW_COUNT;
  IF token_rows = 0 THEN
    INSERT INTO public.device_tokens(device_id, token_hash) VALUES (d.id, v_token_hash);
  END IF;

  INSERT INTO public.audit_logs(org_id, actor_device_id, action, target_type, target_id, payload)
  VALUES (
    e.org_id, d.id,
    CASE WHEN is_existing THEN 'device_repaired' ELSE 'device_enrolled' END,
    'device', d.id::text,
    jsonb_build_object(
      'client_id', p_client_id,
      'device_name', p_device_name,
      'resumed_existing', is_existing,
      'token_rotated_in_place', token_rows > 0,
      'recovery_targeted', recovery_target IS NOT NULL
    )
  );

  RETURN jsonb_build_object(
    'device_id', d.id,
    'org_id', d.org_id,
    'token', v_token,
    'client_id', p_client_id,
    'resumed_existing', is_existing,
    'token_rotated_in_place', token_rows > 0,
    'recovery_targeted', recovery_target IS NOT NULL
  );
END
$function$;
COMMIT;
