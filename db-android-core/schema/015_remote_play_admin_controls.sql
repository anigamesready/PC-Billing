-- Owner-scoped Remote Play control dashboard for the separate Ani Games Admin APK.
-- Additive source migration. CI applies it only to a disposable PostgreSQL database.
BEGIN;

-- Revoking a rental permission permanently revokes its current activation credential.
-- Re-enabling the permission later must not silently restore an old one-time code.
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
  IF p_rental_account_id IS NULL OR p_enabled IS NULL THEN
    RAISE EXCEPTION 'REMOTE_PLAY_INVALID_PERMISSION';
  END IF;
  SELECT * INTO r FROM public.rental_accounts
  WHERE id=p_rental_account_id AND org_id=a.org_id
  FOR UPDATE;
  IF NOT FOUND THEN RAISE EXCEPTION 'RENTAL_NOT_FOUND'; END IF;

  INSERT INTO remote_play.rental_permissions(
    rental_account_id,org_id,enabled,approved_by,approved_at,updated_at
  )
  VALUES(r.id,r.org_id,p_enabled,a.auth_user_id,
    CASE WHEN p_enabled THEN now() ELSE NULL END,now())
  ON CONFLICT(rental_account_id) DO UPDATE SET
    enabled=EXCLUDED.enabled,
    approved_by=a.auth_user_id,
    approved_at=CASE WHEN EXCLUDED.enabled THEN now()
      ELSE remote_play.rental_permissions.approved_at END,
    updated_at=now();

  IF NOT p_enabled THEN
    UPDATE remote_play.client_credentials
    SET enabled=false,revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
    UPDATE remote_play.client_sessions
    SET revoked_at=coalesce(revoked_at,now())
    WHERE rental_account_id=r.id AND revoked_at IS NULL;
    FOR s IN SELECT * FROM remote_play.sessions
      WHERE rental_account_id=r.id
        AND status IN ('starting','active') AND settled_at IS NULL
      FOR UPDATE
    LOOP
      PERFORM private.remote_play_settle_session(s.id,'admin_revoked',true);
    END LOOP;
  END IF;

  INSERT INTO remote_play.audit_events(
    org_id,actor_family,actor_id,event_name,target_id,payload
  )
  VALUES(a.org_id,'admin',a.auth_user_id::text,'rental_permission_changed',
    r.id::text,jsonb_build_object('enabled',p_enabled));
  RETURN jsonb_build_object('ok',true,'rental_account_id',r.id,'enabled',p_enabled);
END;
$function$;

