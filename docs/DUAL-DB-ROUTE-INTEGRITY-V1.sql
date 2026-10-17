-- Applied as dual_db_route_integrity_v1 to both DB1 and DB2.
-- Align the route-control epoch guard and updated_by FK. No business rows are copied or deleted.
ALTER TABLE public.db_route_control DROP CONSTRAINT IF EXISTS db_route_control_epoch_check;
ALTER TABLE public.db_route_control
  ADD CONSTRAINT db_route_control_epoch_check CHECK (epoch >= 1) NOT VALID;
ALTER TABLE public.db_route_control VALIDATE CONSTRAINT db_route_control_epoch_check;

DO $integrity$
BEGIN
  IF NOT EXISTS (
    SELECT 1 FROM pg_constraint
    WHERE conrelid = 'public.db_route_control'::regclass
      AND conname = 'db_route_control_updated_by_fkey'
  ) THEN
    ALTER TABLE public.db_route_control
      ADD CONSTRAINT db_route_control_updated_by_fkey
      FOREIGN KEY (updated_by) REFERENCES auth.users(id) ON DELETE SET NULL
      NOT VALID;
    ALTER TABLE public.db_route_control VALIDATE CONSTRAINT db_route_control_updated_by_fkey;
  END IF;
END
$integrity$;
