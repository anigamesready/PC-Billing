-- Telegram rental event-only reporting for Ani Games Ready DB1.
-- Only session start and session end events are delivered to the Telegram group.
-- The PC presence, standby, test-message, and daily-recap events are skipped.
-- The existing bot token, chat ID, and reporting key remain in Supabase secrets/Vault.

CREATE OR REPLACE FUNCTION api.telegram_reporting_tick(p_key text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'reporting_private', 'vault'
AS $function$
DECLARE
  v_enabled boolean;
  v_claimed jsonb;
BEGIN
  IF p_key IS NULL OR NOT EXISTS (
    SELECT 1
    FROM vault.decrypted_secrets
    WHERE name = 'ani_games_telegram_reporting_key'
      AND decrypted_secret = p_key
  ) THEN
    RAISE EXCEPTION 'REPORTING_UNAUTHORIZED';
  END IF;

  SELECT enabled
    INTO v_enabled
  FROM reporting_private.telegram_settings
  WHERE id = 1
  FOR UPDATE;

  IF NOT coalesce(v_enabled, false) THEN
    RETURN jsonb_build_object('ok', true, 'enabled', false, 'claimed', '[]'::jsonb);
  END IF;

  IF NOT pg_try_advisory_xact_lock(hashtext('ani-games-telegram-reporting')::bigint) THEN
    RETURN jsonb_build_object('ok', true, 'busy', true, 'claimed', '[]'::jsonb);
  END IF;

  -- Event-only mode: permanently skip non-rental notifications instead of
  -- sending daily recaps, PC presence changes, standby, or test messages.
  UPDATE reporting_private.telegram_notification_outbox
  SET status = 'skipped',
      last_error = 'Event-only Telegram reporting: non-rental event disabled',
      claimed_at = NULL
  WHERE event_type NOT IN ('rental_started', 'rental_finished')
    AND status IN ('pending', 'failed', 'processing');

  WITH candidates AS (
    SELECT
      o.id,
      CASE
        WHEN o.event_type = 'rental_finished' THEN
          o.payload || jsonb_build_object(
            'resolved_reason', reason.end_reason,
            'classification',
              CASE
                WHEN lower(coalesce(o.payload->>'status', '')) = 'expired'
                  OR reason.end_reason = ANY(ARRAY[
                    'expired','auto_expired','time_expired','timer_expired',
                    'deadline_reached','rental_expired','session_timeout',
                    'time_up','time_expiry'
                  ])
                  THEN 'expired'
                WHEN reason.end_reason = ANY(ARRAY[
                  'client_stop','manual_stop','admin_stop','operator_stop',
                  'stopped_by_admin','cancelled','user_stop','stop_session',
                  'billing_stop','stopped'
                ])
                  THEN 'manual'
                ELSE 'unknown'
              END
          )
        ELSE o.payload
      END AS resolved_payload
    FROM reporting_private.telegram_notification_outbox o
    CROSS JOIN LATERAL (
      SELECT coalesce(
        nullif(lower(btrim(o.payload->>'recovery_reason')), ''),
        (
          SELECT nullif(lower(btrim(ue.payload->>'reason')), '')
          FROM public.usage_events ue
          WHERE ue.rental_session_id = o.session_id
            AND ue.event_type = 'session_ended'
          ORDER BY ue.occurred_at DESC
          LIMIT 1
        ),
        ''
      ) AS end_reason
    ) reason
    WHERE o.event_type IN ('rental_started', 'rental_finished')
      AND o.attempts < 5
      AND (
        (
          o.status IN ('pending', 'failed')
          AND coalesce(o.next_attempt_at, now()) <= now()
        )
        OR (
          o.status = 'processing'
          AND o.claimed_at < now() - interval '5 minutes'
        )
      )
    ORDER BY o.created_at
    FOR UPDATE OF o SKIP LOCKED
    LIMIT 20
  ),
  claimed AS (
    UPDATE reporting_private.telegram_notification_outbox o
    SET status = 'processing',
        attempts = o.attempts + 1,
        claimed_at = now(),
        last_error = NULL,
        payload = c.resolved_payload
    FROM candidates c
    WHERE o.id = c.id
    RETURNING
      o.id, o.event_key, o.event_type, o.org_id, o.device_id,
      o.session_id, o.occurred_at, o.payload, o.attempts
  )
  SELECT coalesce(
    jsonb_agg(to_jsonb(claimed) ORDER BY claimed.occurred_at, claimed.id),
    '[]'::jsonb
  )
  INTO v_claimed
  FROM claimed;

  RETURN jsonb_build_object(
    'ok', true,
    'enabled', true,
    'mode', 'rental_events_only',
    'claimed', coalesce(v_claimed, '[]'::jsonb)
  );
END
$function$;

UPDATE reporting_private.telegram_settings
SET enabled = true,
    updated_at = now()
WHERE id = 1;

DO $$
DECLARE
  v_job_id bigint;
BEGIN
  SELECT jobid
    INTO v_job_id
  FROM cron.job
  WHERE jobname = 'ani-games-telegram-reporting-minute'
  LIMIT 1;

  IF v_job_id IS NULL THEN
    RAISE EXCEPTION 'TELEGRAM_REPORTING_CRON_JOB_NOT_FOUND';
  END IF;

  PERFORM cron.alter_job(job_id := v_job_id, active := true);
END
$$;
