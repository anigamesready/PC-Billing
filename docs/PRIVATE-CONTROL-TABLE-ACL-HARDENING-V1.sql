-- Applied as private_control_tables_revoke_client_access_v1 to both DB1 and DB2.
-- Direct client grants are unnecessary: these tables have no client-facing RLS policies and
-- should be reached through trusted SECURITY DEFINER RPCs or server-side service_role.
REVOKE ALL PRIVILEGES ON TABLE
  public.admin_alert_events,
  public.billing_control_accounts,
  public.billing_control_sessions,
  public.db_route_control
FROM anon, authenticated;
