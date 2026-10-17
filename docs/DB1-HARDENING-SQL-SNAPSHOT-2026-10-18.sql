-- DB1 hardening SQL snapshot, 2026-10-18.
-- Reference for already-applied changes. Review before re-running against any environment.
-- This is not a single atomic migration file and is not intended for blind re-execution.

-- 1) Disconnect idempotency: a revoked token replay no longer mutates status/audit.
-- The current definition is available in the DB migration history as device_disconnect_revoked_token_idempotency_v1.

-- 2) Drop the redundant heartbeat-history index; keep the index with observed workload scans.
DROP INDEX IF EXISTS public.device_heartbeats_device_received_at_idx;

-- 3) Match case-insensitive login lookup behavior with a unique normalized username index.
CREATE UNIQUE INDEX IF NOT EXISTS admin_accounts_username_lower_key
ON public.admin_accounts (lower(trim(username)));

-- 4) Index the route-control foreign key.
CREATE INDEX IF NOT EXISTS idx_db_route_control_updated_by
ON public.db_route_control(updated_by);

-- 5) Add service-only rate-limit ledger.
-- The full table/RPC definitions are in migration admin_login_rate_limit_ledger_v1.
-- These RPCs are server-only and must not be granted to PUBLIC/anon/authenticated.

-- 6) Heartbeat history retention: applied as cron job device-heartbeats-retention-30d.
-- SELECT cron.schedule('device-heartbeats-retention-30d','17 18 * * *',
--   'DELETE FROM public.device_heartbeats WHERE received_at < now() - interval ''30 days'';');

-- 7) The pg_net REVOKE attempts did not take effect due Supabase-owned object ACLs.
-- Do not copy them into remediation scripts as if fixed.
