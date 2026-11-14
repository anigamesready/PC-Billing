# Next Tasks

## Priority 0 — Activate BOTH workflow
- [x] Read current `AGENTS.md`, Master Skill, project state/registry/decisions/backlog/changelog/version ledger and relevant modular Skills from GitHub in this chat.
- [x] Verify connected GitHub repository read access for this conversation.
- [x] Verify documentation updates can be committed to the dedicated Skill System branch without merging or touching runtime source.
- [ ] User confirms ChatGPT Project creation and Project Instructions installation, if Projects is available.
- [ ] Run and record a fresh-chat activation test from inside that Project. Current chat activation does not independently prove Project-level instructions were installed.

## Priority 0 — PC Billing V12.4.9 DB1-direct live validation
- [x] Rebase recovery work on the verified V12.4.8 Windows build source; keep PC DB Android/Redmi adapter separate.
- [x] Remove PC client DB1/DB2 route resolution and shared-gateway selection from the device request transport.
- [x] Preserve the Electron appId and legacy productName/userData folder while advancing runtime/package version to V12.4.9.
- [x] Build and verify the Windows portable EXE and clean source archive from GitHub Actions.
- [ ] User replaces the running PC Billing executable while keeping the previous EXE as rollback.
- [ ] Verify saved pairing token is still present, then confirm heartbeat reports ONLINE on DB1.
- [ ] Test rental lookup, rental session start/end, heartbeat, command ack, sync/pull and local outbox against DB1 using an actual paired PC.
- [ ] Only after these pass, mark the recovery build operationally accepted; do not merge to master without separate approval.

## Priority 1 — Redmi DB Android server/API contract
- [ ] Obtain current sanitized read-only inventory/source of Termux project `~/ani-games-server`; do not include .env, passwords, tokens, private keys, database dumps or backups.
- [ ] Revalidate current Termux working directory, Node version, PostgreSQL/API process state, port 8787, health response, control script and startup behavior.
- [ ] Inventory every API route, request/response shape, authentication middleware, role/org checks, rate limit and error behavior.
- [ ] Inspect actual database schema and compare it to the 24-table core business schema; identify applied migrations and schema version without changing the live DB.
- [ ] Audit backup automation, checksum verification, retention, off-device copy and a demonstrated restore to a separate staging database.
- [ ] Map PC Billing routes: enrollment/recovery, device token, heartbeat/watchdog, command poll/ack, sync cursor/pull, rental lookup, session start/end/release, offline leases and conflict queue.
- [ ] Map Admin routes: login/context/session revoke, PC status/recovery, alerts, global rental CRUD, command dispatch/ack, daily/monthly/yearly/per-PC reports and Excel/PDF exports.
- [ ] Map Reseller routes: token login/session expiry, reseller-only rental CRUD, ACTIVE/DISABLE/EXPIRED states and active-session/offline-lease delete guards.
- [ ] Define versioned API contract, idempotency rules, transaction boundaries, audit events, role isolation and staging test matrix.
- [ ] Do not port client apps or apply schema to the existing Redmi DB until server/API/auth/backup/restore contract is accepted.

## Priority 2 — Client DB Android migration planning
- [ ] PC Billing: map pairing, heartbeat, commands, rental sync, session lifecycle, offline leases, conflict queue, timer and WoL/Blynk behavior.
- [ ] Admin V12.1.50: map login/context, role gates, PC status/recovery, alerts, rental CRUD, command lifecycle, reports/exports and separate WoL relay behavior.
- [ ] Reseller V1.0.6: map login/session, own-rental CRUD, status lifecycle and active-session/offline-lease delete safeguards.
- [ ] Replace remembered-password plaintext localStorage behavior with revocable short-lived session handling and Android secure storage where feasible.
- [ ] Create a fresh-install/upgrade regression matrix for each client.

## Priority 3 — Build and release discipline
- [ ] Confirm dedicated DB Android build workflows and push filters; do not reuse Supabase workflows as DB Android proof.
- [ ] Add artifact provenance: commit SHA, source archive SHA-256, patch list, app version, package ID, workflow run, artifact SHA-256.
- [ ] Run syntax/build/regression tests before producing each candidate.
- [ ] Test clean install and upgrade/replace path before release.
- [ ] Keep master branches and stable artifacts untouched.

## Done only when
- API contract is implemented and tested in staging;
- authentication and role isolation pass;
- automated backup and restore are demonstrated;
- all three clients pass relevant regression tests;
- artifact provenance is recorded;
- production cutover has separate explicit approval and rollback plan.
