-- Additive one-time Sunshine pairing challenge API for Ani Remote Play.
-- This migration is source-only until explicitly reviewed and applied to staging.
BEGIN;

CREATE TABLE IF NOT EXISTS remote_play.pairing_challenges (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  session_id uuid NOT NULL REFERENCES remote_play.sessions(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  client_session_id uuid NOT NULL REFERENCES remote_play.client_sessions(id) ON DELETE CASCADE,
  client_name text NOT NULL CHECK (length(client_name) BETWEEN 8 AND 64),
  pin text NOT NULL CHECK (pin ~ '^[0-9]{4}$'),
  status text NOT NULL DEFAULT 'pending' CHECK (status IN ('pending','paired','failed','expired')),
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL DEFAULT now() + interval '120 seconds',
  delivered_at timestamptz,
  completed_at timestamptz,
  sunshine_pairing_id text,
  failure_reason text,
  result jsonb NOT NULL DEFAULT '{}'::jsonb,
  CHECK (expires_at > created_at)
);

CREATE INDEX IF NOT EXISTS remote_play_pairing_host_pending_idx
  ON remote_play.pairing_challenges(device_id, expires_at, created_at DESC)
  WHERE status='pending';

CREATE UNIQUE INDEX IF NOT EXISTS remote_play_one_pending_pairing_per_session
  ON remote_play.pairing_challenges(session_id)
  WHERE status='pending';

ALTER TABLE remote_play.pairing_challenges ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE remote_play.pairing_challenges FROM PUBLIC;
REVOKE ALL ON TABLE remote_play.pairing_challenges FROM ani_api_runtime;

CREATE OR REPLACE FUNCTION api.remote_play_pairing_prepare(
  p_session_token text,
  p_session_id uuid,
  p_pin text,
  p_client_name text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
  challenge remote_play.pairing_challenges%ROWTYPE;
BEGIN
  c := private.remote_play_get_client(p_session_token);

  IF coalesce(p_pin,'') !~ '^[0-9]{4}$' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_PIN_INVALID';
  END IF;
  IF coalesce(p_client_name,'') !~ '^ANI-[A-F0-9]{12}$' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_CLIENT_NAME_INVALID';
  END IF;

  SELECT * INTO s
  FROM remote_play.sessions
  WHERE id=p_session_id
    AND rental_account_id=c.rental_account_id
    AND client_session_id=c.id
    AND status IN ('starting','active')
    AND settled_at IS NULL
    AND deadline_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_SESSION_NOT_ACTIVE'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM remote_play.host_permissions hp
    WHERE hp.device_id=s.device_id AND hp.org_id=s.org_id AND hp.enabled
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_DISABLED';
  END IF;

  UPDATE remote_play.pairing_challenges
  SET status='expired', completed_at=now(), failure_reason='challenge_expired'
  WHERE session_id=s.id AND status='pending' AND expires_at<=now();

  SELECT * INTO challenge
  FROM remote_play.pairing_challenges
  WHERE session_id=s.id AND status='pending' AND expires_at>now()
  FOR UPDATE;

  IF FOUND THEN
    IF challenge.pin<>p_pin OR challenge.client_name<>p_client_name THEN
      UPDATE remote_play.pairing_challenges
      SET status='failed', completed_at=now(), failure_reason='superseded'
      WHERE id=challenge.id;
      challenge.id:=NULL;
    ELSE
      RETURN jsonb_build_object('ok',true,'challenge_id',challenge.id,
        'status','pending','expires_at',challenge.expires_at,'idempotent',true);
    END IF;
  END IF;

  INSERT INTO remote_play.pairing_challenges(
    org_id,session_id,device_id,client_session_id,client_name,pin,expires_at
  )
  VALUES(s.org_id,s.id,s.device_id,c.id,p_client_name,p_pin,now()+interval '120 seconds')
  RETURNING * INTO challenge;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(s.org_id,'client',c.id::text,'pairing_challenge_requested',s.id::text,
    jsonb_build_object('challenge_id',challenge.id,'client_name',p_client_name,'expires_at',challenge.expires_at));

  RETURN jsonb_build_object('ok',true,'challenge_id',challenge.id,
    'status','pending','expires_at',challenge.expires_at);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_host_pairing_poll(
  p_host_token text,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  h remote_play.host_registrations%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
  challenge remote_play.pairing_challenges%ROWTYPE;
  permission_enabled boolean;
BEGIN
  h := private.remote_play_get_host(p_host_token);
  SELECT enabled INTO permission_enabled
  FROM remote_play.host_permissions
  WHERE device_id=h.device_id AND org_id=h.org_id;

  IF NOT coalesce(permission_enabled,false) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_DISABLED';
  END IF;

  SELECT * INTO s
  FROM remote_play.sessions
  WHERE id=p_session_id AND device_id=h.device_id
    AND status IN ('starting','active') AND settled_at IS NULL AND deadline_at>now();
  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',true,'pending',false,'reason','session_not_active');
  END IF;

  SELECT * INTO challenge
  FROM remote_play.pairing_challenges
  WHERE session_id=s.id AND device_id=h.device_id
    AND status='pending' AND expires_at>now()
  ORDER BY created_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RETURN jsonb_build_object('ok',true,'pending',false);
  END IF;

  UPDATE remote_play.pairing_challenges
  SET delivered_at=coalesce(delivered_at,now())
  WHERE id=challenge.id;

  RETURN jsonb_build_object('ok',true,'pending',true,
    'challenge_id',challenge.id,'session_id',challenge.session_id,
    'client_name',challenge.client_name,'pin',challenge.pin,
    'expires_at',challenge.expires_at);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_host_pairing_complete(
  p_host_token text,
  p_session_id uuid,
  p_challenge_id uuid,
  p_success boolean,
  p_sunshine_pairing_id text DEFAULT NULL,
  p_failure_reason text DEFAULT NULL
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  h remote_play.host_registrations%ROWTYPE;
  challenge remote_play.pairing_challenges%ROWTYPE;
BEGIN
  h := private.remote_play_get_host(p_host_token);

  SELECT * INTO challenge
  FROM remote_play.pairing_challenges
  WHERE id=p_challenge_id AND session_id=p_session_id AND device_id=h.device_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_CHALLENGE_NOT_FOUND'; END IF;

  IF challenge.status IN ('paired','failed','expired') THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,
      'challenge_id',challenge.id,'status',challenge.status);
  END IF;

  IF challenge.expires_at<=now() THEN
    UPDATE remote_play.pairing_challenges
    SET status='expired',completed_at=now(),failure_reason='challenge_expired'
    WHERE id=challenge.id;
    RETURN jsonb_build_object('ok',false,'challenge_id',challenge.id,'status','expired');
  END IF;

  IF coalesce(p_success,false) AND coalesce(p_sunshine_pairing_id,'') !~ '^[0-9a-fA-F]{32}$' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_PAIRING_ID_INVALID';
  END IF;

  UPDATE remote_play.pairing_challenges
  SET status=CASE WHEN p_success THEN 'paired' ELSE 'failed' END,
      completed_at=now(),
      sunshine_pairing_id=CASE WHEN p_success THEN lower(p_sunshine_pairing_id) ELSE NULL END,
      failure_reason=CASE WHEN p_success THEN NULL ELSE left(coalesce(p_failure_reason,'pairing_failed'),80) END
  WHERE id=challenge.id;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(challenge.org_id,'host',h.device_id::text,
    CASE WHEN p_success THEN 'pairing_completed' ELSE 'pairing_failed' END,
    challenge.session_id::text,
    jsonb_build_object('challenge_id',challenge.id,'sunshine_pairing_id',
      CASE WHEN p_success THEN lower(p_sunshine_pairing_id) ELSE NULL END));

  RETURN jsonb_build_object('ok',true,'challenge_id',challenge.id,
    'status',CASE WHEN p_success THEN 'paired' ELSE 'failed' END);
END;
$function$;

REVOKE ALL ON FUNCTION api.remote_play_pairing_prepare(text,uuid,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_host_pairing_poll(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_host_pairing_complete(text,uuid,uuid,boolean,text,text) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.remote_play_pairing_prepare(text,uuid,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_host_pairing_poll(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_host_pairing_complete(text,uuid,uuid,boolean,text,text) TO ani_api_runtime;

COMMIT;
