# Next Tasks


## Priority 0 — Redmi DB Android API hotfix rollout

- [x] Revalidate the authoritative backend source at d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9 and create an isolated fix branch.
- [x] Fix Auth compatibility routing so the normalized /functions/v1/ani-games-api prefix reaches the correct Auth handler.
- [x] Fix the nine-argument dashboard_billing_user binding, including the text role and UUID organization type order.
- [x] Add a static check for all 49 Node RPC parameter counts, order and types.
- [x] Add HTTP regressions for direct/prefixed Auth and Billing Admin account create/list/update/delete.
- [x] Pass the full PostgreSQL/API CI regression on the restricted DB role; run 43755729409.
- [x] Build the Termux-only patch package and pass shell/fixture/idempotence/local-extension-preservation tests; run 43755729458.
- [x] Verify final patch ZIP SHA-256: c7d11bf7e376506d0ed816a07cdc738d73009304ed7c145bf0371719a6b1dd07.
- [ ] Apply APPLY_DB_ANDROID_API_FIX.sh to the existing ~/ani-games-db-android-stage only; let it create the server.mjs backup.
- [ ] Restart only the stage API with the guarded stop-stage.sh then start-stage.sh scripts; ensure port 8787, PostgreSQL data and WoL relay remain online.
- [ ] Run CHECK_DB_ANDROID_API_FIX.sh and verify health plus direct and legacy-prefixed Auth responses return 401 AUTH_REQUIRED without creating sessions.
- [ ] Verify Admin Billing Control account create/list/update/delete from the Admin interface against stage.
- [ ] Keep API loopback-only until direct internet reachability without a third-party relay is proven. Verify ISP public IPv4 and router forwarding/CGNAT status first; never expose PostgreSQL 5432.


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

## Priority 0 — DB Android Cloudflare stage connectivity
- [x] Revalidate isolated gateway branch ancestry and newest head before changing the runner.
- [x] Patch the Termux runner to expose DNS via `termux-chroot`, install missing support packages, preflight Cloudflare SRV DNS, and validate public API `/health`.
- [x] Pass GitHub Actions Worker/security, isolated API patch/syntax, shell syntax, DNS runner assertions and secret-free package build.
- [ ] User stops the old reconnect loop, installs the new stage helper package while preserving `online-secrets.env`, and starts the updated runner.
- [ ] Verify on Redmi that SRV DNS resolves, Quick Tunnel stays alive, Worker registry is active, and public `/health` returns the staging API response.
- [ ] Only after those tests pass, continue with named/stable tunnel planning; Quick Tunnel remains test-only and is not a 24/7 production solution.

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

 
## Priority 0 — Admin login + DB Android global access (target: Sunday 2026-11-22)

### Verified so far
- [x] Capture the user's Admin screenshot and identify the configured endpoint 127.0.0.1:8788 plus Failed to fetch before login.
- [x] Confirm the latest Admin candidate branch and reject the divergent login-click branch.
- [x] Audit the deployed Cloudflare Worker, secret binding names, KV namespace and current upstream state without reading secret values.
- [x] Confirm that the Worker is deployed but its Redmi upstream KV key is absent; no named Cloudflare Tunnel or zone is configured in this account.
- [x] Create an isolated gateway branch based on current API-fix branch, not the diverged old gateway branch.
- [x] Add Admin API fetch diagnostic/preflight-reduction patch and connect it to the dedicated V12.1.51 build workflow.
- [x] Record the 2026-11-22 target and acceptance matrix in project state.

