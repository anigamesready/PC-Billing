-- DUAL DB CUTOVER GUARD v2
-- Project profile: backup (xcdbipgsvohesxhxydep)
-- Already applied to this project as migration dual_db_cutover_guard_v2 on 2026-10-18.
-- IMPORTANT: review before re-running; this migration deliberately resets backup readiness to fail-closed values.
-- It does NOT migrate application rows and does NOT implement cross-project request routing.

ALTER TABLE public.db_route_control
  ADD COLUMN IF NOT EXISTS data_parity_ready boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS routing_gateway_ready boolean NOT NULL DEFAULT false,
  ADD COLUMN IF NOT EXISTS last_cutover_test_at timestamptz,
  ADD COLUMN IF NOT EXISTS cutover_test_note text;

UPDATE public.db_route_control
SET backup_ready = false,
    data_parity_ready = false,
    routing_gateway_ready = false,
    last_parity_check_at = NULL,
    last_cutover_test_at = NULL,
    cutover_test_note = NULL,
    last_parity_check_note = 'Row-level audit 2026-10-18: backup data is incomplete/stale; failover blocked'
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
    'local_profile', 'backup',
    'project_ref', 'xcdbipgsvohesxhxydep',
    'sync_ready', r.sync_ready,
    'schema_version', r.schema_version,
    'switch_id', r.switch_id,
    'primary_ready', r.primary_ready,
    'backup_ready', r.backup_ready,
    'data_parity_ready', r.data_parity_ready,
    'routing_gateway_ready', r.routing_gateway_ready,
    'primary_schema_version', r.primary_schema_version,
    'backup_schema_version', r.backup_schema_version,
    'last_schema_check_at', r.last_schema_check_at,
    'last_parity_check_at', r.last_parity_check_at,
    'last_parity_check_note', r.last_parity_check_note,
    'last_cutover_test_at', r.last_cutover_test_at,
    'cutover_test_note', r.cutover_test_note,
    'can_switch_to_backup', (r.backup_ready AND r.data_parity_ready AND r.routing_gateway_ready),
    'can_switch_to_primary', r.primary_ready
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
  v_primary_ready boolean;
  v_backup_ready boolean;
  v_data_parity_ready boolean;
  v_gateway_ready boolean;
  v_ready boolean;
  v_version text;
  v_updated timestamptz;
  v_switch_id uuid;
BEGIN
  IF auth.uid() IS NULL THEN RAISE EXCEPTION 'AUTH_REQUIRED'; END IF;
  IF p_target IS NULL OR p_target NOT IN ('primary', 'backup') THEN RAISE EXCEPTION 'INVALID_DB_TARGET'; END IF;
  IF p_epoch IS NULL THEN RAISE EXCEPTION 'ROUTE_EPOCH_REQUIRED'; END IF;

  IF NOT EXISTS (
    SELECT 1 FROM public.org_members m
    JOIN public.organizations o ON o.id = m.org_id
    WHERE m.auth_user_id = auth.uid() AND m.role = 'owner' AND o.status = 'active'
  ) THEN RAISE EXCEPTION 'OWNER_ONLY'; END IF;

  SELECT epoch, primary_ready, backup_ready, data_parity_ready, routing_gateway_ready,
         CASE p_target WHEN 'primary' THEN primary_schema_version WHEN 'backup' THEN backup_schema_version ELSE NULL END
  INTO v_epoch, v_primary_ready, v_backup_ready, v_data_parity_ready, v_gateway_ready, v_version
  FROM public.db_route_control WHERE id = 1 FOR UPDATE;

  IF NOT FOUND THEN RAISE EXCEPTION 'ROUTE_CONTROL_NOT_CONFIGURED'; END IF;
  IF p_epoch <= COALESCE(v_epoch, 0) THEN RAISE EXCEPTION 'ROUTE_EPOCH_NOT_NEWER'; END IF;

  IF p_target = 'primary' THEN
    v_ready := COALESCE(v_primary_ready, false);
    IF NOT v_ready THEN
      RAISE EXCEPTION USING ERRCODE = '55000', MESSAGE = 'DB_TARGET_NOT_READY: primary is not marked ready';
    END IF;
  ELSE
    v_ready := COALESCE(v_backup_ready, false)
               AND COALESCE(v_data_parity_ready, false)
               AND COALESCE(v_gateway_ready, false);
    IF NOT v_ready THEN
      RAISE EXCEPTION USING
        ERRCODE = '55000',
        MESSAGE = 'DB_TARGET_NOT_READY: backup requires backup_ready, data_parity_ready, and routing_gateway_ready';
    END IF;
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
    'ok', true, 'active_target', p_target, 'epoch', p_epoch, 'updated_at', v_updated,
    'local_profile', 'backup', 'project_ref', 'xcdbipgsvohesxhxydep', 'sync_ready', v_ready,
    'schema_version', v_version, 'switch_id', v_switch_id,
    'data_parity_ready', v_data_parity_ready, 'routing_gateway_ready', v_gateway_ready
  );
END;
$function$;
