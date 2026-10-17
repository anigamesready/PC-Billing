# Backend stabilization plan before DB2 cutover

## Keep production stable
- DB1 remains primary. Both route-control rows stay at `active_target = primary`.
- Never declare DB2 ready from schema parity or row counts alone.
- Do not replay queued/historical device commands as part of a data copy.
- Do not export plaintext device tokens or reuse expired enrollment codes.

## Already executed on both Supabase projects
- `dual_db_readiness_guard_v1`: add route-readiness metadata and guard the route RPC.
- `dual_db_cutover_guard_v2`: require `backup_ready`, `data_parity_ready`, and `routing_gateway_ready` before a backup route can be selected.
- `dual_db_route_integrity_v1`: align the epoch CHECK constraint and validate the `updated_by → auth.users(id) ON DELETE SET NULL` foreign key on both databases.
- `private_control_tables_revoke_client_access_v1`: revoke direct `anon`/`authenticated` access to internal alert/billing-control/route tables while preserving server-role access.
- `db-route-status` now reports these gates consistently; the function is read-only and returns no service credential.

## Why the gateway is a separate milestone
The current route metadata is not a cross-project proxy. Each Supabase project has its own Auth, REST/PostgREST, Realtime, Edge Functions, database credentials, and local control row. Updating `active_target` on one project does not automatically retarget clients or update the control row on the other project.

A safe stable gateway therefore needs:
1. A server-only credential/config path for both projects, stored as secrets (never in Android APK or PC source).
2. An explicit tenant/admin/device authorization layer before each privileged read/write.
3. A defined source-of-truth and idempotency strategy for writes, sessions, commands, billing transactions, and alerts.
4. Controlled retries and audit IDs so failover does not create duplicate transactions or repeat a command.
5. Health checks and an owner-only cutover control with a real rollback procedure.
6. Contract tests for current PC and Admin clients and a versioned compatibility window.

Do not deploy a gateway that simply forwards arbitrary SQL/RPC or accepts a client-chosen project URL. That would make the backup switch a security boundary bypass.

## Next implementation phases
1. Finish the row-level parity and schema audit (current report in `DUAL-DB-ROW-PARITY-REPORT-2026-10-18.md`).
2. Harden remaining schema integrity differences and produce an idempotent reconciliation plan.
3. Build the gateway/config adapter in a non-production branch/environment and test with read-only calls first.
4. Add write paths only after tenant/auth/idempotency rules have been verified.
5. Run end-to-end tests against DB1, run shadow validation against DB2, and prove rollback.
6. Only after sign-off may DB2 readiness fields be set true.

## Status naming
`sync_ready` is retained for compatibility with the existing route contract. Use `data_parity_ready` for cross-database row parity and `routing_gateway_ready` for actual client traffic routing. They are intentionally independent flags.


## DB1 hardening checkpoint — 2026-10-18
- Revoked direct `EXECUTE` on `public.audit_normalize_rental_identity_update()` from `PUBLIC`, `anon`, and `authenticated`. Verification: `anon_exec=false`, `authenticated_exec=false`; the function remains attached to its database trigger and `service_role` still has execute permission. This removes the exposed RPC path without removing the trigger.
- Re-ran the Supabase security advisor. The public-executable `SECURITY DEFINER` finding is gone. Remaining findings: `pg_net` installed in `public` (do not move until dependent jobs/functions are mapped), leaked-password protection disabled (Auth project setting), and six internal tables with RLS but no policies. Those six tables are intentionally locked down by revoking direct `anon`/`authenticated` privileges; they must remain inaccessible directly and be accessed only through approved server/RPC paths.
- Route control re-verified: `active_target=primary`, `epoch=1`, `primary_ready=true`, `backup_ready=false`, `data_parity_ready=false`, `routing_gateway_ready=false`. No cutover or business-row mutation was performed.
- Pairing rate-limit code is present in the deployed `ani-games-api` `device/enroll` branch, but a successful enrollment-path smoke test has not been run after that deployment because there was no safe, valid unused enrollment code. Do not call this fully verified until a controlled test code can be created and consumed, then confirm the rate-limit rows are cleared and a paired device can heartbeat.
- Completed: fixed legacy JWT service-key bearer detection in deployed `ani-games-api` version 26 and synchronized the repository source. Remaining: run a controlled enrollment smoke test with a short-lived test code; keep the legacy PC client request/response contract unchanged.


## DB1 sync idempotency hotfix — 2026-10-18
- Logs showed repeated `POST /device/sync → 400` errors caused by `duplicate key value violates unique constraint rental_accounts_org_id_code_key` inside `api.device_sync()`. The event was for an organization/code already present on another device; the old query filtered that row out and then attempted a conflicting insert.
- Replaced `api.device_sync(text,jsonb)` on DB1 with a hardened implementation: `search_path = pg_catalog, public`, a transaction advisory lock keyed by organization+account code, and a lookup of the unique row regardless of device ownership. Existing rows owned by another device are left unchanged and their source event is acknowledged so they do not jam every subsequent batch. Existing event insert idempotency remains protected by `(org_id, source_event_id)` conflict handling.
- Verification: an isolated test created disposable organization/devices/token/account rows, sent a `rental_account_upsert` for the same code from the other device, asserted that the event was acknowledged with `inserted=0` and that the original account/device/remaining time stayed unchanged, then deleted all test rows. The test completed successfully.
- SQL source is preserved in `DB1-DEVICE-SYNC-IDEMPOTENCY-FIX-2026-10-18.sql`. The hotfix is live on DB1 only; DB2 remains blocked pending row parity and gateway readiness. Do not copy this change to DB2 until its existing `device_sync` contract is compared and the parity plan is reconciled.
- Follow-up verification: monitor fresh PC sync calls after rollout and confirm the duplicate-key `23505` errors stop. No production account/session/transaction rows were edited by the isolated test.