### Still required — complete in this order
- [ ] Verify GitHub Actions status for Admin V12.1.51 and gateway branch; fetch logs and artifacts. Do not install an APK unless version/package/commit/checksum are verified.
- [ ] Run static regression on the Admin patch against the actual extracted source pages; validate JavaScript in all three Admin WebViews and Android manifest/network security policy.
- [ ] Review MainActivity.java WebView origin policy. Confirm the app actually presents the expected Origin: null; the Worker rejects any non-opaque browser origin. Adjust only through a narrow, tested origin policy if needed.
- [ ] Build both workflow outputs: AniGames-Admin-DB-Android-V12.1.51.apk (com.anigames.billingadmin.v150db) and AniGames-Admin-DB-Android-V12.1.51-SAFE-TEST.apk (com.anigames.billingadmin.v150dbtest). The safe-test package is for side-by-side validation without replacing the current installed Admin. Verify both APKs, versionCode 79, signature, size, commit provenance and SHA-256; install safe-test first.
- [ ] User installs/replaces the APK on Android while keeping the prior Admin APK as rollback; test server health, Admin username/password login, token refresh, dashboard load, Admin Billing User CRUD and role boundary.
- [ ] Recheck Redmi Termux stage API/DB using a sanitized health response. If the API is down, use only the existing stage start/stop scripts and verify port 8787 remains untouched.
- [ ] Complete the gateway branch CI, including worker tests, clean API patch, synthetic Redmi-local additions (net import and ANI_EDGE_PROXY_SECRET), idempotence, Node syntax, shell syntax and runner smoke test. Fix failures before packaging.
- [ ] Build a secret-free Termux gateway ZIP from the verified gateway branch. Confirm exact ZIP filename, contents, README commands, checksums, no .env, token, password, private key or DB data.
- [ ] On Redmi only, verify presence of required gateway secret variable names without printing their values. If they are absent/mismatched, configure them privately using the package instructions; never paste secrets into chat or GitHub.
- [ ] Apply gateway configuration to ~/ani-games-db-android-stage only after CI/artifact checks. Require timestamped backups of .env and server.mjs, verify API remains 127.0.0.1:8788, then restart only the staging API if needed.
- [ ] Start the Quick Tunnel runner; verify Worker registry health and public /health returns HTTP 200 with both api:online and database:online. Current upstream is absent, so public access remains offline until this passes.
- [ ] Enter the HTTPS Worker URL in the Admin APK Server Address. Test login from cellular data and Wi-Fi (the same HTTPS gateway works over either internet connection after the origin tunnel is active).
- [ ] Add separate direct LAN access only if required: design a private-LAN listener and explicit ANI_ALLOWED_ORIGINS/host checks independently. Never use an unreviewed 0.0.0.0 bind or expose PostgreSQL 5432.
- [ ] Test 24-hour operational behavior: screen off, Doze/battery restrictions, network handover, Termux process recovery, phone reboot, runner reconnect, Worker upstream expiry/refresh. Record real results; don't promise 24/7 from an Android phone until these pass.
- [ ] Test failure/rollback: stop tunnel (only tunnel), verify API local health persists, restore last server file/.env backups if patch failure occurs, and prove port 8787/DB data/WoL relay are unchanged.
- [ ] Final acceptance report: Admin login success, HTTPS public health, mobile-network login, Wi-Fi test, role/RPC checks, hashes and rollback proof.

### Hard safety gates
- [ ] Never expose TCP 5432 or database credentials.
- [ ] Never set API bind to 0.0.0.0 just to get login working.
- [ ] Do not edit/stop main service port 8787, production DB, Supabase DB1/DB2 or Blynk/WoL relay.
- [ ] No SQL migration, data reset, initdb, restore or destructive sync in this task.
- [ ] Mark done only after the device acceptance tests above pass; GitHub CI alone is not runtime acceptance.


### Latest device result — 2026-11-16 09:45 WIB
- [x] User rechecked `127.0.0.1:8788/health`; it returned curl error 7 / connection refused.
- [ ] Start only the staging API using the previously verified `~/ani-games-db-android-stage/start-stage.sh`.
- [ ] Recheck stage `/health`; determine API and database status separately. Do not infer DB down from API connection refused.
- [ ] Do not alter port 8787 or run DB initialization/migrations.

## Priority 1.5 — DB Android WebSocket relay stage (2026-11-16)