CREATE OR REPLACE FUNCTION api.admin_remote_play_dashboard(
  p_session_token text,
  p_limit integer DEFAULT 200
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public','remote_play','private','pg_catalog'
AS $function$
DECLARE
  a public.admin_accounts%ROWTYPE;
  row_limit integer := greatest(1,least(500,coalesce(p_limit,200)));
  hosts jsonb;
  rentals jsonb;
  session_rows jsonb;
BEGIN
  a := private.remote_play_require_admin(p_session_token);

  SELECT coalesce(jsonb_agg(q.item ORDER BY q.sort_key),'[]'::jsonb)
  INTO hosts
  FROM (
    SELECT d.device_name AS sort_key,
      jsonb_build_object(
        'device_id',d.id,
        'device_name',d.device_name,
        'client_id',d.client_id,
        'device_status',d.status,
        'device_online',coalesce(d.status='online' AND d.last_seen_at>now()-interval '60 seconds',false),
        'permission_enabled',coalesce(hp.enabled,false),
        'agent_enrolled',coalesce(hr.device_id IS NOT NULL AND hr.revoked_at IS NULL,false),
        'sunshine_ready',coalesce(hr.sunshine_ready,false),
        'media_path_ready',hr.media_address IS NOT NULL,
        'media_address',CASE WHEN hr.media_address IS NULL THEN NULL ELSE host(hr.media_address) END,
        'agent_version',hr.agent_version,
        'host_last_seen_at',hr.last_heartbeat_at,
        'permission_updated_at',hp.updated_at,
        'pending_enrollment',EXISTS(
          SELECT 1 FROM remote_play.host_enrollments he
          WHERE he.device_id=d.id AND he.org_id=d.org_id
            AND he.consumed_at IS NULL AND he.expires_at>now()
        ),
        'active_session',(
          SELECT jsonb_build_object(
            'id',s.id,'rental_account_id',s.rental_account_id,
            'status',s.status,'deadline_at',s.deadline_at
          )
          FROM remote_play.sessions s
          WHERE s.device_id=d.id AND s.status IN ('starting','active')
            AND s.settled_at IS NULL
          ORDER BY s.started_at DESC LIMIT 1
        )
      ) AS item
    FROM public.devices d
    LEFT JOIN remote_play.host_permissions hp
      ON hp.device_id=d.id AND hp.org_id=d.org_id
    LEFT JOIN remote_play.host_registrations hr
      ON hr.device_id=d.id AND hr.org_id=d.org_id
    WHERE d.org_id=a.org_id
    ORDER BY d.device_name
    LIMIT row_limit
  ) q;

  SELECT coalesce(jsonb_agg(q.item ORDER BY q.sort_key),'[]'::jsonb)
  INTO rentals
  FROM (
    SELECT r.code AS sort_key,
      jsonb_build_object(
        'rental_account_id',r.id,
        'rental_code',r.code,
        'category',r.category,
        'status',r.status,
        'remaining_seconds',greatest(0,r.remaining_seconds),
        'expiry_at',r.expiry_at,
        'client_label',r.client_label,
        'permission_enabled',coalesce(rp.enabled,false),
        'activation_issued',EXISTS(
          SELECT 1 FROM remote_play.client_credentials cc
          WHERE cc.rental_account_id=r.id AND cc.enabled AND cc.revoked_at IS NULL
        ),
        'client_logged_in',EXISTS(
          SELECT 1 FROM remote_play.client_sessions cs
          WHERE cs.rental_account_id=r.id AND cs.revoked_at IS NULL
            AND cs.expires_at>now()
        ),
        'active_session',(
          SELECT jsonb_build_object(
            'id',s.id,'device_id',s.device_id,'status',s.status,
            'deadline_at',s.deadline_at,'started_at',s.started_at
          )
          FROM remote_play.sessions s
          WHERE s.rental_account_id=r.id AND s.status IN ('starting','active')
            AND s.settled_at IS NULL
          ORDER BY s.started_at DESC LIMIT 1
        )
      ) AS item
    FROM public.rental_accounts r
    LEFT JOIN remote_play.rental_permissions rp
      ON rp.rental_account_id=r.id AND rp.org_id=r.org_id
    WHERE r.org_id=a.org_id
    ORDER BY r.code
    LIMIT row_limit
  ) q;

  SELECT coalesce(jsonb_agg(q.item ORDER BY q.started_at DESC),'[]'::jsonb)
  INTO session_rows
  FROM (
    SELECT s.started_at,
      jsonb_build_object(
        'id',s.id,'rental_account_id',s.rental_account_id,
        'rental_code',r.code,'device_id',s.device_id,
        'device_name',d.device_name,'status',s.status,
        'started_at',s.started_at,'deadline_at',s.deadline_at,
        'ended_at',s.ended_at,'settled_seconds',s.settled_seconds,
        'cooldown_until',s.cooldown_until,'end_reason',s.end_reason
      ) AS item
    FROM remote_play.sessions s
    JOIN public.rental_accounts r ON r.id=s.rental_account_id
    JOIN public.devices d ON d.id=s.device_id
    WHERE s.org_id=a.org_id
    ORDER BY s.started_at DESC
    LIMIT least(300,row_limit)
  ) q;

  RETURN jsonb_build_object(
    'ok',true,
    'server_time',now(),
    'host_devices',hosts,
    'rental_accounts',rentals,
    'sessions',session_rows
  );
END;
$function$;

REVOKE ALL ON FUNCTION api.admin_remote_play_dashboard(text,integer) FROM PUBLIC;
GRANT EXECUTE ON FUNCTION api.admin_remote_play_dashboard(text,integer) TO ani_api_runtime;

COMMIT;
