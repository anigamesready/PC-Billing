-- Applied migration: dual_db_readiness_guard_v1
-- Project: DB1 (wzkjpycjizexxcxrfdvr)
-- This migration is additive and does not copy/delete application data.
-- Reapplying resets the parity fields; only re-run deliberately during environment rebuilds.

ALTER TABLE public.db_route_control
  ADD COLUMN IF NOT EXISTS primary_ready boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS backup_ready boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS sync_ready boolean NOT NULL DEFAULT true,
  ADD COLUMN IF NOT EXISTS schema_version text,
  ADD COLUMN IF NOT EXISTS switch_id uuid,
  ADD COLUMN IF NOT EXISTS primary_schema_version text,
  ADD COLUMN IF NOT EXISTS backup_schema_version text,
  ADD COLUMN IF NOT EXISTS last_schema_check_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_parity_check_at timestamptz,
  ADD COLUMN IF NOT EXISTS last_parity_check_note text;

UPDATE public.db_route_control
SET primary_ready = COALESCE(primary_ready, true),
    backup_ready = COALESCE(backup_ready, false),
    primary_schema_version = COALESCE(primary_schema_version, '20261017_admin_pc_recovery_alerts_v1'),
    backup_schema_version = COALESCE(backup_schema_version, '20261017_admin_pc_recovery_alerts_v1'),
    schema_version = CASE
      WHEN active_target = 'primary' THEN COALESCE(primary_schema_version, '20261017_admin_pc_recovery_alerts_v1')
      WHEN active_target = 'backup' THEN COALESCE(backup_schema_version, '20261017_admin_pc_recovery_alerts_v1')
      ELSE schema_version
    END,
    sync_ready = CASE
      WHEN active_target = 'primary' THEN COALESCE(primary_ready, true)
      WHEN active_target = 'backup' THEN COALESCE(backup_ready, false)
      ELSE false
    END,
    last_schema_check_at = now(),
    last_parity_check_at = NULL,
    last_parity_check_note = 'Schema signature checked; row-level parity still pending'
WHERE id = 1;

CREATE OR REPLACE FUNCTION api.db_route_get()
RETURNS jsonb
LANGUAGE sql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
  SELECT jsonb_build_object(
    'active_target', r.active_target,
    'epoch', r.epoch,
    'updated_at', r.updated_at,
    'updated_by', r.updated_by,
    'reason', r.reason,
    'local_profile', 'primary',
    'project_ref', 'wzkjpycjizexxcxrfdvr',
    'sync_ready', r.sync_ready,
    'schema_version', r.schema_version,
    'switch_id', r.switch_id,
    'primary_ready', r.primary_ready,
    'backup_ready', r.backup_ready,
    'primary_schema_version', r.primary_schema_version,
    'backup_schema_version', r.backup_schema_version,
    'last_schema_check_at', r.last_schema_check_at,
    'last_parity_check_at', r.last_parity_check_at,
    'last_parity_check_note', r.last_parity_check_note
  )
  FROM public.db_route_control r
  WHERE r.id = 1;
$function$;

CREATE OR REPLACE FUNCTION api.db_route_set(
  p_target text,
  p_epoch bigint,
  p_reason text DEFAULT NULL::text
)
RETURNS jsonb
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'public', 'pg_catalog'
AS $function$
DECLARE
  v_epoch bigint;
  v_ready boolean;
  v_version text;
  v_updated timestamptz;
  v_switch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN
    RAISE EXCEPTION 'AUTH_REQUIRED';
  END IF;

  IF p_target IS NULL OR p_target NOT IN ('primary', 'backup') THEN
    RAISE EXCEPTION 'INVALID_DB_TARGET';
  END IF;

  IF p_epoch IS NULL THEN
    RAISE EXCEPTION 'ROUTE_EPOCH_REQUIRED';
  END IF;

  IF NOT EXISTS (
    SELECT 1
    FROM public.org_members m
    JOIN public.organizations o ON o.id = m.org_id
    WHERE m.auth_user_id = auth.uid()
      AND m.role = 'owner'
      AND o.status = 'active'
  ) THEN
    RAISE EXCEPTION 'OWNER_ONLY';
  END IF;

  SELECT
    epoch,
    CASE p_target WHEN 'primary' THEN primary_ready WHEN 'backup' THEN backup_ready ELSE false END,
    CASE p_target WHEN 'primary' THEN primary_schema_version WHEN 'backup' THEN backup_schema_version ELSE NULL END
  INTO v_epoch, v_ready, v_version
  FROM public.db_route_control
  WHERE id = 1
  FOR UPDATE;

  IF NOT FOUND THEN
    RAISE EXCEPTION 'ROUTE_CONTROL_NOT_CONFIGURED';
  END IF;

  IF p_epoch <= COALESCE(v_epoch, 0) THEN
    RAISE EXCEPTION 'ROUTE_EPOCH_NOT_NEWER';
  END IF;

  IF NOT COALESCE(v_ready, false) THEN
    RAISE EXCEPTION USING
      ERRCODE = '55000',
      MESSAGE = CASE p_target
        WHEN 'backup' THEN 'DB_TARGET_NOT_READY: backup is blocked until schema and data parity checks pass'
        ELSE 'DB_TARGET_NOT_READY: primary is not marked ready'
      END;
  END IF;

  v_switch_id := gen_random_uuid();

  UPDATE public.db_route_control
  SET active_target = p_target,
      epoch = p_epoch,
      updated_at = now(),
      updated_by = auth.uid(),
      reason = NULLIF(left(trim(COALESCE(p_reason, '')), 160), ''),
      sync_ready = v_ready,
      schema_version = v_version,
      switch_id = v_switch_id
  WHERE id = 1
  RETURNING updated_at INTO v_updated;

  RETURN jsonb_build_object(
    'ok', true,
    'active_target', p_target,
    'epoch', p_epoch,
    'updated_at', v_updated,
    'local_profile', 'primary',
    'project_ref', 'wzkjpycjizexxcxrfdvr',
    'sync_ready', v_ready,
    'schema_version', v_version,
    'switch_id', v_switch_id
  );
END;
$function$;