### Completed (source/deploy)
- [x] Stop repeating native Cloudflared Go DNS resolver and PRoot/termux-chroot workaround; confirm DB/API local health separately.
- [x] Create isolated branch infra/db-android-ws-relay-stage-20261116 from verified gateway stage parent 388fe1808a32ac13ffeeeae6fff49cbef8e7f177.
- [x] Implement outbound Node.js WSS relay agent and Worker/SQLite Durable Object hub; keep API 8788 and PostgreSQL 5432 loopback-only.
- [x] Deploy new Worker and SQLite DO namespace; enable workers.dev and disable previews.
- [x] Run local 12-test regression suite and syntax checks; GitHub CI run 43831355655 PASS.
- [x] Prepare secret-free Redmi installer/source archives.

### Remaining — do not skip
- [ ] In Cloudflare Dashboard, add Worker Secret named RELAY_SHARED_SECRET on ani-games-db-android-stage-ws-relay. Use the private temporary copy of the existing ANI_EDGE_PROXY_SECRET created by the Redmi installer; never paste it into chat or GitHub.
- [ ] User downloads and runs the installer ZIP on Redmi; verify it creates a timestamped .env backup, adds only ANI_DB_RELAY_URL, and leaves API 8788/PostgreSQL/main API 8787 unchanged.
- [ ] Start start-relay.sh; run status-relay.sh; inspect sanitized log if needed.
- [ ] Require public /_relay/health HTTP 200 with relay=online, agent_connected=true, api=online, database=online. Worker deployment/secret configuration alone does not mean the Redmi is connected.
- [ ] Test Auth and all used RPC/device API paths against allowlist; test body limits, disconnect/reconnect, concurrent requests, OPTIONS, 204 logout and origin restrictions on device.
- [ ] Only after relay health and route tests pass, adjust the isolated Admin DB Android candidate API base URL and run clean install + login + Admin CRUD on Wi-Fi and cellular. Do not modify or release the stable Admin APK prematurely.
- [ ] Monitor 24-hour behavior, screen-off/Doze, network handover, Termux process recovery and reboot. Keep status as STAGING until these pass.

### Hard boundaries
- [ ] Do not expose TCP 5432 or set API bind to 0.0.0.0.
- [ ] Do not change main port 8787, production data, Supabase DB1/DB2, or Blynk/WoL relay.
- [ ] Do not run SQL migration/initdb/restore/reset or copy rental data.

 
## Priority 0 — Admin DB Android V12.1.53 device acceptance (latest candidate)

The V12.1.53 branch supersedes the earlier V12.1.51/V12.1.52 APK candidates. Do not install or use V12.1.52 as the latest candidate.

### Completed
- [x] Continue from the verified V12.1.51 Admin DB Android login-gate branch and create isolated `fix/admin-db-android-clean-single-db-v1.53`.
- [x] Set the dedicated Redmi WebSocket Worker HTTPS URL as default in Admin, login and Billing Control pages; retain the manual URL override.
- [x] Physically remove the DB1/DB2 top bar, Database & Sync tab/section, sync/preflight UI, route state/stubs and DB2-only status copy from the Admin page.
- [x] Keep the Admin auth/API adapter single-database; verify no direct `sb.from(` Admin table access.
- [x] Keep Supabase only for the independent Blynk/WoL relay sidecar with explicit `RELAY_SUPABASE_*` naming.
- [x] Pass static core Admin feature checks and JavaScript syntax checks across all 3 WebView pages.
- [x] Pass GitHub Actions run 43879706639; build/verify main APK and side-by-side safe-test APK, package IDs, versionCode 81, v2 signatures and ZIP integrity.
- [x] Verify final artifact checksums and record handover `handovers/2026-11-16-admin-db-android-v12.1.53.md`.

### Remaining — exact order
- [ ] User installs `AniGames-Admin-DB-Android-V12.1.53.apk` as a separate app; keep the stable Admin APK installed as rollback.
- [ ] Confirm Termux DB Android stage API 8788, PostgreSQL and outbound WSS relay are still running using sanitized health/status output. Do not restart or edit port 8787.
- [ ] Test a valid existing Admin account login through the HTTPS Worker gateway; validate token refresh, logout, dashboard and server-derived role/org access. The prior empty-body test returning 401 INVALID_CREDENTIALS is not a valid-login test.
- [ ] Test Admin device/PC list and status, recovery enrollment, alerts, rental list/create/edit/disable/delete, active-session restrictions, PC command dispatch/status, detailed/monthly/yearly/per-PC reports and Excel/PDF export.
- [ ] Test independent WoL relay authentication, status/probe and action; confirm DB Android service controls do not stop or alter WoL relay.
- [ ] Test the app on Wi-Fi and cellular data, screen-off/reconnect and app relaunch. Record exact failures; do not declare operational acceptance until these pass.
- [ ] If the APK fails to sign in, capture the redacted error and inspect the API/Worker path; never request passwords, refresh tokens or secret values in chat.

