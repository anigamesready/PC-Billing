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

## New Edge Functions deployed (version 1, DB1 only)

- `admin-login`: accepts username/password, restricts to active `SUPER_ADMIN` accounts, verifies the password through Supabase Auth, returns access/refresh token data and a generic credential error, and uses persisted username/IP hash buckets.
- `billing-login`: wraps the existing billing-auth RPC on the server and applies the same independent, persistent rate limiter. It preserves the existing billing RPC's success payload to make the PC client migration small.
- `device-enroll`: wraps `api.redeem_device` using server-only credentials; it rate limits pairing attempts by a hashed code, normalized client ID, and trusted gateway IP header when available. The IP bucket allows up to 60 attempts per 15-minute window to support normal multi-PC setup, while the client/code buckets allow 5 attempts each. It returns the same success data envelope used by the current PC API.

Source snapshots are stored at:
- `supabase/functions/admin-login/index.ts`
- `supabase/functions/admin-login/deno.json`
- `supabase/functions/billing-login/index.ts`
- `supabase/functions/billing-login/deno.json`
- `supabase/functions/device-enroll/index.ts`
- `supabase/functions/device-enroll/deno.json`

**Deployment is not the same as adoption.** Current clients have not been switched to these endpoints in this DB1-only stage. The old routes must stay available until the Admin APK and PC Billing clients are updated and tested. Do not revoke the old RPC grants before that migration; doing so would break current sign-in.

## Remaining critical blockers — DB1 is improved, but not yet fully ready

1. **Old Admin username lookup still exposes the email of an active admin.** The new Edge Function is staged, but Admin APK must be moved to `/functions/v1/admin-login`; then anonymous execute on `api.resolve_admin_username(text)` must be revoked and verified.
2. **Old PC billing login has an ineffective in-function failed-attempt counter.** `api.billing_login` updates `failed_attempts` and then raises `INVALID_CREDENTIALS`; that exception rolls the same SQL transaction back. The new `billing-login` Edge Function supplies a separate committed limiter, but PC Billing must be moved to it before the old direct RPC can be locked down.
3. **Device pairing code attempts still need a server-enforced rate-limited gateway.** Do not revoke `api.redeem_device` until the PC client is moved to the replacement endpoint and pairing/repair/recovery tests pass.
4. **Supabase Auth leaked-password protection remains disabled.** The connected management tools available in this run do not expose the required Auth configuration write. Enable it in Supabase Dashboard → Authentication → Password Security before calling auth hardening complete. [Supabase guidance](https://supabase.com/docs/guides/auth/password-security#password-strength-and-leaked-password-protection).
5. **pg_net ACL attempt was not effective.** The attempted `REVOKE` migrations returned success but post-checks showed the grants unchanged because the schema/functions/queue are owned by `supabase_admin`, while the SQL session runs as non-superuser `postgres`. We must not claim this was fixed. `net` is not in PostgREST's exposed schemas (`public,api`) and no app SQL function uses `net.http_*`, so the usual Data API path does not expose those functions; an owner-level remediation can be considered separately.
6. **Backup/restore proof and an end-to-end auth test are still missing.** The Edge Function deployments and database rate-limit helper were verified, but this runtime could not make outbound requests to exercise the public Edge Function endpoints. Do a controlled POST test with a test user after the client is ready. No credential was used in this audit.

## Advisor findings after changes

- Duplicate-index warning for `device_heartbeats` disappeared.
- Unindexed FK warning for `db_route_control.updated_by` disappeared.
- Remaining `unused_index` findings are INFO-level; no indexes were deleted based solely on the cumulative usage counters.
- `rls_enabled_no_policy` INFO notices remain on five internal service-only tables: `admin_alert_events`, `admin_login_rate_limits`, `billing_control_accounts`, `billing_control_sessions`, and `db_route_control`. RLS is enabled and direct `anon`/`authenticated` privileges have been revoked; the no-policy shape is intentional for these service-only tables.
- The advisor still warns that `pg_net` is installed in `public` and that Auth leaked-password protection is disabled.

## Cutover readiness

DB1 remains the only active primary. These changes improve DB1 but do not prove DB2 parity and do not create transparent cross-project request routing. The next safe milestone is: update the Admin APK and PC client to the new login/enrollment gateway contracts, exercise success/failure/lockout/recovery in a controlled test, then revoke direct public RPC grants only for routes no longer used by the old client.
