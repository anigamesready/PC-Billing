# DB1 fundamental hardening — 18 October 2026

## Scope / current decision

This round improves DB1 only. The existing primary route is unchanged:
- `active_target = primary`
- `primary_ready = true`
- `backup_ready = false`
- `data_parity_ready = false`
- `routing_gateway_ready = false`

No rental/session/transaction/device rows were intentionally migrated or deleted. DB2 remains ineligible for cutover.

## Applied to live DB1

| Migration | Change | Verification |
|---|---|---|
| `device_disconnect_revoked_token_idempotency_v1` | Replaying an already-revoked PC token now returns `already_disconnected=true` without marking the device offline again or adding repeated disconnect audit rows. | A rollback-wrapped DB test confirmed first disconnect revokes once and the replay is idempotent. Test token and mutations were rolled back; existing offline device state/token were restored. |
| `drop_duplicate_device_heartbeats_index_v1` | Removed duplicate `(device_id, received_at DESC)` index `device_heartbeats_device_received_at_idx`; kept `idx_device_heartbeats_device_received`. | Afterward, only one non-PK index on that exact key/order remains; the retained index had 22 scans versus 1 scan on the removed duplicate. |
| `active_admin_username_lookup_hardening_v1` | `api.resolve_admin_username` now filters to active accounts, bounds username length, and puts `pg_catalog` first in its pinned search path. | Function definition and privileges re-checked. This is transitional; it still returns an active admin's email to anonymous callers until Admin APK switches to the new login endpoint. |
| `admin_username_casefold_unique_v1` | Added unique index on `lower(trim(username))`, matching the app's case-insensitive username semantics. | Pre-migration scan found no duplicate normalized usernames; index creation succeeded. |
| `db_route_control_updated_by_index_v1` | Added index on the FK column `db_route_control.updated_by`. | Index present; the advisor's unindexed-FK finding disappeared. The table is singleton/small; this is integrity/best-practice coverage, not a material speed claim. |
| `device_heartbeat_history_retention_30d_v1` | Added active daily pg_cron cleanup for heartbeat samples older than 30 days. | Job `device-heartbeats-retention-30d` is active at `17 18 * * *` UTC. At setup, 31,202 samples existed, 12,063 older than 7 days, none older than 30 days; no existing rows were deleted by the migration. |
| `admin_login_rate_limit_ledger_v1` | Added server-only hashed-key rate-limit ledger and service-only consume/clear RPCs, 5 attempts per 15-minute window, 15-minute lock. | A DB test confirmed attempts 1–5 are admitted, attempt 6 blocked with retry metadata, cleanup succeeds, no test rows remain, and anon/authenticated cannot select the table or execute the limiter RPC. |
| `admin_login_rate_limit_cleanup` | Daily cleanup of rate-limit buckets older than 7 days. | Cron job active at `43 18 * * *` UTC. |
| `device_pairing_rate_limit_ledger_v1` | Server-only hashed buckets for pairing attempts by normalized code/client ID and optional trusted IP, 5 code/client attempts or 60 IP attempts per 15-minute window. | SQL test confirmed a 3-attempt test bucket blocks the next request, cleans its test row, and is not callable/readable by anon/authenticated. |
| `device_rpc_payload_limits_v1` + `device_sync_payload_preflight_v1` | Bound input sizes for device sync, heartbeat, command ACK, trial finalize, and admin alerts. | SQL guard tests rejected oversized payloads for all five RPCs; no test rows or business writes remained. |
| `device_ack_idempotency_monotonic_state_v1` | Replayed ACKs no longer duplicate command/audit logs, and a stale ACK cannot revert a terminal command status. | Synthetic command test verified only two log/audit rows for two legitimate state transitions; duplicate and stale ACKs added none. Test token/command/logs were cleaned up. |
| `sensitive_auth_and_pairing_rpc_server_only_v1` | Removed direct PUBLIC/anon/authenticated execute access to legacy username resolver, billing login RPC, and device redemption RPC; service-role access remains for Edge Functions. | ACL query confirms anon/authenticated=false and service_role=true for all three.

## New Edge Functions / compatible API gateway deployed on DB1

