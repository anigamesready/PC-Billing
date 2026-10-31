-- Persist Admin shutdown intent until the selected PC has no open rental session.
-- A rental-active rejection is a deferral, never an implicit cancellation.
-- PC-side Windows execution remains local; this migration only persists and re-queues
-- the already-authorized schedule command when the backend confirms the session ended.

CREATE TABLE IF NOT EXISTS public.device_shutdown_schedules (
  id uuid PRIMARY KEY DEFAULT gen_random_uuid(),
  org_id uuid NOT NULL REFERENCES public.organizations(id) ON DELETE CASCADE,
  device_id uuid NOT NULL REFERENCES public.devices(id) ON DELETE CASCADE,
  schedule_id text NOT NULL,
  deadline_at timestamptz NOT NULL,
  target_device_name text,
  state text NOT NULL DEFAULT 'pending'
    CHECK (state IN (
      'pending',
      'scheduled',
      'waiting_for_rental_end',
      'cancel_requested',
      'canceled',
      'shutdown_requested',
      'completed',
      'superseded',
      'target_mismatch',
      'error'
    )),
  state_before_cancel text,
  created_by uuid,
  last_command_id uuid,
  last_queued_at timestamptz,
  retry_count integer NOT NULL DEFAULT 0 CHECK (retry_count >= 0),
  last_message text,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now(),
  UNIQUE (device_id, schedule_id)
);

COMMENT ON TABLE public.device_shutdown_schedules IS
  'Durable Admin shutdown intent. Rental-active/paused conditions defer execution; only an authenticated Admin cancel command cancels the timer.';

ALTER TABLE public.device_shutdown_schedules ENABLE ROW LEVEL SECURITY;
REVOKE ALL ON TABLE public.device_shutdown_schedules FROM PUBLIC, anon, authenticated;

CREATE INDEX IF NOT EXISTS device_shutdown_schedules_device_state_idx
  ON public.device_shutdown_schedules(device_id, state, updated_at DESC);

CREATE UNIQUE INDEX IF NOT EXISTS device_shutdown_schedules_one_live_per_device_idx
  ON public.device_shutdown_schedules(device_id)
  WHERE state IN ('pending','scheduled','waiting_for_rental_end','cancel_requested');

CREATE OR REPLACE FUNCTION private.try_queue_deferred_shutdown(p_device_id uuid)
RETURNS void
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
DECLARE
  s public.device_shutdown_schedules%ROWTYPE;
  d public.devices%ROWTYPE;
  next_deadline timestamptz;
  command_payload jsonb;
  new_command_id uuid;
BEGIN
  SELECT * INTO s
  FROM public.device_shutdown_schedules
  WHERE device_id = p_device_id
    AND state = 'waiting_for_rental_end'
  ORDER BY updated_at DESC
  LIMIT 1
  FOR UPDATE;

  IF NOT FOUND THEN RETURN; END IF;

  SELECT * INTO d FROM public.devices WHERE id = p_device_id;
  IF NOT FOUND OR d.status = 'disabled' THEN RETURN; END IF;

  -- Never trust only the server session table: also require the latest PC heartbeat
  -- to report that its local active/paused rental fields are empty.
  IF nullif(btrim(coalesce(d.metadata->>'activeCode','')), '') IS NOT NULL
     OR nullif(btrim(coalesce(d.metadata->>'pausedCode','')), '') IS NOT NULL THEN
    RETURN;
  END IF;

  IF EXISTS (
    SELECT 1 FROM public.rental_sessions rs
    WHERE rs.device_id = p_device_id
      AND rs.status IN ('active','paused')
  ) THEN
    RETURN;
  END IF;

  -- Do not duplicate a command that is already waiting for delivery or acknowledgement.
  IF EXISTS (
    SELECT 1 FROM public.device_commands dc
    WHERE dc.device_id = p_device_id
      AND dc.command = 'schedule_shutdown'
      AND dc.payload->>'scheduleId' = s.schedule_id
      AND dc.status IN ('queued','acknowledged')
  ) THEN
    RETURN;
  END IF;

  -- Small debounce for repeated heartbeats after a failed delivery; first deferred
  -- retry is not delayed because retry_count is still zero.
  IF s.retry_count > 0
     AND s.last_queued_at IS NOT NULL
     AND s.last_queued_at > now() - interval '15 seconds' THEN
    RETURN;
  END IF;

  -- Keep the Admin's original deadline when it is still ahead. If it elapsed while
  -- a rental was active, schedule the local PC action immediately after this handoff.
  next_deadline := greatest(s.deadline_at, now() + interval '8 seconds');

  command_payload := jsonb_build_object(
    'scheduled', true,
    'scheduleId', s.schedule_id,
    'deadlineAt', next_deadline,
    'delayMs', greatest(0, floor(extract(epoch FROM (next_deadline - now())) * 1000))::bigint,
    'targetDeviceId', p_device_id::text,
    'targetDeviceName', coalesce(nullif(s.target_device_name,''), d.device_name, d.client_id, 'PC'),
    'source', 'backend-rental-end-retry'
  );

  BEGIN
    INSERT INTO public.device_commands(
      org_id, device_id, command, payload, status, created_by
    )
    VALUES (
      s.org_id, p_device_id, 'schedule_shutdown', command_payload, 'queued', s.created_by
    )
    RETURNING id INTO new_command_id;

    UPDATE public.device_shutdown_schedules
    SET state = 'pending',
        deadline_at = next_deadline,
        last_command_id = new_command_id,
        last_queued_at = now(),
        retry_count = retry_count + 1,
        last_message = 'Rental selesai; perintah shutdown dijadwalkan ulang ke PC.',
        updated_at = now()
    WHERE id = s.id;
  EXCEPTION WHEN OTHERS THEN
    -- A temporary DB write-quiesce or command-insert error must not roll back
    -- the rental-session completion itself. The next heartbeat/end event may retry.
    UPDATE public.device_shutdown_schedules
    SET last_message = left('Shutdown retry tertunda: ' || SQLERRM, 500),
        updated_at = now()
    WHERE id = s.id;
    RETURN;
  END;
