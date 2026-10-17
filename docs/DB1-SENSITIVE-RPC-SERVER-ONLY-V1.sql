-- Applied on DB1 as sensitive_auth_and_pairing_rpc_server_only_v1.
-- The inspected Admin APK signs in through Supabase Auth using email. The current PC Billing
-- source routes enrollment through the unchanged ani-games-api /device/enroll path.
-- Their server-side functions now own the protected RPC calls.
REVOKE ALL PRIVILEGES ON FUNCTION api.resolve_admin_username(text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.resolve_admin_username(text) TO service_role;

REVOKE ALL PRIVILEGES ON FUNCTION api.billing_login(text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.billing_login(text, text) TO service_role;

REVOKE ALL PRIVILEGES ON FUNCTION api.redeem_device(text, text, text, text) FROM PUBLIC, anon, authenticated;
GRANT EXECUTE ON FUNCTION api.redeem_device(text, text, text, text) TO service_role;