- `admin-login` v2: accepts username or email plus password, looks up only active `SUPER_ADMIN` accounts through service-only `api.admin_login_lookup`, verifies through Supabase Auth, returns access/refresh token data, and uses persistent hashed username/IP buckets. The current Admin APK source still signs in directly with email; it has not been switched to this endpoint.
- `billing-login` v1: wraps `api.billing_login` with a persisted rate limiter before calling the legacy RPC, preserving the existing success payload. The inspected PC/Admin source bundles do not call the raw RPC; any other client must use this gateway now that raw RPC execute has been revoked.
- `device-enroll` v1: standalone alternative server endpoint using the same service-only pairing rate-limit ledger.
- `ani-games-api` v22: importantly, the existing `device/enroll` route used by the current PC Billing source was hardened in place. The URL/response envelope remains the same; it now rate-limits code/client ID and the trusted gateway IP header when available, then calls `redeem_device` through service-role credentials. Direct `api.redeem_device` execute is now revoked from clients.

Source snapshots are stored at:
- `supabase/functions/admin-login/index.ts`
- `supabase/functions/admin-login/deno.json`
- `supabase/functions/billing-login/index.ts`
- `supabase/functions/billing-login/deno.json`
- `supabase/functions/device-enroll/index.ts`
- `supabase/functions/device-enroll/deno.json`

**Deployment is not the same as end-to-end network verification.** The current PC client continues using the same `ani-games-api/device/enroll` URL and response contract, so pairing throttling did not require a PC update. The direct RPC grants were revoked only after moving known consumers behind server-side endpoints. Public POST testing from this environment could not complete because outbound DNS resolution is unavailable; a controlled live pairing/login test still needs to be done. The Admin APK's current email/password Auth flow remains unchanged.

## Remaining critical blockers — DB1 is hardened but not fully certified yet

1. **Supabase Auth leaked-password protection remains disabled.** This setting cannot be changed through the connected Supabase tools available in this run. Enable it in Dashboard → Authentication → Password Security. [Supabase guidance](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
2. **`pg_net` remains in the `public` schema.** Attempts to revoke its Supabase-owned ACLs did not change the grants because the runtime SQL role is not the extension owner/superuser. `net` is not in the PostgREST exposed schemas (`public,api`) and no application SQL function uses `net.http_*`; this is an advisor warning not yet remediated at owner level.
3. **Public Edge Function POST testing could not be completed from this runtime** because outbound DNS resolution failed. SQL-level tests passed and deployments report ACTIVE, but run a controlled test login/pairing/heartbeat/ACK from a real test client before declaring DB1 fully ready.
4. **Backup/restore proof is still missing.** Do not enable DB2 readiness until there is a verified restore procedure and a final row-level parity report.
5. **Admin APK custom-login gateway adoption is optional for the current known client** (current source uses Supabase Auth email sign-in). Its direct `resolve_admin_username` helper has been made service-only to close the email disclosure; old APK variants that attempted username-to-email lookup must update to use `admin-login` before using that legacy behavior.

## Advisor findings after changes

- Duplicate-index warning for `device_heartbeats` disappeared.
- Unindexed FK warning for `db_route_control.updated_by` disappeared.
- Remaining `unused_index` findings are INFO-level; no indexes were deleted based solely on the cumulative usage counters.
- `rls_enabled_no_policy` INFO notices remain on six internal service-only tables: `admin_alert_events`, `admin_login_rate_limits`, `billing_control_accounts`, `billing_control_sessions`, `db_route_control`, and `device_pairing_rate_limits`. RLS is enabled and direct `anon`/`authenticated` privileges have been revoked; the no-policy shape is intentional for these service-only tables.
- The advisor still warns that `pg_net` is installed in `public` and that Auth leaked-password protection is disabled.

## Cutover readiness

DB1 remains the only active primary. These changes improve DB1 but do not prove DB2 parity and do not create transparent cross-project request routing. The next safe milestone is: update the Admin APK and PC client to the new login/enrollment gateway contracts, exercise success/failure/lockout/recovery in a controlled test, then revoke direct public RPC grants only for routes no longer used by the old client.