END;
$function$;

CREATE OR REPLACE FUNCTION private.track_device_shutdown_command()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
DECLARE
  sid text;
  deadline timestamptz;
  prior_state text;
BEGIN
  IF TG_OP = 'INSERT' THEN
    IF NEW.command = 'schedule_shutdown' THEN
      sid := nullif(btrim(coalesce(NEW.payload->>'scheduleId','')), '');
      deadline := nullif(NEW.payload->>'deadlineAt','')::timestamptz;
      IF sid IS NULL OR deadline IS NULL
         OR NEW.payload->>'targetDeviceId' IS DISTINCT FROM NEW.device_id::text THEN
        RETURN NEW;
      END IF;

      UPDATE public.device_shutdown_schedules
      SET state = 'superseded',
          last_message = 'Digantikan oleh jadwal shutdown Admin yang lebih baru.',
          updated_at = now()
      WHERE device_id = NEW.device_id
        AND schedule_id <> sid
        AND state IN ('pending','scheduled','waiting_for_rental_end','cancel_requested');

      INSERT INTO public.device_shutdown_schedules(
        org_id, device_id, schedule_id, deadline_at, target_device_name,
        state, created_by, last_command_id, last_queued_at, last_message
      )
      VALUES (
        NEW.org_id, NEW.device_id, sid, deadline,
        nullif(NEW.payload->>'targetDeviceName',''),
        'pending', NEW.created_by, NEW.id, now(),
        'Perintah timer shutdown menunggu konfirmasi PC.'
      )
      ON CONFLICT (device_id, schedule_id) DO UPDATE
      SET org_id = EXCLUDED.org_id,
          deadline_at = EXCLUDED.deadline_at,
          target_device_name = coalesce(EXCLUDED.target_device_name, public.device_shutdown_schedules.target_device_name),
          state = 'pending',
          last_command_id = EXCLUDED.last_command_id,
          last_queued_at = now(),
          last_message = 'Perintah timer shutdown menunggu konfirmasi PC.',
          updated_at = now()
      WHERE public.device_shutdown_schedules.state NOT IN ('cancel_requested','canceled','completed','superseded','target_mismatch');

    ELSIF NEW.command = 'cancel_shutdown_timer' THEN
      sid := nullif(btrim(coalesce(NEW.payload->>'scheduleId','')), '');

      UPDATE public.device_shutdown_schedules
      SET state_before_cancel = state,
          state = 'cancel_requested',
          last_command_id = NEW.id,
          last_message = 'Pembatalan diminta oleh Admin; menunggu konfirmasi PC.',
          updated_at = now()
      WHERE device_id = NEW.device_id
        AND state IN ('pending','scheduled','waiting_for_rental_end','error')
        AND (sid IS NULL OR schedule_id = sid);
    END IF;

    RETURN NEW;
  END IF;

  IF TG_OP = 'UPDATE' AND OLD.status IS DISTINCT FROM NEW.status THEN
    sid := nullif(btrim(coalesce(NEW.payload->>'scheduleId','')), '');

    IF NEW.command = 'schedule_shutdown' AND sid IS NOT NULL THEN
      IF NEW.status = 'completed' AND NEW.result->>'ok' = 'true' THEN
        UPDATE public.device_shutdown_schedules
        SET state = 'scheduled',
            last_message = coalesce(nullif(NEW.result->>'message',''), 'Timer diterima PC dan aktif.'),
            updated_at = now()
        WHERE device_id = NEW.device_id AND schedule_id = sid
          AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');

      ELSIF NEW.status IN ('failed','expired') THEN
        IF coalesce(NEW.result->>'state','') = 'blocked_active_session'
           OR coalesce(NEW.result->>'message','') ILIKE '%sesi rental%'
           OR coalesce(NEW.result->>'message','') ILIKE '%paused%' THEN
          UPDATE public.device_shutdown_schedules
          SET state = 'waiting_for_rental_end',
              last_message = 'Menunggu sesi rental selesai; timer tidak dibatalkan.',
              updated_at = now()
          WHERE device_id = NEW.device_id AND schedule_id = sid
            AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');
        ELSE
          UPDATE public.device_shutdown_schedules
          SET state = 'error',
              last_message = left(coalesce(NEW.result->>'message', NEW.result->>'error', 'PC belum mengonfirmasi timer shutdown.'), 500),
              updated_at = now()
          WHERE device_id = NEW.device_id AND schedule_id = sid
            AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');
        END IF;
      END IF;

    ELSIF NEW.command = 'cancel_shutdown_timer' THEN
      sid := nullif(btrim(coalesce(NEW.payload->>'scheduleId','')), '');

      IF NEW.status = 'completed'
         AND (NEW.result->>'ok' = 'true' OR NEW.result->>'state' = 'canceled') THEN
        UPDATE public.device_shutdown_schedules
        SET state = 'canceled',
            state_before_cancel = NULL,
            last_message = 'Timer shutdown dibatalkan oleh Admin.',
            updated_at = now()
        WHERE device_id = NEW.device_id
          AND state = 'cancel_requested'
          AND (sid IS NULL OR schedule_id = sid);

      ELSIF NEW.status IN ('failed','expired') THEN
        UPDATE public.device_shutdown_schedules
        SET state = coalesce(state_before_cancel, 'scheduled'),
            state_before_cancel = NULL,
            last_message = 'Pembatalan belum dikonfirmasi PC; jadwal tetap dipertahankan.',
            updated_at = now()
        WHERE device_id = NEW.device_id
          AND state = 'cancel_requested'
          AND (sid IS NULL OR schedule_id = sid);
      END IF;
    END IF;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION private.sync_device_shutdown_schedule()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
