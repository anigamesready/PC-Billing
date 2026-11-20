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

COMMIT;
