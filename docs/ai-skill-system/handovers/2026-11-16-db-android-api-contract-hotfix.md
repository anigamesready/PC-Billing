# Handover — Redmi DB Android API contract hotfix

- Date/time (Asia/Jakarta): 2026-11-16
- Status: IN PROGRESS — source fix and CI complete; Redmi application/device acceptance pending
- User request / acceptance criteria: finish the DB Android server/API audit and repairs, preserve the current Redmi database and old services, keep master/stable separate, and provide a safe Termux update package.
- Repository: anigamesready/PC-Billing
- Work branch: fix/db-android-core-api-contracts-20261116
- Exact source baseline branch + full SHA: backend/db-android-core-v1 — d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9
- Baseline ancestry: backend branch is 123 commits ahead of PC Billing DB Android source head f938c574dfbd17ab84b07ca940115a280d3f8d78, 0 behind. Fix branch compares 14 commits ahead of backend baseline, 0 behind.
- Current work branch head + full SHA: 85a8be9534f5739f732c6ee6f25b4b8225eaf5f3
- Source archive + SHA-256: no source archive used; GitHub source was fetched by exact branch/ref and verified by blob SHAs.
- Build workflow + trigger:
  - .github/workflows/test-db-android-core.yml; run 43755729409 — success
  - .github/workflows/package-db-android-api-fix.yml; run 43755729458 — success
- App/EXE version, package ID, version code: not applicable; server-only hotfix, no app build requested or produced.
- Artifact: ANI-GAMES-READY-DB-ANDROID-API-FIX-20261116.zip; artifact ID 14177929336; size 3,903 bytes; SHA-256 c7d11bf7e376506d0ed816a07cdc738d73009304ed7c145bf0371719a6b1dd07.

## What was inspected

- Live repo branch ancestry and source baseline.
- db-android-core/server/server.mjs and all 49 Node RPC allowlist entries.
- PostgreSQL schema migrations 002–011, especially token-bound Admin wrappers in 009_admin_db1_business_routines.sql; migration 001 remains reference-only.
- Node Auth handler, prefix normalization, Admin Billing RPC calls, API smoke test harness and local-stage workflows.
- Termux start-stage.sh / stop-stage.sh / status-stage.sh; stop-stage.sh checks PID working directory and command line before stopping only the stage API.
- The local Termux source differs from GitHub baseline; earlier user-supplied source snippets confirmed local net import and ANI_EDGE_PROXY_SECRET additions. Patch fixture explicitly verifies these are preserved.
- The local stage database backup was known readable by pg_restore --list; no restore test occurred in this hotfix.

## Changes made

| File | Change | Reason |
|---|---|---|
| db-android-core/server/server.mjs | Pass normalized path to Auth handler; enforce path-boundary prefix; bind dashboard_billing_user using the correct nine ordered argument types | Fix AUTH_ROUTE_NOT_FOUND on legacy Auth route and Admin Billing RPC bind/type failure |
| db-android-core/server/api-smoke.mjs | Test direct/prefixed Auth responses and Billing Admin create/list/update/delete through Node HTTP RPC | Add end-to-end regression for both defects |
| db-android-core/server/contract-check.mjs | Check all 49 RPC SQL bind counts, explicit casts, PostgreSQL function overload parameter order and types | Prevent another count-only false pass |
| .github/workflows/test-db-android-core.yml | Run contract checker on the isolated branch; include hotfix branch in CI | Run static contract audit in regression workflow |
| db-android-core/patches/APPLY_DB_ANDROID_API_FIX.sh | Guarded, backup-first, atomic server-only patch for existing Redmi stage source | Preserve local differences and avoid whole-file overwrite |
| db-android-core/patches/CHECK_DB_ANDROID_API_FIX.sh | Read-only source, health and Auth route checker | Verify update without creating users/sessions/rentals |
| .github/workflows/package-db-android-api-fix.yml | Shell syntax checks, local modified-source fixture, idempotence/preservation checks, patch artifact | Produce a safe Termux patch package |

## Verification

- Static/RPC contract: PASS for 49 entries (count, argument order, explicit cast types, matching PostgreSQL overload).
- PostgreSQL schema/function and SQL regression: PASS on fresh disposable CI PostgreSQL.
- Node API startup: PASS; stage installer and localhost:8788 smoke: PASS in CI.
- API role restricted access: PASS; HTTP smoke using restricted role: PASS.
- Auth direct route: expected HTTP 401 AUTH_REQUIRED without token: PASS.
- Legacy-prefixed Auth route: expected HTTP 401 AUTH_REQUIRED without token: PASS.
- Admin Billing User create/list/update/delete through Node HTTP RPC: PASS.
- Existing PC pairing, heartbeat, rental/session, billing/reseller, Admin, device and command regression suite: PASS in workflow 43755729409.
- Patch package validation: PASS; bash -n both scripts.
- Patch fixture: PASS; applied twice (idempotence), preserves local net import and ANI_EDGE_PROXY_SECRET markers, corrects Auth route and exact SQL cast ordering.
- Artifact SHA-256 and archive contents: verified locally.
- Actual Redmi patch install, actual Android Admin UI CRUD and physical client connection tests: NOT RUN; no remote execution access to the phone.
- Existing Redmi backup restore: NOT RUN. Database and schema on the phone were not touched.

## Risks / blockers

- The patch has not yet been executed on the Redmi. It is a guarded update that aborts if expected local source patterns are missing or ambiguous. It creates a timestamped backup before replacing server.mjs.
- Stage API is still configured for 127.0.0.1:8788 and reports remote_access_enabled:false. External access from arbitrary networks is not established. Without third-party relay, reachable public IPv4 and ISP/router forwarding are required; CGNAT prevents direct inbound connections.
- PostgreSQL port 5432 must remain private.
- The package does not import production rental/admin data and does not change client apps.
- The known stage DB backup is readable but not restore-tested.

## Rollback

- Patch backup is created beside server.mjs as server.mjs.backup-api-fix-YYYYMMDD-HHMMSS.
- To roll back after a device patch: use the stage-only stop-stage.sh (which PID-validates the stage process), copy the desired timestamped backup over server/server.mjs, then use start-stage.sh. Do not stop PostgreSQL or the separate port 8787 service.
- Git rollback: revert only the fix branch commits if needed; do not merge into or reset backend/master.

## Next action

1. Download and extract the artifact on Redmi/Termux.
2. Run: bash APPLY_DB_ANDROID_API_FIX.sh ~/ani-games-db-android-stage
3. Restart only staging API: bash ~/ani-games-db-android-stage/stop-stage.sh, then bash ~/ani-games-db-android-stage/start-stage.sh.
4. Run: bash CHECK_DB_ANDROID_API_FIX.sh ~/ani-games-db-android-stage
5. Share only the checker output (no .env or credentials). After that, test Billing Admin UI CRUD and plan direct public ingress if ISP provides a reachable public IPv4.

## User-facing summary

Two real API defects are fixed on an isolated GitHub branch and the full synthetic PostgreSQL/API CI passed. A tested server-only Termux patch ZIP is available. The user's Redmi DB and existing 8787/WoL services have not been changed by this work; one on-device apply/restart/check step remains. Public access from any network remains off until a safe direct network path is verified.
