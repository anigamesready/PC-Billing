-- DB Android local prerequisites. Run only on a fresh staging database after review.
-- This creates no accounts and copies no Supabase Auth secrets.
BEGIN;
CREATE SCHEMA IF NOT EXISTS extensions;
CREATE SCHEMA IF NOT EXISTS auth;
CREATE SCHEMA IF NOT EXISTS private;
CREATE SCHEMA IF NOT EXISTS reporting_private;
CREATE EXTENSION IF NOT EXISTS pgcrypto WITH SCHEMA extensions;

-- Minimal Auth identity reference for imported foreign keys only.
-- Local sign-in will be implemented by the Ani Games API, not by pretending Supabase Auth exists.
CREATE TABLE IF NOT EXISTS auth.users (
  id uuid PRIMARY KEY,
  email text UNIQUE,
  created_at timestamptz NOT NULL DEFAULT now(),
  updated_at timestamptz NOT NULL DEFAULT now()
);

DO $$
BEGIN
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime') THEN
    CREATE ROLE ani_api_runtime NOLOGIN NOSUPERUSER NOCREATEDB NOCREATEROLE NOINHERIT NOBYPASSRLS;
  END IF;
END
$$;
GRANT USAGE ON SCHEMA public,auth,extensions TO ani_api_runtime;
COMMIT;
