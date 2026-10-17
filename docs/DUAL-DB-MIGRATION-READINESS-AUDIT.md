# Dual-DB migration readiness audit — 18 October 2026

## Current decision

**Keep DB1 as active primary. Do not switch traffic to DB2 yet.**

Live projects checked:
- DB1 / primary: `wzkjpycjizexxcxrfdvr`
- DB2 / backup: `xcdbipgsvohesxhxydep`

## Findings

- Both databases expose 25 tables/views with columns across `public` and `api`; the column signatures compared in this audit matched.
- Their API function signatures also matched, except DB1 has one additional helper, `public.rls_auto_enable()`.
- Both have `api.db_route_get()`, `api.db_route_set(text,bigint,text)`, and a `public.db_route_control` row.
- Before the readiness migration, DB2's `db-route-status` function attempted to read `sync_ready`, `schema_version`, and `switch_id` from the route row, but those columns did not exist.
- Data rows are not in parity. Counts at audit time:

| Table | DB1 | DB2 |
|---|---:|---:|
| organizations | 2 | 2 |
| org_members | 3 | 3 |
| admin_accounts | 2 | 2 |
| devices | 3 | 1 |
| device_tokens | 3 | 1 |
| device_enrollments | 83 | 0 |
| rental_accounts | 35 | 29 |
| rental_sessions | 231 | 173 |
| billing_transactions | 45 | 42 |

Counts are warning signals, not a proof of which individual business rows are missing. A row-by-row, foreign-key-aware reconciliation is still required.

## Changes applied to both live databases

Migration name: `dual_db_readiness_guard_v1`.

- Added readiness and diagnostic fields to `public.db_route_control`.
- Extended `api.db_route_get()` to return the readiness status.
- Hardened `api.db_route_set()`: it requires the chosen target to be marked ready before it can change the route.
- Kept `active_target = 'primary'` on both DBs.
- Kept `primary_ready = true`, `backup_ready = false`. The backup cannot be marked ready from this migration.
- Deployed the read-only `db-route-status` Edge Function on DB1 and updated the one on DB2 to return the same readiness fields.

## Verification

- Both migrations returned success.
- A guarded test on each database attempted to select `backup` under an owner identity and verified that the backend rejected it with `DB_TARGET_NOT_READY`.
- After both tests, `active_target` remained `primary`, `sync_ready` remained true for the active primary, and `backup_ready` remained false.
- No billing/session/device rows were copied or deleted by this change.
- The Supabase security advisor still reports existing informational `RLS enabled with no policies` findings on `db_route_control` and other service-only tables. The route table remains protected by RLS; the RPCs use the existing `SECURITY DEFINER` pattern and owner check for route changes.

## Important limitation

This is a **backend safety/control-plane step**, not a transparent database proxy. It prevents an unready target from being selected through `api.db_route_set()` and provides a consistent status endpoint. It does not magically redirect existing SDK, REST, Auth, Realtime, or Edge Function requests from one Supabase project to the other.

To avoid future app rebuilds, a one-time client/API-adapter migration is still needed so PC Billing and Admin use a stable gateway/config endpoint. The gateway must preserve tenant authorization and admin authentication. Before DB2 is marked ready, perform an ID-level data reconciliation, validate every required function/RLS/grant, back up both databases, exercise PC enrollment/heartbeat/rental start-stop/expiry/admin notifications in a test window, and only then perform a controlled cutover with a rollback path.

## Next safe action

Run a row-level parity report per tenant for devices/tokens/enrollments, rental accounts/sessions, and billing transactions. Do not set `backup_ready = true` until discrepancies are resolved and the validation report has been reviewed.