### Safety boundaries
- [ ] Keep `com.anigames.billingadmin.v150db` separate from the stable Admin package.
- [ ] Do not merge the branch or distribute as a production-signed release without separate release-signing/build approval.
- [ ] Do not change the Redmi .env, DB schema/data, PostgreSQL, port 8787, production Supabase routes or WoL relay during APK acceptance.
- [ ] No SQL migration, initdb, restore, reset, destructive sync or public PostgreSQL exposure.


## Priority 0 — Complete Redmi DB Android Owner bootstrap after ADMIN_BOOTSTRAP_DENIED

### Completed in source/CI
- [x] Read the current stage API handler, installer, SQL bootstrap function and related runtime guard scripts on the exact active relay branch.
- [x] Identify the source-level failure path: bootstrap SQL rejects a missing, consumed or stale singleton token hash; installer seed uses `ON CONFLICT DO NOTHING` and cannot repair an old hash.
- [x] Create isolated branch `fix/db-android-stage-bootstrap-recovery-20261116` from the current relay stage head; preserve master and original relay branch.
- [x] Add guarded Termux helper that validates local staging identity, no active Owner, unconsumed bootstrap, current PID/health, repairs only the safe token hash and proves POST acceptance with intentionally invalid input.
- [x] Add four mocked safety regression cases, Bash syntax/security checks and pass GitHub Actions run 43896105470.
- [x] Package helper, Indonesian instructions, tests and checksums; verify ZIP integrity and SHA-256.

### Remaining on Redmi — execute in order
- [ ] Keep Termux API staging online; run `bash ~/ani-games-db-android-stage/start-stage.sh`.
- [ ] Download and run the helper from the isolated branch (instructions in `BOOTSTRAP-RECOVERY-ID.md`); inspect the final output. If it stops on Owner already exists or bootstrap consumed, do not reset DB; report only the sanitized error.
- [ ] Require helper result `BERHASIL` and safe probe result `ADMIN_BOOTSTRAP_INPUT_INVALID`; this proves the POST token gate without making a user.
- [ ] On Chrome on the Redmi itself, open `http://127.0.0.1:8788/setup` and create the first Owner with private credentials (password minimum 12 chars). Never send password/token/.env to chat.
- [ ] Login Admin DB Android V12.1.53 using the new username/password. Confirm the correct HTTPS Worker server setting and valid login response.
- [ ] Test Admin dashboard, organization/role context, rental create/edit/disable/delete, PC list/status, PC command/ack, reports and theme save; verify relay/WoL remains independent.
- [ ] Return sanitized helper output and Admin login result. Do not mark operational acceptance until on-device tests pass.

### Hard boundaries
- [ ] Never rerun `setup-stage.sh` as a repair, reset the staging DB, run migrations or modify owner/bootstrap rows manually.
- [ ] Do not stop PostgreSQL or main API port 8787; helper can restart only the identified stage API 8788 when its environment is stale.
- [ ] Do not touch Supabase DB1/DB2, public PostgreSQL exposure, Worker/DO relay or Blynk/WoL configuration.

## Priority 0 — Repair Redmi WebSocket agent startup (2026-11-17 incident)

