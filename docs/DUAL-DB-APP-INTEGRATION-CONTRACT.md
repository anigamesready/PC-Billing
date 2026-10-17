# AniGames Dual-DB App Integration Contract (Proposal v1)

Status: **proposed app/backend handshake; not a live routing endpoint**. The current app must not assume this endpoint exists or change production targets until the backend publishes and verifies it.

## Goal

PC Billing, Admin Android, and the backend must use one authoritative route decision. A DB selector stored in browser/local storage is a local Admin login target only; it is not a cross-app failover mechanism. DB1 remains primary until the backend confirms schema parity, row/data parity, gateway readiness, and a successful cutover test.

## Proposed resolver

The backend should publish a stable endpoint independent from DB1 and DB2:

- GET /v1/route/resolve
- Cache-Control: no-store
- No service-role secret in any desktop, web, reseller, or Android client.
- The endpoint must not select a new target just because one DB times out.

Example response (the resolver must return real values, not these examples):

~~~json
{
  "contract": "ani-games-dual-db/v1",
  "request_id": "server-generated-id",
  "served_at": "2026-10-18T00:00:00Z",
  "routing": {
    "status": "ready",
    "active_target": "primary",
    "epoch": 1,
    "switch_id": null,
    "gateway_base_url": "https://<stable-gateway-host>/v1",
    "allow_reads": true,
    "allow_writes": true,
    "allow_enrollment": true,
    "retry_after_ms": 15000,
    "reason_code": null
  },
  "targets": {
    "primary": {
      "project_ref": "<actual-primary-ref>",
      "schema_version": "<actual-schema-version>",
      "schema_ready": true,
      "data_parity_ready": false,
      "last_parity_check_at": null
    },
    "backup": {
      "project_ref": "<actual-backup-ref>",
      "schema_version": "<actual-schema-version>",
      "schema_ready": true,
      "data_parity_ready": false,
      "last_parity_check_at": null
    }
  },
  "capabilities": {
    "pc_heartbeat": true,
    "pc_enrollment": true,
    "rental_sync": true,
    "device_commands": true,
    "admin_alerts": true,
    "cross_db_sync": false
  }
}
~~~

## Required behavior

1. The resolver is the only authority for the active target and monotonically increasing epoch. Both apps must validate the contract version, known target, project_ref, epoch, gateway URL allowlist, and response timestamp before using a new route.
2. All PC enrollment, heartbeat, rental sync, command acknowledgement, and alerts must go through the same stable gateway. The gateway performs server-side routing and token validation; clients must not choose DB1/DB2 independently for writes.
3. Fail closed. A timeout, 5xx, INVALID_DEVICE_TOKEN, a stale parity check, mismatched epoch/switch ID, or wrong project ref must never cause automatic failover. Keep local pairing identity, dirty rental records, sync cursor, and alert outbox. Show an actionable status and use bounded/backed-off retries.
4. A cutover is allowed only after schema readiness, row-level parity, ID mapping, active rentals/sessions, non-terminal commands, device tokens, and edge-function configuration are verified, and an explicit cutover test succeeds. A schema-only check or reachable health endpoint is not enough.
5. Cross-database copy/merge/overwrite must be an authenticated backend operation with idempotency keys, a dry-run/preview, audit trail, bounded batches, conflict reporting, and a verified rollback/recovery plan. Client-side JavaScript must not orchestrate privileged cross-project copies.
6. Read-only status checks may be exposed to clients. All privileged actions must enforce owner authorization on the server, not trust a role or organization ID supplied by the client.
7. Alert delivery must de-duplicate by source event ID. Polling may be a foreground fallback; reliable background/terminated-app notifications need a server push path such as FCM with server-side credentials and token lifecycle handling.

## What the apps currently do

- Admin APK performs read-only checks against each project's existing db-route-status endpoint, compares both returned statuses, and reports why cutover is blocked. It intentionally keeps cross-project sync disabled until the safe backend operation exists.
- PC Billing keeps local pairing/sync state when the token is rejected and stops automatic heartbeat retries pending explicit recovery.
- These changes do not create the proposed resolver, do not copy/migrate rows, and do not change either database's active target.

## Acceptance tests for the shared backend

- DB1 online / DB2 incomplete: route remains primary; failover and destructive sync are denied.
- One status endpoint is stale, unavailable, or returns another project ref: cutover denied.
- Epoch or switch_id differs across checks: cutover denied.
- PC token is temporarily rejected during an unresolved route change: client data/outbox remains recoverable and pairing is not silently deleted.
- Duplicate alert/event delivery: one visible alert per event ID, not one per retry.
- Switch-back test: route epoch increases, PC timers/rentals/commands are reconciled without creating duplicates, and audit records identify the operator and reason.

This file is a shared integration proposal. The deployed backend must confirm the final URL, response schema, and migration sequence before the clients enable routing or cross-database writes.
