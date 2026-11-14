-- DB Android runtime least-privilege assertions.
DO $$
DECLARE
  v_super boolean;
  v_login boolean;
  v_createdb boolean;
  v_createrole boolean;
  v_bypass boolean;
BEGIN
  SELECT rolsuper,rolcanlogin,rolcreatedb,rolcreaterole,rolbypassrls
  INTO v_super,v_login,v_createdb,v_createrole,v_bypass
  FROM pg_roles WHERE rolname='ani_api_runtime';
  IF NOT FOUND THEN RAISE EXCEPTION 'API_RUNTIME_ROLE_MISSING'; END IF;
  IF v_super OR v_login OR v_createdb OR v_createrole OR v_bypass THEN
    RAISE EXCEPTION 'API_RUNTIME_ROLE_PRIVILEGED';
  END IF;
  IF NOT has_schema_privilege('ani_api_runtime','api','USAGE') THEN
    RAISE EXCEPTION 'API_RUNTIME_SCHEMA_USAGE_MISSING';
  END IF;
  IF NOT has_function_privilege('ani_api_runtime','api.billing_login(text,text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.device_heartbeat(text,text,jsonb)','EXECUTE')
     OR NOT has_function_privilege('ani_api_runtime','api.billing_reseller_delete_rental_global(text,uuid,uuid)','EXECUTE') THEN
    RAISE EXCEPTION 'API_RUNTIME_FUNCTION_GRANTS_MISSING';
  END IF;
  IF has_table_privilege('ani_api_runtime','public.rental_accounts','SELECT')
     OR has_table_privilege('ani_api_runtime','public.rental_accounts','INSERT')
     OR has_table_privilege('ani_api_runtime','public.billing_control_accounts','SELECT')
     OR has_table_privilege('ani_api_runtime','public.devices','UPDATE') THEN
    RAISE EXCEPTION 'API_RUNTIME_HAS_DIRECT_TABLE_ACCESS';
  END IF;
END;
$$;
SELECT 'PASS: least-privilege API role can execute approved API functions but has no direct business-table privileges' AS result;