- [ ] Obtain the full installed start-relay-stage.sh and related installer/status scripts from Redmi using a redacted read-only command; never output .env contents or secret values.
- [ ] Reconcile the installed ZIP's file hashes/provenance against the authoritative relay branch and documented final Termux package before editing. Do not assume the separate conversational ZIP is identical to the repository artifact.
- [ ] Fix the invalid parameter-length expression in an isolated branch/package; retain the existing ANI_EDGE_PROXY_SECRET, Worker RELAY_SHARED_SECRET binding, and API/database state.
- [ ] Runtime-test the exact scripts under Bash with absent, empty, valid-placeholder and short-placeholder secret variables; test extracted package layout, start/status/stop behavior, syntax, idempotence and secret-redaction.
- [ ] Only after package tests pass, provide one corrected package/one-time patch for Redmi. Verify agent process and WebSocket registration; require Worker /_relay/health HTTP 200 with agent_connected:true, api:online, database:online.
- [ ] If WebSocket handshake returns unauthorized, then privately compare local ANI_EDGE_PROXY_SECRET and existing Cloudflare RELAY_SHARED_SECRET; do not print either value or regenerate it.
- [ ] Preserve API 8788, PostgreSQL 5432, main API 8787, existing rental data, Supabase and the separate Blynk/WoL relay. No resets, migrations or unrelated restarts.

## Priority 0 — Admin V12.1.53 login acceptance after relay became online

- [ ] Keep the currently running Redmi relay agent (PID 12950) alive; do not re-install or rotate secrets.
- [ ] Verify the installed APK is AniGames Admin V12.1.53 DB Android, package com.anigames.billingadmin.v150db, versionCode 81. If absent, use the successful workflow artifact from run 43879706639.
- [ ] On the login screen, verify the saved Alamat Gateway DB Android is https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev; an old saved loopback URL can override the APK's baked default. Save the URL and require the app's health status to show the DB Android server is connected.
- [x] User confirmed successful login with the existing Owner/Admin account through the Redmi HTTPS Worker gateway on 2026-11-17. Credentials were not shared in chat.
- [ ] Validate role/organization context and load the dashboard and PC list read-only. Do not start with rental edits, deletes, power commands or WoL.
- [ ] On failure, capture only the sanitized error screen and distinguish fetch/CORS, HTTP/auth, INVALID_CREDENTIALS and role errors; never ask for a password or secret.
- [ ] Keep API 8788, PostgreSQL 5432, port 8787, rental data, Supabase and Blynk/WoL relay unchanged.
- [ ] Mark Admin login accepted only after the valid login, correct role context and dashboard load pass on the device.

## Priority 0 — Install and accept DB Android one-touch controller on Redmi

- [ ] Download `ANI-GAMES-READY-DB-ANDROID-CONTROL-1.0.0.zip` and run the installer from Termux; installer performs file setup only and does not start/stop services.
- [ ] Run `bash ~/ani-games-db-control/ani-db-control.sh status` first and review PostgreSQL, API 8788, WSS agent, Worker and legacy 8787 status.
- [ ] Run `bash ~/ani-games-db-control/ani-db-control.sh start`; require PostgreSQL ONLINE, API 8788 api/database online, agent ONLINE, Worker HTTP 200 and agent_connected=true.
- [ ] Test normal `stop`; verify agent and API 8788 stop while PostgreSQL remains online and legacy 8787 remains untouched.
- [ ] Test `full-stop` only when no other application is using the PostgreSQL cluster; require typed confirmation and verify safety guards. Do not override a blocked shutdown.
- [ ] If Termux:Widget is installed from a source compatible with the installed Termux app, add the four `~/.shortcuts` scripts as a Home Screen widget; otherwise continue using the one-command Termux menu.
- [ ] Re-run ON after OFF and verify Admin V12.1.53 login still works. Do not claim phone-side acceptance until these device checks pass.

## Priority 1 — Continue DB Android client rollout after control acceptance

- [ ] Re-audit latest PC Billing V12.4.8 DB Android branch/artifact and API contract before integrating it with the Redmi local DB Android backend.
- [ ] After PC Billing passes pairing, heartbeat, rental lookup, session start/end, sync and offline-queue tests, audit the latest Reseller DB Android branch and map reseller-only CRUD/auth flows.
- [ ] Preserve the stable PC Billing/Admin/Reseller builds and separate Blynk/WoL relay. No production cutover or data migration without backup/restore proof and explicit approval.
