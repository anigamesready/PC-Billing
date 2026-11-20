-- Explicitly permit Cloudflare Mesh IPv4 addresses as the approved media overlay.
-- No broad CGNAT range is allowed: only the documented Mesh allocation 100.96.0.0/12.
-- Existing RFC1918 and ULA WireGuard routes remain supported.
BEGIN;

CREATE OR REPLACE FUNCTION api.remote_play_host_heartbeat(
  p_host_token text,p_sunshine_ready boolean,p_media_address inet,p_agent_version text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  h remote_play.host_registrations%ROWTYPE;
  permitted boolean;
  active_session remote_play.sessions%ROWTYPE;
BEGIN
  h:=private.remote_play_get_host(p_host_token);
  SELECT enabled INTO permitted FROM remote_play.host_permissions
  WHERE device_id=h.device_id AND org_id=h.org_id;
  IF NOT coalesce(permitted,false) THEN
    UPDATE remote_play.host_registrations SET sunshine_ready=false,last_heartbeat_at=now(),updated_at=now()
    WHERE device_id=h.device_id;
    RETURN jsonb_build_object('ok',true,'permission_enabled',false,'server_time',now());
  END IF;
  IF p_media_address IS NOT NULL AND NOT (
      p_media_address <<= inet '10.0.0.0/8'
      OR p_media_address <<= inet '172.16.0.0/12'
      OR p_media_address <<= inet '192.168.0.0/16'
      OR p_media_address <<= inet 'fc00::/7'
      OR p_media_address <<= inet '100.96.0.0/12'
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_MEDIA_ADDRESS_MUST_BE_APPROVED_OVERLAY';
  END IF;

  UPDATE remote_play.host_registrations
  SET sunshine_ready=coalesce(p_sunshine_ready,false),
      media_address=coalesce(p_media_address,media_address),
      agent_version=coalesce(left(p_agent_version,80),agent_version),
      last_heartbeat_at=now(),updated_at=now()
  WHERE device_id=h.device_id;

  SELECT * INTO active_session FROM remote_play.sessions
  WHERE device_id=h.device_id AND status IN ('starting','active') AND settled_at IS NULL
  ORDER BY started_at DESC LIMIT 1;
  RETURN jsonb_build_object('ok',true,'permission_enabled',true,
    'sunshine_ready',coalesce(p_sunshine_ready,false),'server_time',now(),
    'active_session',CASE WHEN active_session.id IS NULL THEN NULL ELSE
      jsonb_build_object('id',active_session.id,'deadline_at',active_session.deadline_at,
        'status',active_session.status) END);
END;
$function$;

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
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  SELECT * INTO r FROM public.rental_accounts WHERE id=c.rental_account_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  SELECT enabled INTO perm FROM remote_play.rental_permissions WHERE rental_account_id=r.id;
  SELECT * INTO active_session FROM remote_play.sessions
    WHERE rental_account_id=r.id AND status IN ('starting','active') AND settled_at IS NULL
    ORDER BY started_at DESC LIMIT 1;

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
      AND (r.expiry_at IS NULL OR r.expiry_at>now()) AND active_session.id IS NULL,
    'active_session',CASE WHEN active_session.id IS NULL THEN NULL ELSE jsonb_build_object(
      'id',active_session.id,'device_id',active_session.device_id,'status',active_session.status,
      'deadline_at',active_session.deadline_at,'cooldown_until',active_session.cooldown_until) END,
    'hosts',hosts,'server_time',now());
END;
$function$;

COMMIT;
