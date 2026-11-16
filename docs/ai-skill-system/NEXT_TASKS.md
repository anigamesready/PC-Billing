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
- [ ] Build final AniGames-Admin-DB-Android-V12.1.51.apk on the dedicated workflow, verify package ID com.anigames.billingadmin.v150db, versionCode 79, signature, size, commit provenance and SHA-256.
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
