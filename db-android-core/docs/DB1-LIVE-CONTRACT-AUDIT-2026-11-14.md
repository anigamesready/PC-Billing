# DB Android Core — live DB1 audit and compatibility contract

Audit date: 2026-11-14  
Reference project: Supabase Primary `wzkjpycjizexxcxrfdvr`  
Repository branch: `backend/db-android-core-v1`

## Executive result

The Ani Games Ready business logic already exists in DB1. The Redmi project is therefore a controlled port of an existing system, not a new rental product. A read-only live catalog audit found:

- 41 tables across `public`, `private`, and `reporting_private`.
- 161 PostgreSQL routines; 152 are marked `SECURITY DEFINER`.
- 116 triggers attached to 17 trigger functions.
- 14 active Supabase Edge Functions.
- 37 tables in `public`, one in `private`, three in `reporting_private`.

A schema-only copy is not enough. The current backend depends on token/session rules, Postgres transaction locks, command acknowledgement, event idempotency, offline leases, reporting aggregates, and role/org scoping.

## Table inventory and intended local treatment

### Core business tables (24)

`organizations`, `org_members`, `devices`, `device_enrollments`, `device_tokens`,  
`rental_accounts`, `rental_sessions`, `billing_transactions`, `usage_events`,  
`billing_control_accounts`, `billing_control_sessions`, `admin_accounts`, `admin_pc_access`,  
`device_commands`, `device_command_logs`, `device_heartbeats`, `device_trial_requests`,  
`admin_alert_events`, `audit_logs`, `themes`, `rental_offline_leases`,  
`rental_sync_conflicts`, `admin_login_rate_limits`, `device_pairing_rate_limits`.

These are the first local schema port. Account rows/password hashes/tokens are not in the GitHub snapshot.

### Supabase-specific control or separate sidecar tables (17)

- Dual-DB sync/routing: `db_route_control`, `db_route_coordinator_internal`, `db_sync_runs`, `db_sync_verification`, `db_sync_before_images`.
- Superadmin extension: `superadmin_access_codes`, `superadmin_sessions`, `superadmin_audit`.
- Old shutdown scheduler: `device_shutdown_schedules`.
- WoL Relay sidecar: `wol_relay_enrollments`, `wol_relay_devices`, `wol_relay_commands`, `wol_relay_probes`.
- Telegram reporting sidecar: `telegram_settings`, `telegram_notification_outbox`, `telegram_device_presence`.
- Private feature setting: `private.admin_feature_settings`.

The local DB Android path must not depend on DB1/DB2 route switching, cross-project sync, or route-quiesce triggers. WoL Relay and Telegram remain separately managed. The shutdown countdown table/scheduler is not part of the local design; manual Windows power commands remain a separate Admin feature.

## Edge Function inventory (active at audit time)

| Function | Version | Purpose in current system |
|---|---:|---|
| `ani-games-api` | 35 | PC/device API, pairing, rental session operations, commands, alerts, Blynk/WoL relay token endpoints |
| `admin-login` | 2 | Admin username/email lookup and login rate limiting before Auth sign-in |
| `billing-login` | 1 | Billing/Reseller login via custom DB session |
| `device-enroll` | 1 | Rate-limited PC enrollment redemption |
| `reseller-admin` | 9 | Reseller administration endpoint, JWT verified |
| `ani-games-telegram-reporting` | 4 | Telegram reporting sidecar |
| `db-route-status` | 12 | Read-only DB1/DB2 route status |
| `db-route-coordinator` | 4 | Dual-DB route coordination |
| `db-route-readiness` | 11 | Dual-DB readiness checks |
| `db-sync-export` | 10 | Dual-DB export |
| `db-sync-apply` | 21 | Dual-DB sync apply |
| `db-core-sync` | 6 | Core DB sync |
| `rental-reseller-sync` | 2 | Reseller/rental sync |
| `shared-db-gateway` | 11 | Shared route resolver/gateway |

Only the business operations are port candidates. `db-route-*`, `db-sync-*`, `db-core-sync`, `rental-reseller-sync`, and `shared-db-gateway` are Supabase dual-DB infrastructure and must not be reused as the Redmi single-server routing layer.

## PC Billing API contract observed in deployed `ani-games-api` v35

The currently deployed PC API routes include:

- Pairing and identity: `device/enroll`, `device/disconnect`.
- Device lifecycle: `device/heartbeat`, `device/watchdog`, `device/ack`, `device/alert`.
- Sync: `device/sync`, `device/pull`, `device/sync-cursor`, `device/rentals`.
- Rental and session: `device/test-policy`, `device/rental/lookup`, `device/session/start`, `device/session/end`, `device/rental/release`.
- Existing sidecar routes: `wol/relay/register`, `wol/relay/heartbeat`, `wol/relay/poll`, `wol/relay/ack`, `wol/relay/probe-ack`.
- Existing Blynk owner controls: `iot/status`, `iot/power`.

Core PC RPC dependencies observed in the deployed function include `redeem_device`, `device_heartbeat`, `device_watchdog_poll`, `device_ack`, `device_finalize_trial`, `device_sync`, `device_pull_sync`, `device_sync_cursor`, `device_rentals_snapshot`, `device_free_test_policy`, `device_rental_lookup`, `device_start_rental_session`, `device_end_rental_session`, `device_release_rental_lease`, `device_emit_admin_alert`, `device_pairing_rate_limit_consume`, and `device_pairing_rate_limit_clear`.

