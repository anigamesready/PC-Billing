-- Ani Games Ready Remote Play: additive control-plane schema on the existing DB Android PostgreSQL.
-- Source baseline: feature/db-android-stop-pause-policy-20261118.
-- This migration is intentionally separate from the existing public Billing schema.
-- Apply only after 000 and 002-012 on a disposable/staging DB first. Never replay 001_db1_catalog_snapshot.sql.
-- No Supabase objects, credentials, network calls, or data migration are used.

BEGIN;

CREATE SCHEMA IF NOT EXISTS remote_play;
REVOKE ALL ON SCHEMA remote_play FROM PUBLIC;

CREATE TABLE IF NOT EXISTS remote_play.client_credentials (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  secret_hash text NOT NULL,
  enabled boolean NOT NULL DEFAULT true,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE UNIQUE INDEX IF NOT EXISTS remote_play_one_active_credential_per_rental
  ON remote_play.client_credentials(rental_account_id) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS remote_play.rental_permissions (
  rental_account_id uuid PRIMARY KEY REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  approved_by uuid,
  approved_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS remote_play.client_sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  refresh_token_hash text NOT NULL UNIQUE CHECK (refresh_token_hash ~ '^[0-9a-f]{64}$'),
  client_install_id text NOT NULL,
  created_at timestamptz NOT NULL DEFAULT now(),
  expires_at timestamptz NOT NULL,
  refresh_expires_at timestamptz NOT NULL,
  last_seen_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);
CREATE INDEX IF NOT EXISTS remote_play_client_sessions_rental_active_idx
  ON remote_play.client_sessions(rental_account_id, expires_at) WHERE revoked_at IS NULL;

CREATE TABLE IF NOT EXISTS remote_play.host_permissions (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  enabled boolean NOT NULL DEFAULT false,
  approved_by uuid,
  approved_at timestamptz,
  updated_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS remote_play.host_enrollments (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  code_hash text NOT NULL UNIQUE CHECK (code_hash ~ '^[0-9a-f]{64}$'),
  expires_at timestamptz NOT NULL,
  consumed_at timestamptz,
  created_by uuid,
  created_at timestamptz NOT NULL DEFAULT now()
);

CREATE TABLE IF NOT EXISTS remote_play.host_registrations (
  device_id uuid PRIMARY KEY REFERENCES public.devices(id) ON DELETE CASCADE,
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  token_hash text NOT NULL UNIQUE CHECK (token_hash ~ '^[0-9a-f]{64}$'),
  agent_version text,
  sunshine_ready boolean NOT NULL DEFAULT false,
  media_address inet,
  last_heartbeat_at timestamptz,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  revoked_at timestamptz
);

CREATE TABLE IF NOT EXISTS remote_play.sessions (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  rental_account_id uuid NOT NULL REFERENCES public.rental_accounts(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  client_session_id uuid NOT NULL REFERENCES remote_play.client_sessions(id) ON DELETE RESTRICT,
  status text NOT NULL DEFAULT 'starting' CHECK (status IN ('starting','active','ended','expired','revoked','failed')),
  started_at timestamptz NOT NULL DEFAULT now(),
  deadline_at timestamptz NOT NULL,
  last_client_heartbeat_at timestamptz NOT NULL DEFAULT now(),
  host_started_at timestamptz,
  ended_at timestamptz,
  cooldown_until timestamptz,
  starting_balance_seconds bigint NOT NULL CHECK (starting_balance_seconds >= 0),
  settled_seconds bigint NOT NULL DEFAULT 0 CHECK (settled_seconds >= 0),
  settled_at timestamptz,
  end_reason text,
  idempotency_key text,
  created_at timestamptz NOT NULL DEFAULT now(),
  CHECK (deadline_at > started_at),
  CHECK (deadline_at <= started_at + interval '3 hours')
);
CREATE UNIQUE INDEX IF NOT EXISTS remote_play_one_open_session_per_rental
  ON remote_play.sessions(rental_account_id) WHERE status IN ('starting','active') AND settled_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS remote_play_one_open_session_per_host
  ON remote_play.sessions(device_id) WHERE status IN ('starting','active') AND settled_at IS NULL;
CREATE UNIQUE INDEX IF NOT EXISTS remote_play_client_idempotency_key
  ON remote_play.sessions(client_session_id, idempotency_key)
  WHERE idempotency_key IS NOT NULL;
CREATE INDEX IF NOT EXISTS remote_play_sessions_org_recent_idx
  ON remote_play.sessions(org_id, created_at DESC);

CREATE TABLE IF NOT EXISTS remote_play.commands (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  session_id uuid NOT NULL REFERENCES remote_play.sessions(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  command text NOT NULL CHECK (command IN ('start_stream','stop_stream')),
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  idempotency_key text NOT NULL UNIQUE,
  status text NOT NULL DEFAULT 'queued' CHECK (status IN ('queued','delivered','completed','failed')),
  created_at timestamptz NOT NULL DEFAULT now(),
  delivered_at timestamptz,
  acknowledged_at timestamptz,
  result jsonb NOT NULL DEFAULT '{}'::jsonb
);
CREATE INDEX IF NOT EXISTS remote_play_commands_host_queue_idx
  ON remote_play.commands(device_id, status, created_at);

CREATE TABLE IF NOT EXISTS remote_play.audit_events (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  actor_family text NOT NULL CHECK (actor_family IN ('admin','client','host','system')),
  actor_id text,
  event_name text NOT NULL,
  target_id text,
  payload jsonb NOT NULL DEFAULT '{}'::jsonb,
  created_at timestamptz NOT NULL DEFAULT now()
);
CREATE INDEX IF NOT EXISTS remote_play_audit_org_recent_idx
  ON remote_play.audit_events(org_id, created_at DESC);

ALTER TABLE remote_play.client_credentials ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.rental_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.client_sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.host_permissions ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.host_enrollments ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.host_registrations ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.sessions ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.commands ENABLE ROW LEVEL SECURITY;
ALTER TABLE remote_play.audit_events ENABLE ROW LEVEL SECURITY;

REVOKE ALL ON ALL TABLES IN SCHEMA remote_play FROM PUBLIC;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA remote_play FROM PUBLIC;
REVOKE ALL ON ALL TABLES IN SCHEMA remote_play FROM ani_api_runtime;
REVOKE ALL ON ALL SEQUENCES IN SCHEMA remote_play FROM ani_api_runtime;

-- Every privileged API function uses a token family specific to its caller.
CREATE OR REPLACE FUNCTION private.remote_play_require_admin(p_session_token text)
RETURNS public.admin_accounts
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
BEGIN
  a := private.admin_account_by_token(p_session_token);
  IF a.role <> 'SUPER_ADMIN'
     OR NOT EXISTS (
       SELECT 1 FROM public.org_members m
       WHERE m.auth_user_id = a.auth_user_id
         AND m.org_id = a.org_id
         AND m.role = 'owner'
     ) THEN
    RAISE EXCEPTION 'OWNER_ONLY';
  END IF;
  RETURN a;
END;
$function$;

CREATE OR REPLACE FUNCTION private.remote_play_get_client(p_session_token text)
RETURNS remote_play.client_sessions
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','extensions','pg_catalog'
AS $function$
DECLARE
  s remote_play.client_sessions%ROWTYPE;
BEGIN
  IF NULLIF(BTRIM(p_session_token),'') IS NULL THEN RAISE EXCEPTION 'REMOTE_PLAY_AUTH_REQUIRED'; END IF;
  SELECT * INTO s
  FROM remote_play.client_sessions
  WHERE token_hash = encode(extensions.digest(p_session_token,'sha256'),'hex')
    AND revoked_at IS NULL
    AND expires_at > now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_SESSION_EXPIRED'; END IF;
  UPDATE remote_play.client_sessions SET last_seen_at=now() WHERE id=s.id;
  RETURN s;
END;
$function$;

CREATE OR REPLACE FUNCTION private.remote_play_get_host(p_host_token text)
RETURNS remote_play.host_registrations
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','extensions','pg_catalog'
AS $function$
DECLARE
  h remote_play.host_registrations%ROWTYPE;
BEGIN
  IF NULLIF(BTRIM(p_host_token),'') IS NULL THEN RAISE EXCEPTION 'REMOTE_PLAY_HOST_AUTH_REQUIRED'; END IF;
  SELECT * INTO h
  FROM remote_play.host_registrations
  WHERE token_hash=encode(extensions.digest(p_host_token,'sha256'),'hex')
    AND revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_HOST_REVOKED'; END IF;
  RETURN h;
END;
$function$;

CREATE OR REPLACE FUNCTION private.remote_play_settle_session(
  p_session_id uuid,
  p_reason text,
  p_queue_stop boolean DEFAULT true
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','pg_catalog'
AS $function$
DECLARE
  s remote_play.sessions%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  used_seconds bigint;
  deducted_seconds bigint;
  balance_after bigint;
  final_status text;
BEGIN
  SELECT * INTO s FROM remote_play.sessions WHERE id=p_session_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_SESSION_NOT_FOUND'; END IF;
  IF s.settled_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'session_id',s.id,
      'status',s.status,'settled_seconds',s.settled_seconds,'cooldown_until',s.cooldown_until);
  END IF;

  IF p_queue_stop THEN
    INSERT INTO remote_play.commands(session_id,device_id,command,payload,idempotency_key,status)
    VALUES(s.id,s.device_id,'stop_stream',jsonb_build_object('reason',left(coalesce(p_reason,'session_ended'),80)),
      'stop:'||s.id::text,'queued')
    ON CONFLICT(idempotency_key) DO NOTHING;
  END IF;

  SELECT * INTO r FROM public.rental_accounts WHERE id=s.rental_account_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;

  used_seconds := least(
    10800::bigint,
    greatest(0,ceil(extract(epoch FROM (least(now(),s.deadline_at)-s.started_at)))::bigint)
  );
  deducted_seconds := least(greatest(0,r.remaining_seconds),used_seconds);
  balance_after := greatest(0,r.remaining_seconds-deducted_seconds);
  final_status := CASE
    WHEN p_reason='admin_revoked' THEN 'revoked'
    WHEN balance_after=0 OR (r.expiry_at IS NOT NULL AND r.expiry_at<=now()) THEN 'expired'
    ELSE 'ended'
  END;

  UPDATE public.rental_accounts
  SET remaining_seconds=balance_after,
      status=CASE WHEN final_status='expired' THEN 'expired' ELSE status END,
      updated_at=now()
  WHERE id=r.id;

  UPDATE remote_play.sessions
  SET status=final_status,
      ended_at=coalesce(ended_at,now()),
      settled_seconds=deducted_seconds,
      settled_at=now(),
      cooldown_until=now()+interval '10 minutes',
      end_reason=left(coalesce(p_reason,'session_ended'),80)
  WHERE id=s.id;

  INSERT INTO public.usage_events(
    org_id,device_id,rental_session_id,rental_account_id,event_type,data_class,
    occurred_at,duration_seconds,category,client_label,payload
  )
  VALUES(
    s.org_id,s.device_id,NULL,s.rental_account_id,'remote_play_session','usage',
    s.started_at,deducted_seconds,coalesce(r.category,'remote_play'),r.client_label,
    jsonb_build_object('remote_play_session_id',s.id,'end_reason',left(coalesce(p_reason,'session_ended'),80),
      'started_at',s.started_at,'ended_at',now(),'hard_cap_seconds',10800)
  );

  INSERT INTO public.audit_logs(org_id,actor_user_id,actor_device_id,action,target_type,target_id,payload)
  VALUES(s.org_id,NULL,s.device_id,'remote_play_session_settled','remote_play_session',s.id::text,
    jsonb_build_object('rental_account_id',s.rental_account_id,'device_id',s.device_id,
      'settled_seconds',deducted_seconds,'remaining_seconds',balance_after,'reason',left(coalesce(p_reason,'session_ended'),80)));

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(s.org_id,'system',NULL,'session_settled',s.id::text,
    jsonb_build_object('reason',left(coalesce(p_reason,'session_ended'),80),'settled_seconds',deducted_seconds));

  RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',final_status,
    'settled_seconds',deducted_seconds,'remaining_seconds',balance_after,
    'cooldown_until',now()+interval '10 minutes');
END;
$function$;

-- A Billing PC session and a Remote Play session must serialize on the same
-- org:normalized-code advisory lock. This trigger also guards future writes
-- from older PC clients which know nothing about Remote Play.
CREATE OR REPLACE FUNCTION private.reject_pc_session_during_remote_play()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','pg_catalog'
AS $function$
DECLARE
  normalized_code text := upper(trim(coalesce(NEW.code,'')));
BEGIN
  IF NEW.status IN ('active','paused') AND normalized_code<>'' AND normalized_code<>'__TEST10__' THEN
    PERFORM pg_advisory_xact_lock(hashtextextended(NEW.org_id::text||':'||normalized_code,0));
    IF EXISTS(
      SELECT 1 FROM remote_play.sessions s
      JOIN public.rental_accounts r ON r.id=s.rental_account_id
      WHERE s.org_id=NEW.org_id
        AND upper(trim(r.code))=normalized_code
        AND s.status IN ('starting','active')
        AND s.settled_at IS NULL
        AND s.deadline_at>now()
    ) THEN
      RAISE EXCEPTION 'RENTAL_ACTIVE_ON_REMOTE_PLAY';
    END IF;
  END IF;
  RETURN NEW;
END;
$function$;

DROP TRIGGER IF EXISTS reject_pc_session_during_remote_play ON public.rental_sessions;
CREATE TRIGGER reject_pc_session_during_remote_play
BEFORE INSERT OR UPDATE OF status,org_id,code,rental_account_id
ON public.rental_sessions
FOR EACH ROW EXECUTE FUNCTION private.reject_pc_session_during_remote_play();

CREATE OR REPLACE FUNCTION api.admin_remote_play_set_host_permission(
  p_session_token text,p_device_id uuid,p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  IF p_device_id IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'REMOTE_PLAY_INVALID_PERMISSION'; END IF;
  SELECT * INTO d FROM public.devices WHERE id=p_device_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;

  INSERT INTO remote_play.host_permissions(device_id,org_id,enabled,approved_by,approved_at,updated_at)
  VALUES(d.id,d.org_id,p_enabled,a.auth_user_id,CASE WHEN p_enabled THEN now() ELSE NULL END,now())
  ON CONFLICT(device_id) DO UPDATE SET enabled=EXCLUDED.enabled,approved_by=a.auth_user_id,
    approved_at=CASE WHEN EXCLUDED.enabled THEN now() ELSE remote_play.host_permissions.approved_at END,updated_at=now();

  IF NOT p_enabled THEN
    UPDATE remote_play.commands SET status='failed',acknowledged_at=now(),
      result=jsonb_build_object('reason','HOST_PERMISSION_REVOKED')
    WHERE device_id=d.id AND command='start_stream' AND status IN ('queued','delivered');
    FOR s IN SELECT * FROM remote_play.sessions
      WHERE device_id=d.id AND status IN ('starting','active') AND settled_at IS NULL
      FOR UPDATE
    LOOP
      PERFORM private.remote_play_settle_session(s.id,'host_permission_revoked',true);
    END LOOP;
  END IF;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'host_permission_changed',d.id::text,jsonb_build_object('enabled',p_enabled));
  RETURN jsonb_build_object('ok',true,'device_id',d.id,'enabled',p_enabled);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_play_set_rental_permission(
  p_session_token text,p_rental_account_id uuid,p_enabled boolean
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  IF p_rental_account_id IS NULL OR p_enabled IS NULL THEN RAISE EXCEPTION 'REMOTE_PLAY_INVALID_PERMISSION'; END IF;
  SELECT * INTO r FROM public.rental_accounts WHERE id=p_rental_account_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;

  INSERT INTO remote_play.rental_permissions(rental_account_id,org_id,enabled,approved_by,approved_at,updated_at)
  VALUES(r.id,r.org_id,p_enabled,a.auth_user_id,CASE WHEN p_enabled THEN now() ELSE NULL END,now())
  ON CONFLICT(rental_account_id) DO UPDATE SET enabled=EXCLUDED.enabled,approved_by=a.auth_user_id,
    approved_at=CASE WHEN EXCLUDED.enabled THEN now() ELSE remote_play.rental_permissions.approved_at END,updated_at=now();

  IF NOT p_enabled THEN
    UPDATE remote_play.client_sessions SET revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
    FOR s IN SELECT * FROM remote_play.sessions
      WHERE rental_account_id=r.id AND status IN ('starting','active') AND settled_at IS NULL
      FOR UPDATE
    LOOP
      PERFORM private.remote_play_settle_session(s.id,'admin_revoked',true);
    END LOOP;
  END IF;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'rental_permission_changed',r.id::text,jsonb_build_object('enabled',p_enabled));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'enabled',p_enabled);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_play_issue_client_credential(
  p_session_token text,p_rental_account_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  activation_code text := encode(extensions.gen_random_bytes(8),'hex');
  s remote_play.sessions%ROWTYPE;
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO r FROM public.rental_accounts WHERE id=p_rental_account_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.rental_permissions WHERE rental_account_id=r.id AND enabled) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_RENTAL_PERMISSION_REQUIRED';
  END IF;

  UPDATE remote_play.client_credentials SET revoked_at=coalesce(revoked_at,now()),enabled=false
  WHERE rental_account_id=r.id AND revoked_at IS NULL;
  UPDATE remote_play.client_sessions SET revoked_at=coalesce(revoked_at,now())
  WHERE rental_account_id=r.id AND revoked_at IS NULL;
  FOR s IN SELECT * FROM remote_play.sessions
    WHERE rental_account_id=r.id AND status IN ('starting','active') AND settled_at IS NULL
    FOR UPDATE
  LOOP
    PERFORM private.remote_play_settle_session(s.id,'activation_rotated',true);
  END LOOP;

  INSERT INTO remote_play.client_credentials(rental_account_id,secret_hash,enabled,created_by)
  VALUES(r.id,extensions.crypt(activation_code,extensions.gen_salt('bf')),true,a.auth_user_id);

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(a.org_id,'admin',a.auth_user_id::text,'client_activation_issued',r.id::text,
    jsonb_build_object('rental_code',r.code,'activation_rotated',true));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'activation_code',activation_code,
    'note','Tampilkan sekali kepada penyewa; jangan simpan PIN mentah di aplikasi Admin.');
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_play_issue_host_enrollment(
  p_session_token text,p_device_id uuid,p_valid_minutes integer DEFAULT 15
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  enrollment_code text := encode(extensions.gen_random_bytes(16),'hex');
  valid_minutes integer := greatest(1,least(60,coalesce(p_valid_minutes,15)));
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT * INTO d FROM public.devices WHERE id=p_device_id AND org_id=a.org_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'DEVICE_NOT_FOUND'; END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.host_permissions WHERE device_id=d.id AND enabled) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_PERMISSION_REQUIRED';
  END IF;

  UPDATE remote_play.host_enrollments SET consumed_at=coalesce(consumed_at,now())
  WHERE device_id=d.id AND consumed_at IS NULL;
  INSERT INTO remote_play.host_enrollments(device_id,org_id,code_hash,expires_at,created_by)
  VALUES(d.id,d.org_id,encode(extensions.digest(enrollment_code,'sha256'),'hex'),
    now()+make_interval(mins=>valid_minutes),a.auth_user_id);

  RETURN jsonb_build_object('ok',true,'device_id',d.id,'enrollment_code',enrollment_code,
    'expires_at',now()+make_interval(mins=>valid_minutes));
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_host_enroll(p_enrollment_code text,p_agent_version text DEFAULT NULL)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','extensions','pg_catalog'
AS $function$
DECLARE
  e remote_play.host_enrollments%ROWTYPE;
  d public.devices%ROWTYPE;
  raw_token text := encode(extensions.gen_random_bytes(32),'hex');
BEGIN
  IF length(coalesce(p_enrollment_code,''))<24 OR length(p_enrollment_code)>128 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ENROLLMENT_INVALID';
  END IF;
  SELECT * INTO e FROM remote_play.host_enrollments
  WHERE code_hash=encode(extensions.digest(p_enrollment_code,'sha256'),'hex')
    AND consumed_at IS NULL AND expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_ENROLLMENT_INVALID'; END IF;
  SELECT * INTO d FROM public.devices WHERE id=e.device_id AND org_id=e.org_id;
  IF NOT FOUND OR NOT EXISTS(SELECT 1 FROM remote_play.host_permissions WHERE device_id=e.device_id AND enabled) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_PERMISSION_REQUIRED';
  END IF;

  INSERT INTO remote_play.host_registrations(device_id,org_id,token_hash,agent_version,sunshine_ready,last_heartbeat_at)
  VALUES(d.id,d.org_id,encode(extensions.digest(raw_token,'sha256'),'hex'),left(coalesce(p_agent_version,''),80),false,now())
  ON CONFLICT(device_id) DO UPDATE SET org_id=EXCLUDED.org_id,token_hash=EXCLUDED.token_hash,
    agent_version=EXCLUDED.agent_version,sunshine_ready=false,last_heartbeat_at=now(),
    updated_at=now(),revoked_at=NULL;
  UPDATE remote_play.host_enrollments SET consumed_at=now() WHERE id=e.id;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(e.org_id,'host',d.id::text,'host_enrolled',d.id::text,jsonb_build_object('agent_version',left(coalesce(p_agent_version,''),80)));
  RETURN jsonb_build_object('ok',true,'host_token',raw_token,'device_id',d.id,
    'host_name',d.device_name,'note','Token hanya ditampilkan sekali dan wajib disimpan dengan Windows DPAPI.');
END;
$function$;

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
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_MEDIA_ADDRESS_MUST_BE_PRIVATE_OVERLAY';
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

CREATE OR REPLACE FUNCTION api.remote_play_host_next_command(p_host_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  h remote_play.host_registrations%ROWTYPE;
  c remote_play.commands%ROWTYPE;
  permission_enabled boolean;
BEGIN
  h:=private.remote_play_get_host(p_host_token);
  SELECT enabled INTO permission_enabled FROM remote_play.host_permissions WHERE device_id=h.device_id;
  SELECT * INTO c FROM remote_play.commands
  WHERE device_id=h.device_id AND status='queued'
    AND (command='stop_stream' OR coalesce(permission_enabled,false))
  ORDER BY created_at
  LIMIT 1 FOR UPDATE SKIP LOCKED;
  IF NOT FOUND THEN RETURN jsonb_build_object('ok',true,'command',NULL); END IF;

  UPDATE remote_play.commands SET status='delivered',delivered_at=now() WHERE id=c.id;
  RETURN jsonb_build_object('ok',true,'command',jsonb_build_object(
    'id',c.id,'session_id',c.session_id,'command',c.command,'payload',c.payload,
    'created_at',c.created_at
  ));
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_host_ack(
  p_host_token text,p_command_id uuid,p_status text,p_result jsonb DEFAULT '{}'::jsonb
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  h remote_play.host_registrations%ROWTYPE;
  c remote_play.commands%ROWTYPE;
BEGIN
  h:=private.remote_play_get_host(p_host_token);
  IF p_status NOT IN ('completed','failed') THEN RAISE EXCEPTION 'REMOTE_PLAY_COMMAND_STATUS_INVALID'; END IF;
  IF pg_column_size(coalesce(p_result,'{}'::jsonb))>16384 THEN RAISE EXCEPTION 'REMOTE_PLAY_RESULT_TOO_LARGE'; END IF;
  SELECT * INTO c FROM remote_play.commands
  WHERE id=p_command_id AND device_id=h.device_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_COMMAND_NOT_FOUND'; END IF;
  IF c.status IN ('completed','failed') THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'command_id',c.id,'status',c.status);
  END IF;

  UPDATE remote_play.commands SET status=p_status,acknowledged_at=now(),result=coalesce(p_result,'{}'::jsonb)
  WHERE id=c.id;

  IF c.command='start_stream' AND p_status='completed' THEN
    UPDATE remote_play.sessions SET status='active',host_started_at=coalesce(host_started_at,now())
    WHERE id=c.session_id AND status='starting' AND settled_at IS NULL AND deadline_at>now();
  ELSIF c.command='start_stream' AND p_status='failed' THEN
    PERFORM private.remote_play_settle_session(c.session_id,'host_start_failed',true);
  ELSIF c.command='stop_stream' AND p_status='completed' THEN
    PERFORM private.remote_play_settle_session(c.session_id,'host_stop_acknowledged',false);
  END IF;

  RETURN jsonb_build_object('ok',true,'command_id',c.id,'status',p_status);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_login(
  p_rental_code text,p_activation_code text,p_client_install_id text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','extensions','pg_catalog'
AS $function$
DECLARE
  r public.rental_accounts%ROWTYPE;
  credential remote_play.client_credentials%ROWTYPE;
  raw_token text := encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh text := encode(extensions.gen_random_bytes(32),'hex');
  v_session_id uuid;
BEGIN
  IF length(coalesce(p_rental_code,''))<1 OR length(p_rental_code)>120
     OR length(coalesce(p_activation_code,''))<8 OR length(p_activation_code)>128
     OR length(coalesce(p_client_install_id,''))<8 OR length(p_client_install_id)>128 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_INVALID_CREDENTIALS';
  END IF;

  SELECT count(*) INTO matched_accounts FROM public.rental_accounts
  WHERE upper(trim(code))=upper(trim(p_rental_code));
  IF matched_accounts<>1 THEN RAISE EXCEPTION 'REMOTE_PLAY_INVALID_CREDENTIALS'; END IF;
  SELECT * INTO r FROM public.rental_accounts
  WHERE upper(trim(code))=upper(trim(p_rental_code))
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_INVALID_CREDENTIALS'; END IF;

  SELECT * INTO credential FROM remote_play.client_credentials
  WHERE rental_account_id=r.id AND enabled AND revoked_at IS NULL
  FOR UPDATE;
  IF NOT FOUND OR extensions.crypt(p_activation_code,credential.secret_hash)<>credential.secret_hash THEN
    RAISE EXCEPTION 'REMOTE_PLAY_INVALID_CREDENTIALS';
  END IF;
  IF r.status IN ('disabled','deleted','inactive') THEN
    RAISE EXCEPTION 'REMOTE_PLAY_ACCOUNT_DISABLED';
  END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.rental_permissions WHERE rental_account_id=r.id AND enabled) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_DISABLED';
  END IF;

  INSERT INTO remote_play.client_sessions(
    rental_account_id,token_hash,refresh_token_hash,client_install_id,expires_at,refresh_expires_at
  )
  VALUES(r.id,encode(extensions.digest(raw_token,'sha256'),'hex'),
    encode(extensions.digest(raw_refresh,'sha256'),'hex'),left(p_client_install_id,128),
    now()+interval '12 hours',now()+interval '30 days')
  RETURNING id INTO v_session_id;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(r.org_id,'client',v_session_id::text,'client_login',r.id::text,
    jsonb_build_object('client_install_id',left(p_client_install_id,128)));
  RETURN jsonb_build_object('ok',true,'access_token',raw_token,'refresh_token',raw_refresh,
    'token_type','bearer','expires_at',now()+interval '12 hours',
    'refresh_expires_at',now()+interval '30 days','client_session_id',v_session_id);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_refresh(p_refresh_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','extensions','pg_catalog'
AS $function$
DECLARE
  s remote_play.client_sessions%ROWTYPE;
  raw_token text := encode(extensions.gen_random_bytes(32),'hex');
  raw_refresh text := encode(extensions.gen_random_bytes(32),'hex');
BEGIN
  IF NULLIF(BTRIM(p_refresh_token),'') IS NULL THEN RAISE EXCEPTION 'REMOTE_PLAY_REFRESH_EXPIRED'; END IF;
  SELECT * INTO s FROM remote_play.client_sessions
  WHERE refresh_token_hash=encode(extensions.digest(p_refresh_token,'sha256'),'hex')
    AND revoked_at IS NULL AND refresh_expires_at>now()
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_REFRESH_EXPIRED'; END IF;
  UPDATE remote_play.client_sessions SET
    token_hash=encode(extensions.digest(raw_token,'sha256'),'hex'),
    refresh_token_hash=encode(extensions.digest(raw_refresh,'sha256'),'hex'),
    expires_at=now()+interval '12 hours',
    refresh_expires_at=now()+interval '30 days',
    last_seen_at=now()
  WHERE id=s.id;
  RETURN jsonb_build_object('ok',true,'access_token',raw_token,'refresh_token',raw_refresh,
    'token_type','bearer','expires_at',now()+interval '12 hours',
    'refresh_expires_at',now()+interval '30 days');
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_logout(p_session_token text)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','extensions','pg_catalog'
AS $function$
DECLARE
  n integer;
BEGIN
  UPDATE remote_play.client_sessions SET revoked_at=coalesce(revoked_at,now())
  WHERE token_hash=encode(extensions.digest(p_session_token,'sha256'),'hex') AND revoked_at IS NULL;
  GET DIAGNOSTICS n=ROW_COUNT;
  RETURN jsonb_build_object('ok',true,'revoked',n>0);
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

CREATE OR REPLACE FUNCTION api.remote_play_request_session(
  p_session_token text,p_device_id uuid,p_idempotency_key text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  d public.devices%ROWTYPE;
  h remote_play.host_registrations%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
  previous_cooldown timestamptz;
  matched_accounts integer;
  deadline timestamptz;
  command_id uuid;
  media_address text;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  IF p_device_id IS NULL OR length(coalesce(p_idempotency_key,''))<8 OR length(p_idempotency_key)>128 THEN
    RAISE EXCEPTION 'REMOTE_PLAY_REQUEST_INVALID';
  END IF;

  SELECT * INTO r FROM public.rental_accounts WHERE id=c.rental_account_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  PERFORM pg_advisory_xact_lock(hashtextextended(r.org_id::text||':'||upper(trim(r.code)),0));

  SELECT * INTO s FROM remote_play.sessions
  WHERE client_session_id=c.id AND idempotency_key=p_idempotency_key
  LIMIT 1;
  IF FOUND AND s.status IN ('starting','active') AND s.settled_at IS NULL THEN
    SELECT host(media_address) INTO media_address FROM remote_play.host_registrations WHERE device_id=s.device_id;
    RETURN jsonb_build_object('ok',true,'idempotent',true,'session_id',s.id,'status',s.status,
      'deadline_at',s.deadline_at,'media_address',media_address);
  END IF;

  -- Settle a stale, over-deadline session before checking the unique active-session indexes.
  SELECT * INTO s FROM remote_play.sessions
  WHERE rental_account_id=r.id AND status IN ('starting','active') AND settled_at IS NULL
  ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND s.deadline_at<=now() THEN
    PERFORM private.remote_play_settle_session(s.id,'deadline_expired',true);
  ELSIF FOUND THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SESSION_ACTIVE';
  END IF;

  IF r.status<>'active' THEN RAISE EXCEPTION 'REMOTE_PLAY_ACCOUNT_INACTIVE'; END IF;
  IF r.expiry_at IS NOT NULL AND r.expiry_at<=now() THEN RAISE EXCEPTION 'REMOTE_PLAY_ACCOUNT_EXPIRED'; END IF;
  IF r.remaining_seconds<=0 THEN RAISE EXCEPTION 'REMOTE_PLAY_BALANCE_EMPTY'; END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.rental_permissions WHERE rental_account_id=r.id AND enabled) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_DISABLED';
  END IF;
  IF EXISTS(
    SELECT 1 FROM public.rental_sessions ps
    WHERE ps.org_id=r.org_id AND ps.status IN ('active','paused')
      AND (ps.rental_account_id=r.id OR upper(trim(ps.code))=upper(trim(r.code)))
  ) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_BILLING_SESSION_ACTIVE';
  END IF;

  SELECT max(cooldown_until) INTO previous_cooldown FROM remote_play.sessions
  WHERE rental_account_id=r.id AND cooldown_until IS NOT NULL;
  IF previous_cooldown IS NOT NULL AND previous_cooldown>now() THEN
    RAISE EXCEPTION 'REMOTE_PLAY_COOLDOWN_ACTIVE';
  END IF;

  SELECT * INTO d FROM public.devices WHERE id=p_device_id AND org_id=r.org_id;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_HOST_NOT_FOUND'; END IF;
  IF NOT EXISTS(SELECT 1 FROM remote_play.host_permissions WHERE device_id=d.id AND org_id=d.org_id AND enabled) THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_DISABLED';
  END IF;
  SELECT * INTO h FROM remote_play.host_registrations
  WHERE device_id=d.id AND org_id=d.org_id AND revoked_at IS NULL
    AND last_heartbeat_at>now()-interval '60 seconds'
    AND sunshine_ready AND media_address IS NOT NULL;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_HOST_OFFLINE_OR_MEDIA_UNAVAILABLE'; END IF;

  -- Expire a stale session on this PC before starting a new rental.
  SELECT * INTO s FROM remote_play.sessions
  WHERE device_id=d.id AND status IN ('starting','active') AND settled_at IS NULL
  ORDER BY started_at DESC LIMIT 1 FOR UPDATE;
  IF FOUND AND s.deadline_at<=now() THEN
    PERFORM private.remote_play_settle_session(s.id,'deadline_expired',true);
  ELSIF FOUND THEN
    RAISE EXCEPTION 'REMOTE_PLAY_HOST_BUSY';
  END IF;

  deadline:=least(now()+interval '3 hours',
    now()+make_interval(secs=>r.remaining_seconds),
    coalesce(r.expiry_at,now()+interval '3 hours'));

  INSERT INTO remote_play.sessions(
    org_id,rental_account_id,device_id,client_session_id,status,started_at,deadline_at,
    last_client_heartbeat_at,starting_balance_seconds,idempotency_key
  )
  VALUES(r.org_id,r.id,d.id,c.id,'starting',now(),deadline,now(),r.remaining_seconds,p_idempotency_key)
  RETURNING * INTO s;

  INSERT INTO remote_play.commands(session_id,device_id,command,payload,idempotency_key,status)
  VALUES(s.id,d.id,'start_stream',jsonb_build_object('session_id',s.id,'deadline_at',deadline,
      'max_duration_seconds',10800,'media_address',host(h.media_address),'client_install_id',c.client_install_id),
    'start:'||s.id::text,'queued')
  RETURNING id INTO command_id;

  media_address:=host(h.media_address);
  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(r.org_id,'client',c.id::text,'session_requested',s.id::text,
    jsonb_build_object('device_id',d.id,'deadline_at',deadline));

  RETURN jsonb_build_object('ok',true,'session_id',s.id,'command_id',command_id,
    'status','starting','deadline_at',deadline,'media_address',media_address,
    'max_duration_seconds',10800);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_session_heartbeat(p_session_token text,p_session_id uuid)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  SELECT * INTO s FROM remote_play.sessions
  WHERE id=p_session_id AND rental_account_id=c.rental_account_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_SESSION_NOT_FOUND'; END IF;
  IF s.settled_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok',false,'status',s.status,'settled',true,'cooldown_until',s.cooldown_until);
  END IF;
  IF s.deadline_at<=now() THEN
    RETURN private.remote_play_settle_session(s.id,'deadline_expired',true);
  END IF;
  UPDATE remote_play.sessions SET last_client_heartbeat_at=now()
  WHERE id=s.id;
  RETURN jsonb_build_object('ok',true,'status',s.status,'session_id',s.id,
    'deadline_at',s.deadline_at,
    'remaining_seconds',greatest(0,ceil(extract(epoch FROM (s.deadline_at-now())))::bigint));
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_end_session(
  p_session_token text,p_session_id uuid,p_reason text DEFAULT 'client_stopped'
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  SELECT * INTO s FROM remote_play.sessions
  WHERE id=p_session_id AND rental_account_id=c.rental_account_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_SESSION_NOT_FOUND'; END IF;
  RETURN private.remote_play_settle_session(s.id,left(coalesce(p_reason,'client_stopped'),80),true);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_play_sessions(p_session_token text,p_limit integer DEFAULT 100)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  result_rows jsonb;
BEGIN
  a:=private.remote_play_require_admin(p_session_token);
  SELECT coalesce(jsonb_agg(x ORDER BY (x->>'started_at') DESC),'[]'::jsonb) INTO result_rows
  FROM (
    SELECT jsonb_build_object('id',s.id,'rental_account_id',s.rental_account_id,'rental_code',r.code,
      'device_id',s.device_id,'device_name',d.device_name,'status',s.status,'started_at',s.started_at,
      'deadline_at',s.deadline_at,'ended_at',s.ended_at,'settled_seconds',s.settled_seconds,
      'cooldown_until',s.cooldown_until,'end_reason',s.end_reason) AS x
    FROM remote_play.sessions s
    JOIN public.rental_accounts r ON r.id=s.rental_account_id
    JOIN public.devices d ON d.id=s.device_id
    WHERE s.org_id=a.org_id
    ORDER BY s.started_at DESC
    LIMIT greatest(1,least(300,coalesce(p_limit,100)))
  ) q;
  RETURN jsonb_build_object('ok',true,'sessions',result_rows);
END;
$function$;

-- Grant only API entry points. Helper functions and schema tables stay private.
REVOKE ALL ON ALL FUNCTIONS IN SCHEMA remote_play FROM PUBLIC;
REVOKE ALL ON FUNCTION private.remote_play_require_admin(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.remote_play_get_client(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.remote_play_get_host(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.remote_play_settle_session(uuid,text,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION private.reject_pc_session_during_remote_play() FROM PUBLIC;

REVOKE ALL ON FUNCTION api.admin_remote_play_set_host_permission(text,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_play_set_rental_permission(text,uuid,boolean) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_play_issue_client_credential(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_play_issue_host_enrollment(text,uuid,integer) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_host_enroll(text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_host_heartbeat(text,boolean,inet,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_host_next_command(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_host_ack(text,uuid,text,jsonb) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_login(text,text,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_refresh(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_logout(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_dashboard(text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_request_session(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_session_heartbeat(text,uuid) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.remote_play_end_session(text,uuid,text) FROM PUBLIC;
REVOKE ALL ON FUNCTION api.admin_remote_play_sessions(text,integer) FROM PUBLIC;

GRANT EXECUTE ON FUNCTION api.admin_remote_play_set_host_permission(text,uuid,boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_play_set_rental_permission(text,uuid,boolean) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_play_issue_client_credential(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_play_issue_host_enrollment(text,uuid,integer) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_host_enroll(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_host_heartbeat(text,boolean,inet,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_host_next_command(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_host_ack(text,uuid,text,jsonb) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_login(text,text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_refresh(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_logout(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_dashboard(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_request_session(text,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_session_heartbeat(text,uuid) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.remote_play_end_session(text,uuid,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_remote_play_sessions(text,integer) TO ani_api_runtime;

COMMIT;