DECLARE
  sid text;
  timer_state text;
  deadline timestamptz;
  timer_message text;
BEGIN
  sid := nullif(btrim(coalesce(NEW.metadata #>> '{shutdownTimer,scheduleId}','')), '');
  timer_state := coalesce(NEW.metadata #>> '{shutdownTimer,state}','');
  deadline := nullif(NEW.metadata #>> '{shutdownTimer,deadlineAt}','')::timestamptz;
  timer_message := nullif(NEW.metadata #>> '{shutdownTimer,message}','');

  IF sid IS NULL OR timer_state = '' THEN RETURN NEW; END IF;

  IF timer_state = 'scheduled' THEN
    UPDATE public.device_shutdown_schedules
    SET state = 'scheduled',
        deadline_at = coalesce(deadline, deadline_at),
        last_message = coalesce(timer_message, 'Timer shutdown aktif di PC.'),
        updated_at = now()
    WHERE device_id = NEW.id AND schedule_id = sid
      AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');

  ELSIF timer_state = 'blocked_active_session' THEN
    UPDATE public.device_shutdown_schedules
    SET state = 'waiting_for_rental_end',
        deadline_at = coalesce(deadline, deadline_at),
        last_message = coalesce(timer_message, 'Menunggu sesi rental selesai; timer tidak dibatalkan.'),
        updated_at = now()
    WHERE device_id = NEW.id AND schedule_id = sid
      AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');

    PERFORM private.try_queue_deferred_shutdown(NEW.id);

  ELSIF timer_state IN ('shutdown_requested','admin_shutdown_requested') THEN
    UPDATE public.device_shutdown_schedules
    SET state = 'shutdown_requested',
        last_message = coalesce(timer_message, 'Perintah shutdown diteruskan ke Windows.'),
        updated_at = now()
    WHERE device_id = NEW.id AND schedule_id = sid
      AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');

  ELSIF timer_state = 'canceled' THEN
    UPDATE public.device_shutdown_schedules
    SET state = 'canceled',
        state_before_cancel = NULL,
        last_message = coalesce(timer_message, 'Timer shutdown dibatalkan oleh Admin.'),
        updated_at = now()
    WHERE device_id = NEW.id AND schedule_id = sid;

  ELSIF timer_state = 'target_mismatch' THEN
    UPDATE public.device_shutdown_schedules
    SET state = 'target_mismatch',
        last_message = coalesce(timer_message, 'Identitas PC tidak cocok; tidak ada shutdown yang dijalankan.'),
        updated_at = now()
    WHERE device_id = NEW.id AND schedule_id = sid
      AND state NOT IN ('cancel_requested','superseded','canceled','completed','target_mismatch');

  ELSIF timer_state = 'previous_admin_shutdown' THEN
    UPDATE public.device_shutdown_schedules
    SET state = 'completed',
        last_message = coalesce(timer_message, 'PC kembali menyala setelah shutdown terencana.'),
        updated_at = now()
    WHERE device_id = NEW.id AND schedule_id = sid;
  END IF;

  RETURN NEW;
END;
$function$;

CREATE OR REPLACE FUNCTION private.retry_shutdown_after_rental_end()
RETURNS trigger
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path TO 'pg_catalog', 'public', 'private'
AS $function$
BEGIN
  IF OLD.status IN ('active','paused')
     AND NEW.status IN ('ended','expired')
     AND NEW.device_id IS NOT NULL THEN
    PERFORM private.try_queue_deferred_shutdown(NEW.device_id);
  END IF;
  RETURN NEW;
END;
$function$;


-- Preserve shutdown timers that were already accepted by a PC before this migration.
INSERT INTO public.device_shutdown_schedules(
  org_id, device_id, schedule_id, deadline_at, target_device_name, state, last_message
)
SELECT
  d.org_id,
  d.id,
  d.metadata #>> '{shutdownTimer,scheduleId}',
  (d.metadata #>> '{shutdownTimer,deadlineAt}')::timestamptz,
  coalesce(d.device_name, d.client_id, 'PC'),
  CASE d.metadata #>> '{shutdownTimer,state}'
    WHEN 'blocked_active_session' THEN 'waiting_for_rental_end'
    WHEN 'shutdown_requested' THEN 'shutdown_requested'
    WHEN 'admin_shutdown_requested' THEN 'shutdown_requested'
    ELSE 'scheduled'
  END,
  left(coalesce(d.metadata #>> '{shutdownTimer,message}', 'Timer shutdown dipulihkan dari metadata PC.'), 500)
FROM public.devices d
WHERE nullif(btrim(coalesce(d.metadata #>> '{shutdownTimer,scheduleId}','')), '') IS NOT NULL
  AND nullif(btrim(coalesce(d.metadata #>> '{shutdownTimer,deadlineAt}','')), '') IS NOT NULL
  AND d.metadata #>> '{shutdownTimer,state}' IN (
    'scheduled','blocked_active_session','shutdown_requested','admin_shutdown_requested'
  )
ON CONFLICT (device_id, schedule_id) DO NOTHING;

DROP TRIGGER IF EXISTS track_device_shutdown_command_insert ON public.device_commands;
CREATE TRIGGER track_device_shutdown_command_insert
AFTER INSERT ON public.device_commands
FOR EACH ROW EXECUTE FUNCTION private.track_device_shutdown_command();

DROP TRIGGER IF EXISTS track_device_shutdown_command_update ON public.device_commands;
CREATE TRIGGER track_device_shutdown_command_update
AFTER UPDATE OF status ON public.device_commands
FOR EACH ROW EXECUTE FUNCTION private.track_device_shutdown_command();

DROP TRIGGER IF EXISTS sync_device_shutdown_schedule_from_heartbeat ON public.devices;
CREATE TRIGGER sync_device_shutdown_schedule_from_heartbeat
AFTER UPDATE OF metadata ON public.devices
FOR EACH ROW EXECUTE FUNCTION private.sync_device_shutdown_schedule();

DROP TRIGGER IF EXISTS retry_shutdown_after_rental_end ON public.rental_sessions;
CREATE TRIGGER retry_shutdown_after_rental_end
AFTER UPDATE OF status ON public.rental_sessions
FOR EACH ROW
WHEN (OLD.status IN ('active','paused') AND NEW.status IN ('ended','expired'))
EXECUTE FUNCTION private.retry_shutdown_after_rental_end();

-- If a timer was already waiting when the migration landed, attempt its safe handoff now.
DO $deferred_shutdown_backfill$
DECLARE r record;
BEGIN
  FOR r IN
    SELECT device_id
    FROM public.device_shutdown_schedules
    WHERE state = 'waiting_for_rental_end'
  LOOP
    PERFORM private.try_queue_deferred_shutdown(r.device_id);
  END LOOP;
END;
$deferred_shutdown_backfill$;

REVOKE ALL ON FUNCTION private.try_queue_deferred_shutdown(uuid) FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.track_device_shutdown_command() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.sync_device_shutdown_schedule() FROM PUBLIC, anon, authenticated;
REVOKE ALL ON FUNCTION private.retry_shutdown_after_rental_end() FROM PUBLIC, anon, authenticated;