The deployed v35 Edge Function contains DB1/DB2 route selection and forwarding. The Redmi adapter must deliberately replace that with one configured local DB; it must not copy DB route keys, Supabase service-role secrets, or DB2 forwarding logic.

## Authentication model observed

### Billing and Reseller

The live `api.billing_login(username,password)` routine:
1. Finds an active `billing_control_accounts` row by case-insensitive username.
2. Rejects disabled/locked accounts.
3. Verifies the password using `extensions.crypt(password,password_hash)`.
4. After 5 consecutive failures, locks the account for 10 minutes.
5. On success resets failure state and issues a random 32-byte token (hex).
6. Stores only SHA-256(token) in `billing_control_sessions`, with a 12-hour expiry.
7. `private.billing_account_by_token(token)` re-hashes the token, checks revocation/expiry/account status, locks/updates the session's last-seen timestamp, and returns the account.

Read-only account metadata showed 7 active billing-control accounts: 2 `SUPER_ADMIN` and 5 `RESELLER_ADMIN`; all 7 have a password hash and no Auth user ID. No password/hash values were read or copied. This is a strong candidate for preserving existing login credentials during a carefully controlled data migration, without placing hashes in GitHub.

### Admin APK

Current Admin V12.1.50 still uses the Supabase Auth path. Live `admin_context()` checks `auth.uid()` against `org_members`; `admin_context_v2()` checks `admin_accounts.auth_user_id`, active status, and role. A local DB Android Admin login must use an explicit server-issued session and derive its role/org scope server-side. A user-supplied role/org ID is never authoritative.

The local Admin path should use the existing `billing_control_accounts` SUPER_ADMIN record where appropriate, then return a role-scoped context. The Auth-specific table remains a compatibility reference; a local API must not pretend that the Supabase JWT/Auth server exists.

## Reseller rental safeguards that must be preserved

The live Reseller RPCs authenticate the token using `private.billing_account_by_token` and require role `RESELLER_ADMIN` with the same `org_id`. Operations are device-independent for global rental rows.

- Create: validates code, minutes, category and future expiry; uses `pg_advisory_xact_lock(org_id + normalized code)`; rejects duplicate code; writes rental account, transaction and audit row.
- Edit: locks the rental row; rejects active/paused sessions; updates status, time, expiry, label/category and optionally queues PC upsert if a device is assigned.
- Delete: uses a transaction and advisory lock; rejects active/paused sessions; rejects a still-valid offline lease; queues a best-effort PC delete command only if the rental is device-assigned; audits and deletes without requiring the PC to be online.
- The 2026-11-06 backend hotfix explicitly allows reseller accounts whose `auth_user_id` is NULL; the session token is the authentication proof. This is preserved as a non-executable reference in the Reseller DB Android branch.

Do not weaken the active-timer or offline-lease guards.

## Trigger audit and porting rules

Live DB1 has 116 triggers across 17 trigger functions. The triggers include:
- business behavior: rental identity normalization/audit, free-test session/trial guards, shutdown-timer scheduling rejection, rental-session Telegram sidecar capture;
- Supabase dual-DB infra: before-image capture, write-quiesce guards, route-control parity/cutover guards, sync direction normalization and sync verification guards;
- deprecated shutdown scheduling: schedule tracking and retry-after-rental-end.

Do not port the DB1/DB2 write-quiesce or before-image triggers into the local single-DB runtime. They depend on route/sync state and can block normal local writes. Port business guards explicitly. Do not reintroduce automatic shutdown countdowns.

## Routine inventory

The 161 live routines include:
- Admin and account context: `admin_context`, `admin_context_v2`, `admin_login_lookup`, `admin_recent_alerts`, `admin_devices`, `admin_selected_sessions`.
- Rental management: `admin_create_rental_global`, `admin_update_rental_global`, `admin_disable_rental_global`, `admin_delete_rental_global`, `billing_reseller_create_rental_global`, `billing_reseller_edit_rental_global`, `billing_reseller_delete_rental_global`, and global rental list routines.
- PC/device: `redeem_device`, `device_heartbeat`, `device_ack`, `device_sync`, `device_pull_sync`, `device_rental_lookup`, `device_start_rental_session`, `device_end_rental_session`, `device_release_rental_lease`, `device_watchdog_poll`.
- Reporting/theme: `report_detailed_usage_page`, `report_summary_compact`, `report_monthly_rental_summary`, `report_rental_period_breakdown`, `report_by_account_theme`, `save_theme`.
- WoL relay and Telegram: separate sidecar function groups; keep separate from the local DB switch.

152 of 161 routines are SECURITY DEFINER. The local API must carefully reimplement the intended role/org guards and transaction checks. Do not bulk-copy SECURITY DEFINER routines without reviewing their `search_path`, privileges and Supabase-specific dependencies.

## Known missing pieces before an app can connect

- Local equivalent for Supabase Auth and Admin sessions.
- Full function/API contract implementation and exact payload compatibility.
- Device token issuance, hashing, revocation and recovery enrollment.
- Rental sync cursor, idempotent event processing, conflict/outbox handling and offline leases.
- Transaction-level active-session protections and command ack lifecycle.
- Reports, monthly/yearly rankings, file export compatibility and timezone alignment.
- A migration/data-import process that preserves IDs, device tokens, sessions, rental history and audit log integrity.
- Automated tests run against a fresh local PostgreSQL instance and then a staging device; only after that can the Redmi service be upgraded.

## Safety boundary

All inspection of DB1 for this document was read-only. No Supabase data, route-control row, Edge Function, DB2 project or Blynk/WoL relay was modified. This document and schema snapshots contain structure/contract data only, no credentials or row data.
