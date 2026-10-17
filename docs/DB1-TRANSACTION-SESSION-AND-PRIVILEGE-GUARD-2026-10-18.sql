-- DB1 fundamental hardening additions, captured 2026-10-18.
-- Review before applying to any non-DB1 environment. Existing live changes were applied incrementally.
-- Does not move traffic, copy business rows, or alter rental balances.

-- A. Bound direct client privileges.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM anon;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON TABLES FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM anon;

-- Authenticated clients use vetted API RPCs for writes. Keep a narrow legacy exception
-- for the shipped Admin APK's direct rental code/status update until that call is moved to an RPC.
REVOKE TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON ALL TABLES IN SCHEMA public FROM authenticated;
REVOKE INSERT, UPDATE, DELETE ON ALL TABLES IN SCHEMA public FROM authenticated;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM authenticated;
GRANT UPDATE (code, status) ON TABLE public.rental_accounts TO authenticated;
REVOKE INSERT, UPDATE, DELETE ON TABLE
  public.admin_pc_access, public.device_command_logs, public.device_heartbeats, public.device_trial_requests
FROM authenticated;
GRANT SELECT ON TABLE
  public.admin_pc_access, public.device_command_logs, public.device_heartbeats, public.device_trial_requests
TO authenticated;

ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE INSERT, UPDATE, DELETE, TRUNCATE, REFERENCES, TRIGGER, MAINTAIN ON TABLES FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE ALL PRIVILEGES ON SEQUENCES FROM authenticated;

-- Future public/api RPCs are not callable merely by default; explicitly grant intended clients.
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA public
  REVOKE EXECUTE ON FUNCTIONS FROM authenticated;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA api
  REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA api
  REVOKE EXECUTE ON FUNCTIONS FROM anon;
ALTER DEFAULT PRIVILEGES FOR ROLE postgres IN SCHEMA api
  REVOKE EXECUTE ON FUNCTIONS FROM authenticated;

-- B. Link free-test billing transactions to their session, fixing device_finalize_trial's schema dependency.
ALTER TABLE public.billing_transactions
  ADD COLUMN IF NOT EXISTS rental_session_id uuid;

DO $fk$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid='public.billing_transactions'::regclass
      AND conname='billing_transactions_rental_session_id_fkey'
  ) THEN
    ALTER TABLE public.billing_transactions
      ADD CONSTRAINT billing_transactions_rental_session_id_fkey
      FOREIGN KEY (rental_session_id)
      REFERENCES public.rental_sessions(id)
      ON DELETE SET NULL
      NOT VALID;
    ALTER TABLE public.billing_transactions
      VALIDATE CONSTRAINT billing_transactions_rental_session_id_fkey;
  END IF;
END
$fk$;

CREATE INDEX IF NOT EXISTS idx_billing_transactions_rental_session
  ON public.billing_transactions(rental_session_id);
CREATE UNIQUE INDEX IF NOT EXISTS billing_transactions_free_test_session_unique
  ON public.billing_transactions(rental_session_id)
  WHERE transaction_type='free_test' AND rental_session_id IS NOT NULL;

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

-- C. Conservative expiry reconciliation for stale offline sessions. Session only; rental balance is preserved.
DO $schedule$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM cron.job WHERE jobname='stale-offline-session-expiry-guard') THEN
    PERFORM cron.schedule(
      'stale-offline-session-expiry-guard',
      '*/5 * * * *',
      $job$
        WITH expired AS (
          UPDATE public.rental_sessions s
          SET status='expired',
              ended_at=COALESCE(s.ended_at,s.deadline_at,now()),
              recovery_reason=COALESCE(s.recovery_reason,'server_deadline_elapsed_device_offline')
          FROM public.devices d
          WHERE d.id=s.device_id
            AND d.status='offline'
            AND s.status IN ('active','paused')
            AND s.deadline_at IS NOT NULL
            AND s.deadline_at <= now()-interval '5 minutes'
            AND COALESCE(d.last_seen_at,s.last_client_at,s.started_at) <= now()-interval '5 minutes'
          RETURNING s.id,s.org_id,s.device_id,s.code,s.session_type,s.deadline_at,s.last_client_remaining_seconds
        ),
        logged AS (
          INSERT INTO public.audit_logs(org_id,actor_device_id,action,target_type,target_id,payload)
          SELECT e.org_id,e.device_id,'expire_stale_offline_rental_session','rental_session',e.id::text,
            jsonb_build_object(
              'reason','deadline elapsed while device offline; rental balance preserved',
              'session_code',e.code,'session_type',e.session_type,'deadline_at',e.deadline_at,
              'last_client_remaining_seconds',e.last_client_remaining_seconds,
              'source','stale-offline-session-expiry-guard'
            )
          FROM expired e
          RETURNING id
        )
        SELECT count(*) FROM logged;
      $job$
    );
  END IF;
END
$schedule$;

-- D. Final DB1 status checks after applying/reviewing:
--   * anon has no direct SELECT/INSERT on public application tables.
--   * authenticated has no table-level INSERT/UPDATE/DELETE/TRUNCATE; rental_accounts.code/status
--     are the only remaining direct updateable columns for current Admin APK compatibility.
--   * service_role keeps required server-side access.
--   * stale-offline-session-expiry-guard is active every 5 minutes.
--   * do not enable DB2 routing until row-level parity and backup/restore are proven.


