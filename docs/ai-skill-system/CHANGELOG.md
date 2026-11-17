# Changelog

## 2026-11-17 — Termux WebSocket agent startup incident and prevention

- User-reported execution of the delivered relay-agent package failed at start-relay-stage.sh:32 with Bash bad substitution on \${#ANI_EDGE_PROXY_SECRET:-0}. This is a confirmed script defect; the agent start script exited before the WebSocket connection attempt.
- The resulting local agent status was OFFLINE and Worker /_relay/health returned HTTP 503 with agent_connected:false. This confirms no agent was registered at that time; it does not establish a shared-secret mismatch.
- Local API 127.0.0.1:8788/health remained ONLINE with database ONLINE in the same user report. Do not restart PostgreSQL, API 8788, main API 8787, or the separate Blynk/WoL relay to repair this shell expansion.
- Cloudflare screenshot showed that a RELAY_SHARED_SECRET binding name already exists; the attempted Add flow correctly rejected a duplicate name. No new Cloudflare secret should be added. The deployed relay source documentation specifies reusing existing ANI_EDGE_PROXY_SECRET from the stage .env.
- Root cause for current connectivity failure: confirmed Bash expansion defect in the installed start script; exact package-to-repository provenance and remaining script behavior still require inspection. Secret value equality is unverified.
- Preventive updates: Developer Bug Fixer, Troubleshooting Engineer and Regression Tester Skills now require Termux Bash runtime tests (not only bash -n), variable-state fixtures, secret-preservation checks, and staged diagnosis of shell startup vs WebSocket auth vs Worker/API/DB health.
- No device script was patched, no secret value changed, and no Worker redeploy, SQL migration, database reset, API restart or port 8787 change was performed in this incident review. Device fix remains pending inspection of the sanitized installed script.

## 2026-11-16 — Redmi DB Android API contract hotfix

- Revalidated the backend baseline at d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9 (123 commits ahead of PC Billing DB Android source head f938c574dfbd17ab84b07ca940115a280d3f8d78, zero behind).
- Created isolated branch fix/db-android-core-api-contracts-20261116 at 85a8be9534f5739f732c6ee6f25b4b8225eaf5f3; 14 commits ahead of the backend baseline, zero behind. No master/backend baseline merge or production change.
- Fixed two API integration defects: legacy-prefixed Auth requests were routed using the original, non-normalized URL path; Admin dashboard_billing_user had an incorrect bind count and swapped role/org SQL types.
- Added 49-entry RPC contract validation for parameter count, order and types, and HTTP smoke tests for both Auth paths plus Billing Admin account CRUD.
- PostgreSQL/API regression run 43755729409 passed; package/fixture run 43755729458 passed. Fixture test applied the guarded Termux patch twice and confirmed that local net import and ANI_EDGE_PROXY_SECRET additions were preserved.
- Built artifact ANI-GAMES-READY-DB-ANDROID-API-FIX-20261116.zip, artifact ID 14177929336, size 3,903 bytes, SHA-256 c7d11bf7e376506d0ed816a07cdc738d73009304ed7c145bf0371719a6b1dd07.
- The package changes only stage server/server.mjs, creates a timestamped backup and performs no SQL migration or DB reset. It does not touch .env, PostgreSQL, port 8787 or WoL relay.
- Redmi patch application and post-restart device checks remain pending. Stage API is still loopback-only; access from arbitrary external networks is not claimed.


## 2026-11-15 — DB Android Cloudflare Termux DNS runner fix
- Revalidated the isolated stage branch against its baseline `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9`; branch head was 19 commits ahead and 0 behind.
- Root-cause evidence from Redmi: `cloudflared` tried `[::1]:53` and received connection refused; Termux resolver file existed under `$PREFIX/etc/resolv.conf`, while Android/Termux lacked the standard `/etc/resolv.conf` path.
- Updated the stage runner to install missing `proot`/`bind-tools`, execute the tunnel through `termux-chroot`, preflight the Cloudflare SRV record against public DNS, and test the actual public API `/health` after registration.
- Updated deployment documentation and CI package assertions. No Worker deployment, API source, DB schema/data, production route, port 8787, Supabase or Blynk/WoL resource was modified.
- GitHub Actions run `43689341047` succeeded; artifact `14151522874`, size 17,557 bytes, SHA-256 `84bf654ae73c4b2b6656df058d392c8c56260b3ec41cddea1c62713907018442`.
- Redmi application/runtime test is pending; do not mark global API connectivity as fixed until DNS preflight, tunnel persistence and public `/health` pass on-device.


## 2026-11-14 — PC Billing V12.4.9 DB1 Direct recovery build
- Created isolated recovery branch `recovery/pc-v12.4.9-db1-direct-20261114` from the verified V12.4.8 source baseline.
- Removed client-side `db-route-status`/DB2/shared-gateway route lookup from PC Billing device transport; all device requests now target DB1 `ani-games-api` directly.
- Preserved device token, local outbox, sync cursor, heartbeat, watchdog, rental/session/sync flows, timer sizing, fullscreen safety and manual Windows controls.
- Preserved Electron `appId` and legacy `productName` so existing `userData` location is not renamed; build output is V12.4.9.
- GitHub Actions run `43572350285` completed successfully; artifact `14104807189`; EXE SHA-256 `9B8171EC801229B3C0EE01F763D9037B33ABB7CDCBF38396F3BC8D83C1EB0807`.
- Clean source ZIP SHA-256 `7BEFCF83D4D542FE0F7FE92866E16B7BA29C1DE05E063927B89FBD43099C75F7`.
- Static/build tests passed. Live saved-token login, heartbeat and real rental session tests remain pending on a paired customer PC.
- No master branch, Admin APK, Reseller APK, DB1 data, DB2 project or production database configuration was changed.

## 2026-11-14 — BOTH activation and live repository re-audit
- Read the current GitHub entry rules, Master Skill, state, registry, decisions, next tasks, changelog, version ledger, setup guide and relevant project/database/handover/regression Skills.
- Verified the connected GitHub repository can be read in this chat.
- Revalidated live branches and found the previous registry stale: Admin DB Android candidate is now V12.1.50; Reseller DB Android branch head advanced to `62e14e8...`; a separate `backend/db-android-core-v1` schema/contract branch exists.
- Updated the registry and version ledger to the current exact full SHAs and recorded build-workflow exclusions.
- Reviewed DB1 contract audit: 41 tables, 161 routines, 116 triggers and 14 active Edge Functions; 24 operational-table schema is only a schema reference, not a complete Redmi API.
- Recorded the last user-reported Termux state and explicitly marked it as not live-verified in this chat.
- Created a task handover. No runtime source, SQL database, Supabase project, server process, APK/EXE, build workflow or production setting was changed.

## 2026-11-14 — Hybrid ChatGPT + GitHub setup
- Added `CHATGPT_SETUP.md` with ChatGPT Project instructions, start prompt, handover prompt, setup steps, capability boundaries, and manual activation test.
- Updated README, project state, and next tasks to record the BOTH workflow.
- ChatGPT-side Project setup remained pending user confirmation.
- Documentation-only changes; no runtime source, build workflow, APK/EXE, database, Supabase project, or production configuration changed.

## 2026-11-14 — Initial AI Skill System
- Audited current GitHub repositories and active DB Android branches for PC Billing, Admin, and Reseller.
- Identified legacy repositories and recorded why their default branches are not automatically authoritative.
- Created isolated documentation branch `docs/ani-games-ready-ai-skill-system` from PC Billing DB Android branch `f938c574dfbd17ab84b07ca940115a280d3f8d78`.
- Added master instructions, modular Skills, project registry/state/decisions, version ledger, next tasks, and handover template.
- No runtime source, build workflow, APK/EXE, database, Supabase project, or production configuration changed.

 
## 2026-11-16 — Admin login and DB Android global access audit
- User screenshot showed the Admin APK still defaults to http://127.0.0.1:8788 and displays Failed to fetch. Explained that loopback is the device running the APK, not a remote Redmi server; the message alone does not prove PostgreSQL is down.
- Confirmed historical user-reported stage health/API checker PASS after API contract patch; current Redmi state still requires a fresh Termux check.
- Revalidated Admin V12.1.50 source base at 3ebc8b1912aef13a4833f113c9e7a4914554b146. Created/continued isolated V12.1.51 work branch fix/admin-db-android-login-gate-v1.51, latest head 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5, 5 ahead/0 behind.
- Audited V12.1.51 missing setAdminAuthEnabled helper. Added a separate fetch reliability patch that removes unnecessary Content-Type on bodyless health GET and reports the attempted API origin when WebView fetch fails; wired into the dedicated APK workflow. This does not prove root cause or build success.
- Audited the deployed Worker and KV: stable workers.dev gateway exists, but upstream key is absent. No named Cloudflare tunnel or DNS zone exists in the account. Public API therefore remains offline pending Redmi tunnel registration.
- Rejected old gateway branch infra/db-android-cloudflare-gateway-stage as an install source because it diverges from the active API hotfix (49 ahead/17 behind).
- Created infra/db-android-cloudflare-global-stage-20261116 from current API hotfix base f16d97a3dfd96f2f3598396976c3ee5d63c60e6d; latest head 8c39f86410a3cd6b0ce3521029e689d63984752e, 10 ahead/0 behind. Added gateway source, compatibility-safe API patch logic and a CI synthetic fixture for the Redmi's existing net/edge-secret additions.
- Build/CI status and artifacts for these branches are not verified; no APK or Termux gateway ZIP was claimed delivered. No Redmi process, runtime .env, PostgreSQL, port 8787, production data, Supabase or Worker deployment was modified.
- Added an acceptance plan with target Sunday 2026-11-22; all on-device/global connectivity criteria remain open.


## 2026-11-16 09:45 WIB — Stage API not listening
- User's live Termux curl to `127.0.0.1:8788/health` returned curl error 7 (connection refused). Stage API is currently not accepting connections. This alone does not establish PostgreSQL status.
- No runtime restart or DB mutation was performed by assistant. Next step is to start only the stage API with the previously verified start-stage script and recheck health.

## 2026-11-16 — DB Android outbound WebSocket relay stage

- Replaced the repeated native Cloudflared DNS/PRoot approach with an isolated Node.js outbound WebSocket agent and Cloudflare Worker + SQLite Durable Object relay.
- Created work branch infra/db-android-ws-relay-stage-20261116 from exact stage parent 388fe1808a32ac13ffeeeae6fff49cbef8e7f177; latest branch head d86e7ecfa82d7af29bb53d067a316984b1fef69b. No master merge or stable product branch edits.
- Deployed Worker ani-games-db-android-stage-ws-relay on workers.dev with Durable Object class RelayHub, SQLite namespace d3deb95247764649a63e05aa94962c45, binding RELAY_HUB, migration v1.
- Added Worker route allowlist, opaque-origin CORS support, bootstrap/setup denial, request header filtering, client-IP forwarding under the existing local edge-trust contract, bounded payload/concurrency/timeouts and WebSocket health/reconnect design.
- Local tests: 12/12 PASS, Worker/agent Node syntax PASS, Termux shell syntax PASS. GitHub Actions run 43831355655 SUCCESS.
- Prepared final Termux ZIP ANI-GAMES-READY-DB-ANDROID-WS-RELAY-TERMUX-FINAL.zip SHA-256 e7b448b678819b3d811c3503dfdb04d90e1b7dbb54be98f9caad836acd633a95; source ZIP SHA-256 f67826e2031772d312d909758d552d517fb05cc6a3b5f36dd9051333c2cac1b2. Packages contain no secret values.
- The Worker's secret RELAY_SHARED_SECRET still requires manual setup in Cloudflare Dashboard because the automated secret-write action was blocked; Redmi agent is not yet installed or connected. Public health, API end-to-end, Admin APK login, cellular/Wi-Fi and 24-hour tests remain pending. This is not yet a completed public relay.
- No schema/SQL migration, database reset, PostgreSQL public bind, API main port 8787, Supabase DB1/DB2, Blynk/WoL or Admin APK changes were made.

## 2026-11-16 — Admin DB Android V12.1.53 clean single-DB build

- Revalidated isolated Admin lineage: V12.1.51 login gate at 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5; V12.1.53 work branch fix/admin-db-android-clean-single-db-v1.53 at 1177b018725822a671fe3a2b9b9facedf75240b7; 10 commits ahead / 0 behind the V12.1.51 baseline.
- Added V12.1.52 gateway default for all three app WebView pages and V12.1.53 physical removal of legacy DB1/DB2 selector, route-control and sync UI/state from Admin.
- Preserved local Admin auth/context, rental CRUD, PC commands, reports/theme and independent Blynk/WoL relay sidecar. Remaining Supabase variables are explicitly named RELAY_SUPABASE_* and no direct Supabase table access remains in Admin UI.
- Static single-DB/core-feature assertions and JavaScript syntax validation for Admin, login and Billing Control pages passed.
- GitHub Actions run 43879706639 succeeded. Main APK V12.1.53 (versionCode 81; applicationId com.anigames.billingadmin.v150db) and side-by-side safe-test APK (com.anigames.billingadmin.v150dbtest) built and v2 signature verified.
- Main APK: 734,881 bytes; SHA-256 3c436460229450b66cdd72752fc65c9d2a2a39e428cc156da0017cc0253dea28. Safe-test APK: 734,889 bytes; SHA-256 8e0cb141d634dcd9d9a79cc58eee1fa89ababfebb2c607f5f57d2f716882ea38.
- Artifact ID 14231274085, ZIP size 1,295,700 bytes, SHA-256 447a2c825ab8d0dd980f4ee74fece7823552f4a59ea3b1e85275d5931607e72a. The APKs use CI debug signing, not production release signing.
- User-reported point-in-time stage status before build showed the relay agent/Worker/API 8788/PostgreSQL online; port 8787 was separately closed. APK build did not change Redmi runtime, DB data/schema, .env, Supabase production or WoL relay.
- Device install, valid Admin login, authorization/role, rental CRUD, commands, reports, WoL and Wi-Fi/cellular tests remain pending. A 401 INVALID_CREDENTIALS response to an empty-body probe does not count as successful login.


## 2026-11-16 — DB Android Owner bootstrap recovery helper

- Diagnosed the `ADMIN_BOOTSTRAP_DENIED` path against the exact stage API and SQL source. The installer’s bootstrap-row insert uses `ON CONFLICT DO NOTHING`, so a pre-existing stale hash can persist. This remains the leading hypothesis pending local Redmi database verification.
- Added an isolated recovery helper and documentation branch based on the active WSS relay stage branch. The helper guards database identity, localhost binding, PID, health, existing Owner and consumed-bootstrap state; it repairs only an unconsumed bootstrap token hash and verifies with a no-account POST probe.
- Added four mocked regression cases (missing row, stale hash, active Owner, consumed bootstrap) and Bash syntax/security scans. GitHub Actions run 43896105470 SUCCESS.
- Packaged the helper without credentials or database material. ZIP SHA-256: 374b6b49b45f7cb706f069ca1467a9810a66483a1d8767bf228c93046e386287; ZIP integrity passed.
- No on-device changes have yet been made by this task. User must run the helper on Redmi, create the Owner account locally, and verify Admin V12.1.53 login. Existing PostgreSQL, main API 8787, Supabase DB1/DB2, Worker/relay and Blynk/WoL remain untouched.

## 2026-11-17 — Redmi WebSocket relay agent online (user-verified)

- User reported the fixed Termux start-relay-stage.sh now passes Bash syntax checks and the runtime secret fixture matrix (unset/empty/short rejected; 32-character dummy accepted).
- Device's private export was checked without revealing values: existing local ANI_EDGE_PROXY_SECRET is valid and matches the private relay-worker-shared-secret.txt copy; Worker URL matches the staging relay.
- Agent started successfully on Redmi with PID 12950. status-relay-stage.sh reported Local agent ONLINE.
- Local 127.0.0.1:8788/health returned api=online, database=online.
- Public Worker /_relay/health returned HTTP 200: relay=online, agent_connected=true, api=online, database=online.
- This is the first user-reported end-to-end relay transport acceptance. Keep the Termux agent running; do not re-run installer, rotate secrets, redeploy Worker, restart API/PostgreSQL, or touch main port 8787.
- Admin APK V12.1.53 remains a separate pending device test. The APK source/build must be re-verified before use; verify its saved API URL because a previously persisted localStorage value may override the newly baked default Worker URL.
- No Admin login success, dashboard authorization, rental CRUD or business-flow test is claimed yet.

## 2026-11-17 — DB Android one-touch Termux controller package 1.0.0

- Audited the live relay-stage branch `infra/db-android-ws-relay-stage-20261116` at `d86e7ecfa82d7af29bb53d067a316984b1fef69b` and exact `start-stage.sh`, `status-stage.sh`, `stop-stage.sh`, stage README, and WSS relay README. Confirmed stage API 8788 is separate from legacy 8787; WSS agent is a separate process; PostgreSQL 5432 is private and may host other database clients.
- Prepared `ANI-GAMES-READY-DB-ANDROID-CONTROL-1.0.0.zip` (11,168 bytes, SHA-256 `d3f51d6528695891bbf8e48f727e87a1ffd0d8e538877f66dbad19a71520aa04`).
- Added controller menu and four launcher scripts: DB-ANDROID-ON, DB-ANDROID-OFF, DB-ANDROID-FULL-OFF, DB-ANDROID-STATUS. Installer copies only the controller/shortcut scripts under the user's home; it does not edit `.env`, start/stop services, migrate SQL, or reset data.
- Safety behavior: ON starts existing PostgreSQL, then API 8788, then WSS agent and checks Worker HTTP 200. Normal OFF stops agent then API but keeps PostgreSQL running. FULL OFF asks for typed confirmation and only stops PostgreSQL if legacy 8787 and old-server process checks are clear and no other client backend remains in pg_stat_activity; uncertain states leave PostgreSQL ON.
- Regression evidence: bash syntax checks PASS; per-file SHA-256 checks PASS; ZIP integrity PASS; local mock runtime tests PASS for ON, normal OFF, safe FULL OFF, DB-session guard and legacy-8787 guard; installer simulation PASS in disposable HOME. No live Redmi service was changed in this work.
- Termux:Widget official documentation was checked. It can show executable scripts in `~/.shortcuts`; the user's Termux:Widget install/source and home-screen behavior remain to be accepted on the device.
- Admin DB Android V12.1.53 login was user-confirmed successful after the Worker/agent returned online. Dashboard feature acceptance and PC Billing/Reseller migration remain separate tasks.
