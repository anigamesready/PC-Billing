-- Remote Play server-side watchdog.
-- Settles stale sessions even if the Android client AND Windows Host Agent disappear.
-- Invoked only by the local DB Android API process; never exposed as a public RPC route.
BEGIN;

CREATE OR REPLACE FUNCTION api.remote_play_watchdog_sweep()
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  v_now timestamptz := now();
  session_row record;
  checked_count integer := 0;
  settled_count integer := 0;
  settle_reason text;
BEGIN
  -- Prevent concurrent API instances from running the same cleanup pass.
  IF NOT pg_try_advisory_xact_lock(hashtextextended('ani_remote_play_server_watchdog_v1',0)) THEN
    RETURN jsonb_build_object('ok',true,'skipped',true,'checked_sessions',0,
      'settled_sessions',0,'server_time',v_now);
  END IF;

  FOR session_row IN
    SELECT s.id, s.deadline_at, s.last_client_heartbeat_at,
      h.last_heartbeat_at AS host_last_heartbeat_at, h.revoked_at AS host_revoked_at
    FROM remote_play.sessions s
    LEFT JOIN remote_play.host_registrations h
      ON h.device_id=s.device_id AND h.org_id=s.org_id
    WHERE s.status IN ('starting','active')
      AND s.settled_at IS NULL
      AND (
        s.deadline_at <= v_now
        OR s.last_client_heartbeat_at <= v_now - interval '90 seconds'
        OR h.last_heartbeat_at IS NULL
        OR h.last_heartbeat_at <= v_now - interval '60 seconds'
        OR h.revoked_at IS NOT NULL
      )
    ORDER BY s.deadline_at, s.started_at
    LIMIT 100
    FOR UPDATE OF s SKIP LOCKED
  LOOP
    checked_count := checked_count + 1;
    settle_reason := CASE
      WHEN session_row.deadline_at <= v_now THEN 'deadline_expired'
      WHEN session_row.host_revoked_at IS NOT NULL
        OR session_row.host_last_heartbeat_at IS NULL
        OR session_row.host_last_heartbeat_at <= v_now - interval '60 seconds'
        THEN 'host_heartbeat_timeout'
      ELSE 'client_heartbeat_timeout'
    END;

    PERFORM private.remote_play_settle_session(session_row.id,settle_reason,true);
    settled_count := settled_count + 1;
  END LOOP;

  RETURN jsonb_build_object('ok',true,'skipped',false,
    'checked_sessions',checked_count,'settled_sessions',settled_count,
    'server_time',v_now);
END;
$function$;

REVOKE ALL ON FUNCTION api.remote_play_watchdog_sweep() FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.remote_play_watchdog_sweep() TO ani_api_runtime;

COMMIT;
