# Ani Games Ready — V13 Dual-DB Base Audit
**Audit date:** 2026-10-26  
**Candidate branch:** `release/v13-dual-db-base-candidate`  
**Candidate code parent:** `feature/dual-db-runtime-routing-v1`  
**Decision:** **NOT RELEASE-FINAL — keep DB1 primary; do not cut over to DB2.**

## 1. Version/source identity — unresolved
The requested `V12.1.27` artifact could not be identified in the `anigamesready/PC-Billing` repository's visible `main` tree, searchable code, or searchable commit messages. The `main` tree contains `AniGames-PC-V12.1.0-ADMIN-POPUP-FIXED-SOURCE.zip`; the dual-DB runtime branch builds that source through patches to version `12.2.3`. This is **not evidence that V12.1.27 was found or renamed**.

For safety, this branch is an isolated **V13 base candidate and audit record**, not a replacement of `main`, not a release tag, and not proof of a final V13 build. Do not describe the requested V12.1.27 as migrated until its exact source/artifact is located and checked against this candidate.

## 2. Repository/code review
The selected candidate parent contains the dual-DB routing, shared-gateway client adapter, token-preservation patch, and V12.2.3 route-refresh patch. The build workflow includes Python patch execution, `node --check` for renderer/cloud/runtime JavaScript, token-based regression assertions, dependency installation, and a Windows EXE build. However, the GitHub commit-status endpoint returned **no reported status checks** for the inspected branch/main commits; the presence of a workflow is not proof that this candidate passed it.

### Source blocker: shared gateway implementation
`scripts/patch_pc_shared_gateway.py` rewrites device API calls to the endpoint:
`/functions/v1/shared-db-gateway/v1/`.

The inspected candidate tree includes `supabase/functions/ani-games-api/`, but no `supabase/functions/shared-db-gateway/` implementation. That endpoint may exist outside this repository, but its live deployment and contract have not been verified here. The active DB route-control rows also report `routing_gateway_ready=false`. Do not treat the gateway path as production-ready without checking the actual deployed endpoint and testing its authorization, target selection, and error responses.

### Useful safety behavior found in the candidate
- Routing checks the read-only status from both projects and rejects mismatched target/epoch/switch ID.
- The client is designed to fail closed rather than silently switch databases on a timeout.
- The V12.2.3 refresh patch requests a fresh route check for API reads/writes and checks finalized route evidence.
- The token-preservation patch is intended to preserve local pairing/sync state when a token is rejected instead of automatically deleting local pairing data.

These are useful safeguards, but static source checks do not replace build/installation and end-to-end smoke tests.

## 3. Live database gate status
Projects audited read-only:
- **DB1 / primary:** `wzkjpycjizexxcxrfdvr`
- **DB2 / standby:** `xcdbipgsvohesxhxydep`

Both live `public.db_route_control` rows report `active_target=primary`, `epoch=1`, and no `switch_id`. DB1 has `primary_ready=true`; both have `backup_ready=false`, `data_parity_ready=false`, `routing_gateway_ready=false`, and `auth_parity_ready=false`. The most recent parity-check timestamp is NULL. DB2's last route note records an aborted/unverified sync caused by a duplicate open rental session. No route change was made.

## 4. Current data comparison
Read-only row counts/fingerprints on 2026-10-26 show that the databases are **not at parity**.