-- E. Keep the shipped Admin APK's column-only code/status update path auditable and normalized.
-- Status-only changes must not normalize/rewrite a legacy code; normalize only when code changes.
CREATE OR REPLACE FUNCTION public.audit_normalize_rental_identity_update()
 RETURNS trigger
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'pg_catalog', 'public'
AS $function$
DECLARE
  actor uuid := auth.uid();
BEGIN
  -- Normalize only when the code itself changes. A status-only update must not
  -- rewrite an existing legacy code as a side effect.
  IF NEW.code IS DISTINCT FROM OLD.code THEN
    NEW.code := upper(trim(coalesce(NEW.code, '')));
    IF NEW.code = '' THEN
      RAISE EXCEPTION 'RENTAL_CODE_REQUIRED';
    END IF;
  END IF;

  IF NEW.code IS DISTINCT FROM OLD.code
     OR NEW.status IS DISTINCT FROM OLD.status THEN
    NEW.updated_at := now();

    IF actor IS NOT NULL THEN
      INSERT INTO public.audit_logs(
        org_id, actor_user_id, action, target_type, target_id, payload
      )
      VALUES(
        NEW.org_id, actor, 'rental_identity_updated', 'rental_account', NEW.id::text,
        jsonb_build_object(
          'old_code', OLD.code,
          'new_code', NEW.code,
          'old_status', OLD.status,
          'new_status', NEW.status,
          'source', 'rental_accounts-code-status-trigger'
        )
      );
    END IF;
  END IF;

  RETURN NEW;
END
$function$;

DROP TRIGGER IF EXISTS rental_accounts_audit_identity_update ON public.rental_accounts;
CREATE TRIGGER rental_accounts_audit_identity_update
BEFORE UPDATE OF code, status ON public.rental_accounts
FOR EACH ROW EXECUTE FUNCTION public.audit_normalize_rental_identity_update();

-- Rollback-wrapped tests verified status-only updates preserve legacy code, explicit code changes
-- normalize to uppercase/trim, exactly one audit row per actual change, and no test rows remain.

-- F. Replacement RPC for the remaining legacy Admin APK rental code/status update.
-- Granted only to authenticated and service_role; never to anon.
-- Keep the narrow column grant for already-installed APKs until v12.1.9 is installed and tested.
CREATE OR REPLACE FUNCTION api.admin_update_rental_identity(p_org_id uuid, p_device_id uuid, p_rental_id uuid, p_code text, p_status text)
 RETURNS jsonb
 LANGUAGE plpgsql
 SECURITY DEFINER
 SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  uid uuid := auth.uid();
  r public.rental_accounts%ROWTYPE;
  normalized_code text := upper(trim(coalesce(p_code, '')));
  normalized_status text := coalesce(p_status, '');
BEGIN
  IF uid IS NULL THEN
    RAISE EXCEPTION 'UNAUTHENTICATED';
  END IF;

  IF p_org_id IS NULL OR p_device_id IS NULL OR p_rental_id IS NULL THEN
    RAISE EXCEPTION 'RENTAL_IDENTITY_FIELDS_REQUIRED';
  END IF;

  IF NOT private.is_owner_access(p_org_id) THEN
    RAISE EXCEPTION 'OWNER_ONLY';
  END IF;

  IF normalized_code = '' OR length(normalized_code) > 120 THEN
    RAISE EXCEPTION 'RENTAL_CODE_INVALID';
  END IF;

  IF normalized_status NOT IN ('active', 'expired', 'disabled') THEN
    RAISE EXCEPTION 'RENTAL_STATUS_INVALID';
  END IF;

  SELECT * INTO r
  FROM public.rental_accounts
  WHERE id = p_rental_id
    AND org_id = p_org_id
    AND device_id = p_device_id
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'RENTAL_NOT_FOUND';
  END IF;

  IF EXISTS (
    SELECT 1
    FROM public.rental_accounts other
    WHERE other.org_id = p_org_id
      AND other.code = normalized_code
      AND other.id <> p_rental_id
  ) THEN
    RAISE EXCEPTION 'CODE_ALREADY_EXISTS';
  END IF;

  UPDATE public.rental_accounts
  SET code = normalized_code,
      status = normalized_status,
      updated_at = now()
  WHERE id = p_rental_id
    AND org_id = p_org_id
    AND device_id = p_device_id;

  RETURN jsonb_build_object(
    'ok', true,
    'id', p_rental_id,
    'org_id', p_org_id,
    'device_id', p_device_id,
    'code', normalized_code,
    'status', normalized_status,
    'updated_at', now()
  );
END
$function$;

REVOKE ALL PRIVILEGES ON FUNCTION api.admin_update_rental_identity(uuid,uuid,uuid,text,text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_identity(uuid,uuid,uuid,text,text) TO authenticated;
GRANT EXECUTE ON FUNCTION api.admin_update_rental_identity(uuid,uuid,uuid,text,text) TO service_role;

-- Rollback-wrapped SQL test verified owner-only scope, normalized update, single audit record,
-- duplicate-code rejection, and zero residual test rows.
