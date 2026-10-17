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
