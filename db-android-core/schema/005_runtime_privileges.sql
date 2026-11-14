-- DB Android API least-privilege runtime grant set.
-- Apply after 003/004 migrations on a fresh staging database.
-- ani_api_runtime is intentionally NOLOGIN; Termux installer creates a separate
-- local LOGIN role with a generated password and grants it membership in ani_api_runtime.
-- The login role must never be superuser, owner of business tables, or have direct table rights.

BEGIN;

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime') THEN
    CREATE ROLE ani_api_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;

ALTER ROLE ani_api_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;

GRANT USAGE ON SCHEMA api TO ani_api_runtime;
GRANT EXECUTE ON ALL FUNCTIONS IN SCHEMA api TO ani_api_runtime;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA api FROM PUBLIC;

-- Callers may execute the API contract only; all table work happens inside the
-- audited SECURITY DEFINER routines. Never give the runtime role direct data rights.
REVOKE ALL PRIVILEGES ON ALL TABLES IN SCHEMA public FROM ani_api_runtime;
REVOKE ALL PRIVILEGES ON ALL SEQUENCES IN SCHEMA public FROM ani_api_runtime;
REVOKE ALL PRIVILEGES ON SCHEMA auth FROM ani_api_runtime;
REVOKE ALL PRIVILEGES ON SCHEMA reporting_private FROM ani_api_runtime;

-- Security-definer helpers are not exposed as direct RPC endpoints.
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM PUBLIC;
REVOKE EXECUTE ON ALL FUNCTIONS IN SCHEMA private FROM ani_api_runtime;

-- Future api functions created by the same migration owner must default to private execution.
ALTER DEFAULT PRIVILEGES IN SCHEMA api REVOKE EXECUTE ON FUNCTIONS FROM PUBLIC;
ALTER DEFAULT PRIVILEGES IN SCHEMA api GRANT EXECUTE ON FUNCTIONS TO ani_api_runtime;

COMMIT;

-- Termux installer must:
-- 1. Create LOGIN role ani_api_login with a freshly generated random password stored only in a
--    chmod 600 local .env file (never commit it or print it).
-- 2. GRANT ani_api_runtime TO ani_api_login.
-- 3. Use ani_api_login for Node pg Pool connections; do not use postgres/superuser in Node.
-- 4. Verify: rolsuper=false, rolcreatedb=false, rolcreaterole=false; no SELECT/INSERT/UPDATE/DELETE
--    on public tables; EXECUTE on the api.* contract is granted through ani_api_runtime membership.
