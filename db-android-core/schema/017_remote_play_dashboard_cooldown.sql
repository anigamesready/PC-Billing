-- Expose the server-enforced 10-minute post-session cooldown to the Android dashboard.
-- This is additive: no session, balance, token, or permission rows are modified.
BEGIN;
CREATE OR REPLACE FUNCTION api.remote_play_dashboard(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  perm boolean;
  hosts jsonb;
  active_session remote_play.sessions%ROWTYPE;
  cooldown_until timestamptz;
  cooldown_seconds bigint := 0;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  SELECT * INTO r FROM public.rental_accounts WHERE id=c.rental_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  SELECT enabled INTO perm FROM remote_play.rental_permissions WHERE rental_account_id=r.id;
  SELECT * INTO active_session FROM remote_play.sessions
    WHERE rental_account_id=r.id AND status IN ('starting','active') AND settled_at IS NULL
    ORDER BY started_at DESC LIMIT 1;

  SELECT max(s.cooldown_until) INTO cooldown_until
  FROM remote_play.sessions s
  WHERE s.rental_account_id=r.id AND s.cooldown_until>now();
  cooldown_seconds:=CASE WHEN cooldown_until IS NULL THEN 0 ELSE
    greatest(0,ceil(extract(epoch FROM (cooldown_until-now())))::bigint) END;

  SELECT coalesce(jsonb_agg(jsonb_build_object(
    'device_id',d.id,'client_id',d.client_id,'device_name',d.device_name,
    'online',coalesce(d.status='online' AND h.last_heartbeat_at>now()-interval '60 seconds',false),
    'sunshine_ready',coalesce(h.sunshine_ready,false),
    'media_path_ready',h.media_address IS NOT NULL,
    'media_address',CASE WHEN h.media_address IS NULL THEN NULL ELSE host(h.media_address) END,
    'available',coalesce(h.last_heartbeat_at>now()-interval '60 seconds' AND h.sunshine_ready AND h.media_address IS NOT NULL,false)
      AND hp.enabled AND NOT EXISTS(SELECT 1 FROM remote_play.sessions s WHERE s.device_id=d.id
        AND s.status IN ('starting','active') AND s.settled_at IS NULL AND s.deadline_at>now()),
    'last_seen_at',h.last_heartbeat_at
  ) ORDER BY d.device_name),'[]'::jsonb)
  INTO hosts
  FROM remote_play.host_permissions hp
  JOIN public.devices d ON d.id=hp.device_id AND d.org_id=hp.org_id
  LEFT JOIN remote_play.host_registrations h ON h.device_id=d.id AND h.revoked_at IS NULL
  WHERE hp.org_id=r.org_id AND hp.enabled;

  RETURN jsonb_build_object('ok',true,
    'rental_account',jsonb_build_object('id',r.id,'code',r.code,'category',r.category,
      'remaining_seconds',greatest(0,r.remaining_seconds),'expiry_at',r.expiry_at,'status',r.status,
      'client_label',r.client_label),
    'remote_play_enabled',coalesce(perm,false),
    'can_start',coalesce(perm,false) AND r.status='active' AND r.remaining_seconds>0
      AND (r.expiry_at IS NULL OR r.expiry_at>now()) AND active_session.id IS NULL
      AND cooldown_seconds=0,
    'active_session',CASE WHEN active_session.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',active_session.id,'device_id',active_session.device_id,'status',active_session.status,
      'deadline_at',active_session.deadline_at,'cooldown_until',active_session.cooldown_until) END,
    'cooldown_until',cooldown_until,
    'cooldown_seconds',cooldown_seconds,
    'hosts',hosts,'server_time',now());
END;
$function$;
COMMIT;
