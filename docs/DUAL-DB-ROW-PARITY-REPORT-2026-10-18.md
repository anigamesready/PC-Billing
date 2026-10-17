# DB1 ↔ DB2 row-level parity report — 18 October 2026

## Decision

**Do not cut over to DB2. DB1 remains the active primary.**

This report is based on read-only queries against:
- DB1 project ref: `wzkjpycjizexxcxrfdvr`
- DB2 project ref: `xcdbipgsvohesxhxydep`

No production records were copied, updated, or deleted while preparing this report.

## Table-ID and material-field comparison

| Table | DB1 | DB2 | DB1-only IDs | DB2-only IDs | Material mismatch among shared IDs |
|---|---:|---:|---:|---:|---:|
| organizations | 2 | 2 | 0 | 0 | 0 |
| org_members | 3 | 3 | 0 | 0 | 0 |
| admin_accounts | 2 | 2 | 0 | 0 | 0 |
| devices | 3 | 1 | 2 | 0 | 1 |
| device_tokens (by device ID) | 3 | 1 | 2 | 0 | not compared; token hashes intentionally not exported |
| device_enrollments | 83 | 0 | 83 | 0 | — |
| rental_accounts | 35 | 29 | 6 | 0 | 8 |
| rental_sessions | 231 | 173 | 58 | 0 | 1 |
| billing_transactions | 45 | 42 | 3 | 0 | 0 |
| device_commands | 388 | 0 | 388 | 0 | — |
| usage_events | 30 | 30 | 0 | 0 | 0 |
| admin_alert_events | 0 | 0 | 0 | 0 | — |

“DB1-only” means the ID exists in DB1 but not in DB2. Material-field comparisons use selected application fields and exclude volatile heartbeat timestamps and token hashes; they are not an exhaustive checksum of every column.

## What the differences mean

- DB1's currently online PC is marked offline in DB2. The shared device ID exists in both, but `status` and `power_state` disagree.
- Two devices and two device-token rows present in DB1 are absent in DB2. A PC holding a token whose hash is absent from DB2 would fail device-token authentication there.
- DB1 has 83 enrollment rows; none are in DB2. At report time DB1 had 10 used and 73 expired-unused codes, with zero unused non-expired codes. Do not copy expired codes as usable enrollments.
- Six rental-account IDs are missing from DB2. Eight shared rental accounts also have a different `remaining_seconds` value. These are live billing values; DB2 appears stale rather than synchronized.
- Fifty-eight rental-session IDs are missing from DB2. One session is ended in DB1 but still active in DB2. Treating DB2 as active before reconciling this could revive a session the primary already ended.
- Three billing-transaction IDs are missing from DB2.
- The 388 device-command rows in DB1 are historical states (94 acknowledged, 221 completed, 73 failed at audit time); DB2 has none. The queried summary found no queued command rows, but command history/log relationships still need verification.
- Organization, membership, admin-account IDs, and the queried usage-event rows match by ID and compared business fields.

## Structural comparison

- 25 table/view column signatures were present in both databases and matched.
- 100 indexes and 2 triggers matched by name and definition.
- 23 RLS policies matched by table, command, roles, predicate, and check predicate.
- Function signatures: 89 in DB1 and 88 in DB2. DB1 has one extra `public.rls_auto_enable()` helper. The two `api.db_route_get/set` definitions intentionally differ by local project profile and project ref; other inspected function definitions matched.
- The epoch CHECK constraint is written as `epoch >= 1` in DB1 and `epoch > 0` in DB2 (equivalent for an integer). DB1 also has an `updated_by → auth.users(id)` foreign key on `db_route_control` that DB2 lacks; align this during the DB2 schema-hardening stage.
- The migration history differs because DB2 was cloned and seeded separately. Matching columns do not prove complete migration-history parity, and do not establish a transparent failover path.

## Backend guard applied

Migration names on both projects:
- `dual_db_readiness_guard_v1`
- `dual_db_cutover_guard_v2`

The route status Edge Function is active on both projects. The backend now requires all three flags to select backup:
- `backup_ready = true`
- `data_parity_ready = true`
- `routing_gateway_ready = true`

All three remain false. `active_target` remains `primary` on both DBs.

A controlled test temporarily set only `backup_ready = true` inside the verification transaction and confirmed that `api.db_route_set('backup', ...)` still rejected the switch because data parity and the gateway readiness gates remained false. The test restored the flag to false and confirmed the active target did not change.

## What must happen before the data-migration stage

1. Decide which exact DB1 records are current versus intentionally historical/archived (especially two absent devices, the six missing rental accounts, and the 58 sessions).
2. Define an idempotent, resumable copy/reconciliation path that preserves primary IDs, foreign-key order, transaction uniqueness, and tenant boundaries; never blindly replay old commands or expired enrollment codes.
3. Account for the two missing device-token hashes securely, or deliberately rotate/re-enroll devices in a controlled process. Never export plaintext device tokens.
4. Reconcile remaining time and active/ended session state using DB1 as the current source of truth at the chosen cutover point.
5. Validate backups and restore procedures; then test pairing, heartbeat, rental start/stop/expiry, transactions, admin alerts, RLS, and rollback in a controlled window.
6. Implement and test a stable API/gateway path before setting `routing_gateway_ready = true`. A route flag alone cannot redirect Supabase Auth, REST, Realtime, and Edge Function calls between projects.

Until all checks pass, keep DB2 read-only for this migration effort and do not mark it ready.