| Table | DB1 | DB2 | Current assessment |
|---|---:|---:|---|
| organizations | 2 | 2 | Exact row fingerprint matched |
| device_enrollments | 83 | 83 | Exact row fingerprint matched |
| device_tokens | 3 | 3 | Exact row fingerprint matched |
| devices | 3 | 3 | Selected identity/status fields match, but whole-row fingerprint differs |
| org_members | 3 | 3 | Whole-row fingerprint differs |
| admin_accounts | 2 | 2 | Whole-row fingerprint differs |
| rental_accounts | 45 | 41 | Row count and fingerprint differ |
| rental_sessions | 395 | 346 | Row count and fingerprint differ |
| billing_transactions | 55 | 50 | Row count and fingerprint differ |
| billing_control_accounts | 5 | 5 | Whole-row fingerprint differs |
| billing_control_sessions | 7 | 20 | Row count and fingerprint differ |
| device_commands | 533 | 463 | Row count and fingerprint differ |
| device_trial_requests | 3 | 0 | Data missing on DB2 |
| audit_logs | 1,564 | 0 | History not copied |
| device_heartbeats | 36,874 | 8,750 | Telemetry/history differs |
| device_command_logs | 931 | 824 | Command history differs |

Counts alone are not a row-reconciliation proof. The full-row fingerprints above are comparison signals, not a substitute for a foreign-key-aware reconciliation report.

### Admin/Auth identity needs a cutover test
The two projects each have three Auth users, but **2 of the 3 Auth user UUIDs differ** between projects. An admin account and its org membership use project-local Auth IDs, so matching email addresses alone does not prove matching authorization, password/session behavior, or cross-project login. Confirm the intended admin users can log in and obtain the correct roles on DB2 before setting any readiness flag.

### Active rental-session conflict — current sync failure
DB1 has one active rental session for the main device `c30ddea5-2630-42dd-8980-89261b95defd` with a session deadline on 2026-10-26. DB2 retains a different session on the same device marked active, started 2026-10-23, whose deadline is already past. Both projects enforce the unique partial index `rental_sessions_one_open_per_device` on `device_id` for active/paused sessions.

The latest DB2 sync attempt on 2026-10-24 failed with:
`TARGET_DELTA_UPSERT_FAILED:rental_sessions:duplicate key value violates unique constraint "rental_sessions_one_open_per_device"`.

That run recorded 43 updated rows and 1 inserted row before failure; subsequent verification rows are absent for the failed run. Some partial upserts may remain on DB2 and are unverified. **Do not blindly replay the sync or manually end/delete the stale session without a deliberate reconciliation plan**, because current rental time, session state, and foreign-key references must be preserved.

## 5. Readiness decision
**V13 / dual-DB migration is blocked.** The following must pass before the candidate can be called final:

1. Identify and checksum the exact requested V12.1.27 artifact; document why it differs from the current V12.2.3 branch, or explicitly approve a different baseline.
2. Verify the actual shared-gateway deployment and its contract. Confirm the deployed function is present, performs server-side authorization/target routing, and is covered by integration tests.
3. Create a dry-run reconciliation for DB2 using DB1 as the source of truth at the chosen freeze point. Reconcile the stale open session first with explicit conflict reporting; preserve rental/session/transaction/device IDs and foreign keys.
4. Rerun an idempotent, resumable sync only after the session conflict is addressed; then verify **all allowlisted tables** by row IDs and material fields/fingerprints, including admin/organization mappings, pairing devices/tokens/enrollments, rental accounts/sessions, transactions, and active commands.
5. Validate auth/login and owner/reseller role authorization on DB2; do not infer auth parity from matching emails.
6. Run a controlled fresh-install regression on a test environment: PC pairing resume (no unexpected re-pair prompt), heartbeat, rental start/pause/resume/stop/expiry, account top-up/transaction, command acknowledgement, admin alerts, and switch-back/rollback. Do not use the active customer rental as the test session.
7. Confirm backup/restore and rollback evidence. Only then, after a new current parity check and gateway smoke test, may an authorized operator update the readiness flags and perform a controlled cutover.

## 6. Actions performed during this audit
- Read-only inspection of repository source/branches and both Supabase projects.
- Read-only queries for table counts/fingerprints, route-control status, sync-run history, active rental sessions, Auth ID mapping, and unique-index definition.
- Created this audit-only candidate branch from `feature/dual-db-runtime-routing-v1`.
- **No database rows, route flags, secrets, production source branch, or deployment were changed by this audit.**
