-- Bill Remote Play only after Moonlight confirms the first successful GameStream connection.
-- Additive and idempotent; no existing rental/session rows are rewritten.
BEGIN;

ALTER TABLE remote_play.sessions
  ADD COLUMN IF NOT EXISTS stream_started_at timestamptz;

-- A connection attempt that never reaches an actual stream consumes no rental time
-- and does not impose the post-session cooldown.
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
  final_cooldown timestamptz;
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

  used_seconds := CASE WHEN s.stream_started_at IS NULL THEN 0::bigint ELSE least(
    10800::bigint,
    greatest(0,ceil(extract(epoch FROM (least(now(),s.deadline_at)-s.stream_started_at)))::bigint)
  ) END;
  deducted_seconds := least(greatest(0,r.remaining_seconds),used_seconds);
  balance_after := greatest(0,r.remaining_seconds-deducted_seconds);
  final_status := CASE
    WHEN p_reason='admin_revoked' THEN 'revoked'
    WHEN balance_after=0 OR (r.expiry_at IS NOT NULL AND r.expiry_at<=now()) THEN 'expired'
    ELSE 'ended'
  END;
  final_cooldown := CASE WHEN s.stream_started_at IS NULL THEN NULL ELSE now()+interval '10 minutes' END;

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
      cooldown_until=final_cooldown,
      end_reason=left(coalesce(p_reason,'session_ended'),80)
  WHERE id=s.id;

  INSERT INTO public.usage_events(
    org_id,device_id,rental_session_id,rental_account_id,event_type,data_class,
    occurred_at,duration_seconds,category,client_label,payload
  )
  VALUES(
    s.org_id,s.device_id,NULL,s.rental_account_id,'remote_play_session','usage',
    coalesce(s.stream_started_at,s.started_at),deducted_seconds,coalesce(r.category,'remote_play'),r.client_label,
    jsonb_build_object('remote_play_session_id',s.id,'end_reason',left(coalesce(p_reason,'session_ended'),80),
      'started_at',coalesce(s.stream_started_at,s.started_at),'ended_at',now(),
      'hard_cap_seconds',10800,'stream_started',s.stream_started_at IS NOT NULL)
  );

  INSERT INTO public.audit_logs(org_id,actor_user_id,actor_device_id,action,target_type,target_id,payload)
  VALUES(s.org_id,NULL,s.device_id,'remote_play_session_settled','remote_play_session',s.id::text,
    jsonb_build_object('rental_account_id',s.rental_account_id,'device_id',s.device_id,
      'settled_seconds',deducted_seconds,'remaining_seconds',balance_after,'reason',left(coalesce(p_reason,'session_ended'),80)));

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(s.org_id,'system',NULL,'session_settled',s.id::text,
    jsonb_build_object('reason',left(coalesce(p_reason,'session_ended'),80),
      'settled_seconds',deducted_seconds,'stream_started',s.stream_started_at IS NOT NULL));

  RETURN jsonb_build_object('ok',true,'session_id',s.id,'status',final_status,
    'settled_seconds',deducted_seconds,'remaining_seconds',balance_after,
    'cooldown_until',final_cooldown);
END;
$function$;

CREATE OR REPLACE FUNCTION api.remote_play_session_connected(
  p_session_token text,
  p_session_id uuid
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','extensions','pg_catalog'
AS $function$
DECLARE
  c remote_play.client_sessions%ROWTYPE;
  s remote_play.sessions%ROWTYPE;
  r public.rental_accounts%ROWTYPE;
  new_deadline timestamptz;
BEGIN
  c:=private.remote_play_get_client(p_session_token);
  SELECT * INTO s
  FROM remote_play.sessions
  WHERE id=p_session_id
    AND rental_account_id=c.rental_account_id
    AND client_session_id=c.id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'REMOTE_PLAY_SESSION_NOT_FOUND'; END IF;

  IF s.settled_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok',false,'status',s.status,'settled',true,
      'remaining_seconds',0,'cooldown_until',s.cooldown_until);
  END IF;
  IF s.deadline_at<=now() THEN
    RETURN private.remote_play_settle_session(s.id,'connection_deadline_expired',true)
      || jsonb_build_object('ok',false,'settled',true);
  END IF;
  IF s.stream_started_at IS NOT NULL THEN
    RETURN jsonb_build_object('ok',true,'idempotent',true,'status',s.status,
      'session_id',s.id,'stream_started_at',s.stream_started_at,
      'deadline_at',s.deadline_at,
      'remaining_seconds',greatest(0,ceil(extract(epoch FROM (s.deadline_at-now())))::bigint),
      'max_duration_seconds',10800);
  END IF;
  IF s.status<>'active' THEN
    RAISE EXCEPTION 'REMOTE_PLAY_SESSION_NOT_READY';
  END IF;

  SELECT * INTO r FROM public.rental_accounts WHERE id=s.rental_account_id FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;
  IF r.status<>'active' OR r.remaining_seconds<=0 OR
     (r.expiry_at IS NOT NULL AND r.expiry_at<=now()) THEN
    RETURN private.remote_play_settle_session(s.id,'rental_not_available_at_stream_start',true)
      || jsonb_build_object('ok',false,'settled',true,'remaining_seconds',0);
  END IF;

  new_deadline:=least(
    now()+interval '3 hours',
    now()+make_interval(secs=>r.remaining_seconds),
    coalesce(r.expiry_at,now()+interval '3 hours')
  );
  IF new_deadline<=now() THEN
    RETURN private.remote_play_settle_session(s.id,'connection_deadline_expired',true)
      || jsonb_build_object('ok',false,'settled',true,'remaining_seconds',0);
  END IF;

  UPDATE remote_play.sessions
  SET stream_started_at=now(),
      started_at=now(),
      deadline_at=new_deadline,
      status='active'
  WHERE id=s.id;

  INSERT INTO remote_play.audit_events(org_id,actor_family,actor_id,event_name,target_id,payload)
  VALUES(s.org_id,'client',c.id::text,'stream_connected',s.id::text,
    jsonb_build_object('device_id',s.device_id,'deadline_at',new_deadline));

  RETURN jsonb_build_object('ok',true,'status','active','session_id',s.id,
    'stream_started_at',now(),'deadline_at',new_deadline,
    'remaining_seconds',greatest(0,ceil(extract(epoch FROM (new_deadline-now())))::bigint),
    'max_duration_seconds',10800);
END;
$function$;

REVOKE ALL ON FUNCTION api.remote_play_session_connected(text,uuid) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.remote_play_session_connected(text,uuid) TO ani_api_runtime;

COMMIT;
