# Project State — 2026-11-16

## Current Skill System status
- Hybrid BOTH workflow is being used: GitHub is the permanent instruction/state source; ChatGPT reads the repository through the connected GitHub integration at task start.
- This chat successfully read the required Skill System documents and relevant Skills from `docs/ani-games-ready-ai-skill-system`.
- The connected GitHub repository was readable. Previous setup commits also demonstrated documentation-only updates on the dedicated docs branch.
- The user has not independently confirmed creation of a ChatGPT Project or pasting the Project Instructions. Do not claim Project-level setup is complete.
- No runtime source, database, APK/EXE, server, build workflow, or production configuration was changed in this activation/audit.

## Latest verified source tracks
- PC Billing DB Android: V12.4.8, branch `pc-billing-v12.4.8-DB-Android`, head `f938c574dfbd17ab84b07ca940115a280d3f8d78`, source baseline `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`.
- Admin DB Android: newer candidate V12.1.50, branch `admin-v12.1.50-DB-Android`, head `3ebc8b1912aef13a4833f113c9e7a4914554b146`, baseline `9460e8dcbdbf69706408dd0507016cf0037ff153`. V12.1.46 is retained as historical.
- Reseller DB Android: V1.0.6, branch `reseller-v1.0.6-DB-Android`, current head `62e14e8caea62c50269cd62f4122efeed19e8731`, source baseline `a67c2f6318230671a7d7776bf6040c39bca6ff97`.
- DB Android standalone backend: branch `backend/db-android-core-v1`, head `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9`. It contains the Node API, Auth/Admin/Billing/Reseller/Device routes, PostgreSQL schema/functions, Termux stage scripts and CI regression suite. Redmi installation still awaits the one-file hotfix and on-device verification.
- Full branch ancestry, workflow limitations and source warnings are recorded in `PROJECT_REGISTRY.md`.


## Redmi DB Android API contract hotfix — 2026-11-16

- User requested direct completion of the API audit/fix, while preserving stable source and the existing Redmi database.
- Repository: anigamesready/PC-Billing. Source baseline: backend/db-android-core-v1 / d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9 (verified ancestry from PC Billing DB Android head f938c574dfbd17ab84b07ca940115a280d3f8d78).
- Isolated work branch: fix/db-android-core-api-contracts-20261116 / 85a8be9534f5739f732c6ee6f25b4b8225eaf5f3. Comparison: 14 commits ahead, 0 behind. No merge to master and no modification to the backend baseline.
- Changes: normalize the Auth path before calling authRequest; enforce exact prefix boundary; correct dashboard_billing_user to nine arguments with the correct role/org type order; add HTTP smoke cases and a contract checker over all 49 Node RPC entries.
- CI: PostgreSQL/API regression run 43755729409 PASS. It applies schema 000 and 002–011 only to a disposable CI database, runs SQL smoke tests and Node HTTP smoke tests using a restricted DB role, then checks backup/restore and local stage startup. Billing Admin user CRUD over HTTP passed.
- Packaging: Termux fixture/package run 43755729458 PASS. It checks shell syntax, applies the patch twice to a temporary modified-source fixture (idempotence), confirms local net import and ANI_EDGE_PROXY_SECRET remain, and packages the two scripts plus README.
- Artifact: ANI-GAMES-READY-DB-ANDROID-API-FIX-20261116.zip; artifact ID 14177929336; SHA-256 c7d11bf7e376506d0ed816a07cdc738d73009304ed7c145bf0371719a6b1dd07; 3,903 bytes.
- Existing Redmi stage history: ~/ani-games-db-android-stage, DB ani_games_ready_stage, API port 8788 loopback; old port 8787 is separate. Previously reported backup ani_games_ready_stage-before-core-20261115-222016.dump has SHA-256 b16ca9199ea848839aeb989bb2d37d3372db56f3e05169572b695e29491f9c19 and was readable by pg_restore --list. It was not restore-tested.
- Local server.mjs has local additions not present in GitHub baseline (including net and ANI_EDGE_PROXY_SECRET), so the package uses a guarded pattern patch, not whole-file replacement. It creates a timestamped backup and aborts if expected patterns are not unique.
- No patch has yet been executed on the Redmi in this chat. No local DB, schema, .env, PostgreSQL, port 8787 or Blynk/WoL relay was changed. No migration, initdb, restore, reset or data copy was run.
- Public access: stage API still binds to 127.0.0.1:8788 and reports remote_access_enabled:false. It is intentionally not exposed. Access from arbitrary networks without a third-party relay remains open pending verification of reachable ISP public IPv4/router forwarding; PostgreSQL port 5432 must remain private.

## PC Billing DB1-direct recovery — 2026-11-14

- Recovery branch: `recovery/pc-v12.4.9-db1-direct-20261114`; exact head `0565a8a225793e8785ca17f9079a15b753a834f1`.
- Source baseline: official PC V12.4.8 build branch `fix/pc-v12.4.8-timer-size-sync`, commit `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`; the DB Android source branch was kept separate and its Redmi adapter was not applied to this DB1 recovery build.
- Final build: PC Billing V12.4.9 DB1 Direct, GitHub Actions run `43572350285` (`success`), artifact `14104807189`.
- Runtime: PC device transport is pinned to DB1 Edge Function `ani-games-api`; `resolveDbRoute`, `db-route-status`, DB2 reference and `shared-db-gateway` route selection removed from `v11-cloud.js`.
- DB1 `ani-games-api` was live-checked at version 36, ACTIVE, with direct handlers for enrollment, heartbeat, watchdog, ack, sync/pull, rental lookup, session start/end/release and test-policy.
- Compatibility: Electron `appId` remains `com.anigames.billing.v12test` and legacy `productName` remains `AniGames Billing V12.3.3` so the default `userData` path remains the same. Only package/runtime version is V12.4.9 and the portable EXE output filename is V12.4.9.
- Regression/build verification: existing V12.4.5–V12.4.8 patch chain passed; V12.4.9 patch passed; JS + inline script syntax passed; direct DB1/router static assertions passed; Windows portable EXE build and artifact upload passed.
- Artifacts: EXE SHA-256 `9B8171EC801229B3C0EE01F763D9037B33ABB7CDCBF38396F3BC8D83C1EB0807`; clean source ZIP SHA-256 `7BEFCF83D4D542FE0F7FE92866E16B7BA29C1DE05E063927B89FBD43099C75F7`; GitHub artifact ZIP SHA-256 `a645ae96002c28fbe7510e53cd4c91c317efa8c18c86f1463024a3bea0c479d7`.
- Not yet tested on a live customer PC: saved-token login/heartbeat, real rental start/end, and fresh replace/install. No backend DB data, Admin APK, Reseller APK, DB2 project, or master branch was changed.

## DB Android Cloudflare staging gateway DNS fix — 2026-11-15

- Dedicated infra branch: `infra/db-android-cloudflare-gateway-stage`; latest verified head after CI trigger: `693289ad16a380119bba981ecdde4e2d4453ad0e`.
- Branch ancestry: 19 commits ahead of exact stage baseline `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9`, zero behind at the time of verification. No master or production branch was changed.
- User-observed failure: public Worker `/health` returned HTTP 503 `STAGE_TUNNEL_OFFLINE`; Redmi cloudflared log showed Go DNS lookup to `[::1]:53` connection refused. Python `getaddrinfo` also failed. Termux `$PREFIX/etc/resolv.conf` was present with 8.8.8.8 and 8.8.4.4.
- Updated `db-android-core/cloudflare-gateway-stage/start-online.sh` to install missing Termux `proot` and `bind-tools`, run cloudflared through `termux-chroot` (which exposes Termux's resolver at `/etc/resolv.conf`), test the Cloudflare SRV record through 1.1.1.1/8.8.8.8, and verify the real public API `/health` path after Worker registry health.
- Updated stage deployment notes and CI assertions. Worker implementation/deployment, staging API code, port 8787, production DB, Supabase and Blynk/WoL were not changed by this DNS fix.
- Runtime runner commit: `143253184bca03b96ea5233ac2a76e61723b5cf5`; CI workflow commit/head: `693289ad16a380119bba981ecdde4e2d4453ad0e`.
- GitHub Actions run `43689341047` completed successfully. Package artifact ID `14151522874`; SHA-256 `84bf654ae73c4b2b6656df058d392c8c56260b3ec41cddea1c62713907018442`; size 17,557 bytes.
- The new package deliberately excludes `online-secrets.env`, runtime `.env`, passwords and database files. The existing local `online-secrets.env` must be copied forward when updating the helper folder.
- Not yet applied or tested on the Redmi. Until the new runner passes DNS preflight and public API `/health`, global API access remains unverified and the previous 503 is still the last user-observed public result.

## Redmi Termux server — reported main + DB Android stage state

- Existing main service: ~/ani-games-server, Server Control 1.0.2, Node.js v24.22.3, API port 8787. The last reported health check on 2026-11-13 showed PostgreSQL/API ONLINE; this service remains separate and was not stopped or modified in the current fix.
- Separate DB Android staging service: ~/ani-games-db-android-stage; database ani_games_ready_stage; Node API port 8788 bound to 127.0.0.1. The last observed /health response showed API and database online, remote_access_enabled:false, bind_host:127.0.0.1, relay:separate. This is historical observed state, not a live re-query of the phone.
- Stage PostgreSQL data directory was previously observed as $PREFIX/var/lib/postgresql, PostgreSQL 18, listening on 127.0.0.1:5432. Never expose port 5432.
- A pre-core backup exists at ~/ani-db-backup/ani_games_ready_stage-before-core-20261115-222016.dump; SHA-256 b16ca9199ea848839aeb989bb2d37d3372db56f3e05169572b695e29491f9c19; pg_restore --list succeeded. A restore test was not performed.
- The local stage server.mjs contains local additions (including net and ANI_EDGE_PROXY_SECRET) that differ from GitHub baseline. The delivered patch is guarded and preserves those additions; it has not yet been applied to the Redmi.
- No .env, passwords, tokens or database dumps were copied to GitHub or included in the patch artifact. No database reset, migration, initdb, restore or data copy was run by the hotfix.

## DB Android core implementation status

- The standalone GitHub backend now contains a Node HTTP API, local Auth/Admin/Billing/Reseller/Device routes, 108 API-schema functions, PostgreSQL schema/migrations 000 and 002–011, and a CI suite. Full PostgreSQL/API CI passed at hotfix HEAD; this validates the synthetic disposable CI database, not all client apps against the physical Redmi.
- The 24-table core schema is separate from the 41-table DB1 catalog snapshot. Migration 001_db1_catalog_snapshot.sql is reference-only and must not be applied.
- The local stage database was previously observed with 28 base tables. Seven tables held one row each for auth/admin bootstrap, organization/member, and audit setup; the operational rental/device/session tables were empty. It is not a clone/import of DB1 customer or rental data.
- Auth prefix routing and the Admin Billing User RPC bind order/type were fixed on the isolated branch fix/db-android-core-api-contracts-20261116. Device runtime tests, the on-device patch and UI-level Admin/Reseller/PC client acceptance remain pending.
- Keep Supabase DB1/DB2 route/sync infrastructure, route-quiesce/before-image triggers, WoL Relay/Telegram sidecars and automatic shutdown scheduler out of the local single-server runtime.

## Safety constraints
- Keep DB Android separate from Supabase DB1/DB2 dual-database development and production routes.
- Never expose PostgreSQL passwords, Supabase service-role keys, signing credentials or customer data in clients/docs.
- No production cutover, destructive sync or cross-database copy without explicit approval, dry-run, verified backup/restore, row-level parity, idempotency, audit and rollback.
- Do not reintroduce automatic shutdown countdown behavior.
- Reseller must remain limited to its own rentals; no Admin/Owner or PC/Windows/WoL control.

## Next action
1. Apply the guarded API hotfix to ~/ani-games-db-android-stage only, restart only stage port 8788 using its PID-validated stop/start scripts, then run the read-only checker.
2. Confirm stage Admin Billing CRUD from the Android Admin interface. Keep port 8787, PostgreSQL data and Blynk/WoL relay untouched.
3. After local acceptance, resolve direct public reachability without a third-party relay by checking ISP public IPv4/router forwarding versus CGNAT. Keep PostgreSQL 5432 private; no external ingress is configured yet.

 
## Admin APK login + DB Android global access — 2026-11-16 (priority deadline 2026-11-22)

### User-visible failure and verified meaning
- User screenshot shows the Admin APK API field set to http://127.0.0.1:8788 and the status message "Server database lokal belum siap: Failed to fetch" before login can proceed.
- 127.0.0.1 always means the device running the APK, not the Redmi server when the APK is installed on a different phone. The displayed error is a network-fetch failure; it does not, by itself, prove PostgreSQL is down.
- Earlier user-provided Termux output showed stage API and PostgreSQL online at 127.0.0.1:8788, remote_access_enabled:false, bind_host:127.0.0.1. This is prior evidence, not a live recheck of the Redmi on 2026-11-16.
- User had applied the API contract patch, restarted stage and ran CHECK_DB_ANDROID_API_FIX.sh: source assertions, API+database health, direct Auth and compatibility-prefixed Auth all returned PASS. That verifies local API contracts, not the APK WebView, remote reachability or public tunnel.

### Admin source candidate
- Repository: anigamesready/Admin-Ani-Games.
- Work branch: fix/admin-db-android-login-gate-v1.51, current audited head 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5; compare against admin-v12.1.50-DB-Android at 3ebc8b1912aef13a4833f113c9e7a4914554b146: 5 commits ahead, 0 behind.
- The other branch fix/admin-v12.1.50-db-android-login-click is diverged from the current V12.1.50 base and is not the release source.
- Existing V12.1.51 patch restores the missing setAdminAuthEnabled helper and identifies a candidate APK as version 12.1.51, versionCode 79, applicationId com.anigames.billingadmin.v150db.
- Added scripts/patch_admin_db_android_api_fetch_reliability.py and wired it into .github/workflows/build-db-android-admin-apk.yml. It changes bodyless GET health requests so they do not send an unnecessary JSON Content-Type preflight and turns generic fetch exceptions into an actionable API origin diagnostic. It preserves JSON Content-Type for requests with bodies and does not alter credentials/auth semantics.
- This helper is an additional diagnostic/reliability improvement, not proof of the screenshot root cause. No successful APK build/artifact or on-device login has been verified for this candidate in this task. CI status lookup returned no status rows; do not claim build success.

### Global access audit
- Cloudflare account has Worker ani-games-db-android-stage-gateway, public stable Worker URL https://ani-games-db-android-stage-gateway.anigamesready.workers.dev, Workers.dev enabled, KV namespace ani-games-db-android-stage-upstreams (ID 55b2907fc76242c99774413e9986187f). Worker deployment is present.
- Current KV upstream key ani_games_ready_stage:upstream is absent; its GET returned key-not-found. Cloudflare account returned zero named tunnels and zero zones/custom DNS zones. Therefore the Worker is deployed but the Redmi origin is NOT connected; internet access is not currently working.
- Existing Worker has allowlisted API routes, denies public /setup and /api/admin/bootstrap, accepts opaque Android WebView origin null, requires registration bearer token, and overwrites edge client-IP/secret headers before forwarding. The values of Worker secrets were not read or disclosed.
- Old gateway branch infra/db-android-cloudflare-gateway-stage is diverged from the installed API-fix branch (49 ahead, 17 behind); do not use its package directly.
- New isolated branch infra/db-android-cloudflare-global-stage-20261116 is based exactly on API fix head f16d97a3dfd96f2f3598396976c3ee5d63c60e6d. Current head 8c39f86410a3cd6b0ce3521029e689d63984752e; compare is 10 ahead, 0 behind. It ports gateway files only and hardens the API patch to reuse an existing local node:net import and ANI_EDGE_PROXY_SECRET declaration, avoiding duplicate JS declarations. CI result remains unverified.
- Current gateway path uses a Cloudflare Quick Tunnel registered behind the stable Worker URL. The origin URL is ephemeral and registration TTL is 600 seconds; the Termux runner refreshes it periodically and reconnects, but needs the Redmi, Termux, power, network and background execution to stay alive. It is a staging/availability proof, not a 24/7 SLA or a named stable tunnel.
- The Worker URL can be used over Wi-Fi or cellular once its upstream is active, but that path traverses the internet. Direct LAN-only access from another device still needs a separate safe LAN listener/origin configuration and explicit CORS/origin policy; do not point a different phone at 127.0.0.1.

### Safety and runtime boundary
- PostgreSQL remains loopback/private on port 5432. Never port-forward/expose 5432.
- Do not blindly set API bind to 0.0.0.0; local LAN ingress needs a separate audited listener, explicit origin policy and firewall/role/rate-limit checks.
- Main server port 8787, production DB, Supabase DB1/DB2 and Blynk/WoL relay are out of scope and must remain untouched.
- No runtime server process, Redmi .env, PostgreSQL schema/data or Cloudflare Worker deployment was changed by this task. Only isolated GitHub source branches were updated.

### Acceptance target and deadline
- Target: Sunday, 2026-11-22 (Asia/Jakarta).
- Do not mark complete until: Admin V12.1.51 APK artifact and SHA are verified; clean install/replace and correct login pass on Android; Cloudflare public /health returns API+database online; Admin login succeeds over cellular and Wi-Fi using HTTPS URL; role separation and Admin CRUD pass; Termux reconnect/background/restart behavior is documented; PostgreSQL 5432 stays private; rollback is available.
- Deadline is a project acceptance target, not a claim that the phone can be remotely operated from GitHub. On-device runtime tests require the Redmi/Termux output.


### Runtime recheck — 2026-11-16 09:45 WIB
- User ran `curl -sS --max-time 5 http://127.0.0.1:8788/health` in Termux; curl returned error 7, connection refused in 2 ms. This confirms no API listener was accepting connections on stage port 8788 at that moment.
- It does NOT prove PostgreSQL is offline; API and DB must be checked separately. No restart or DB operation has been run by the assistant.
- Next safe step: use the previously verified stage-only `~/ani-games-db-android-stage/start-stage.sh`, then recheck `/health`. Do not touch port 8787 or PostgreSQL data.


### Runtime diagnosis update — 2026-11-16 09:47 WIB
- User's repeated localhost health checks still return curl error 7 / connection refused on port 8788.
- Running the exact stage launcher bash ~/ani-games-db-android-stage/start-stage.sh exits with [ANI STAGE] API belum sehat.
- Its log tail contains historical successful /health 200 responses and api:online startup lines, but also fatal ECONNREFUSED / REQUEST_FAILED. The stage log is append-only and includes prior runs, so the old 200 lines do not prove the latest attempt is alive.
- Audited current source db-android-core/start-stage.sh and server/server.mjs on fix/db-android-core-api-contracts-20261116: launcher starts only the staging Node API on 8788 and waits 2 seconds; server startup first runs SELECT 1 against PostgreSQL before opening the HTTP listener. main().catch records fatal errors if that initial DB query fails. Therefore DB reachability at 127.0.0.1:5432 is the next diagnostic, not an Admin APK or Cloudflare change.
- db-android-core/status-stage.sh is a read-only PID/health check. db-android-core/setup-stage.sh is an installer and MUST NOT be run as a recovery step.
- No database changes or service restarts beyond the user's attempted stage launcher have been performed by assistant. Next step is read-only pg_isready -h 127.0.0.1 -p 5432, process check and sanitized last log lines. Do not start/reinitialize PostgreSQL or touch port 8787 until the result is known.

## DB Android WebSocket relay stage — 2026-11-16

- User authorized moving away from the repeated native Cloudflared DNS failure. Redmi evidence: PostgreSQL 18.6 accepted on 127.0.0.1:5432; API staging 127.0.0.1:8788 returned API/database online; Cloudflared repeatedly failed Go DNS lookup on [::1]:53; termux-chroot then crashed inside PRoot. The native Cloudflared/PRoot workaround is no longer the selected path.
- Selected design: Admin/API client → Cloudflare Worker → SQLite Durable Object RelayHub → outbound WSS Node.js agent on Termux → local API 127.0.0.1:8788 → PostgreSQL 127.0.0.1:5432.
- Runtime source branch: infra/db-android-ws-relay-stage-20261116, parent baseline infra/db-android-cloudflare-global-stage-20261116 / 388fe1808a32ac13ffeeeae6fff49cbef8e7f177; current branch head 7aed650a0705e20302719012fd440f4c245622d6. Master and all existing product tracks remain untouched.
- Worker deployed: ani-games-db-android-stage-ws-relay, URL https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev. workers.dev enabled; previews disabled. Durable Object RelayHub, SQLite namespace d3deb95247764649a63e05aa94962c45, binding RELAY_HUB, migration v1.
- Source branch has Worker code, minimal CI security regression suite, safe env example, documentation and workflow. Termux agent/control source is in the separately delivered installer/source archives.
- Verification: local Worker regression suite 12/12 PASS; Node syntax checks for Worker and agent PASS; Bash syntax checks for start/stop/status PASS. GitHub Actions run 43831355655 SUCCESS (branch CI Worker syntax/security tests).
- Worker API deployment and namespace binding succeeded. A public health fetch could not be completed by the current verification environment. No claim that the Worker is already serving the Redmi API.
- Pending: manually create Worker secret RELAY_SHARED_SECRET using the matching value from the Redmi staging ANI_EDGE_PROXY_SECRET (secret must not be sent to chat or committed); install the agent package on Redmi; start agent; require /_relay/health HTTP 200 with agent/API/database all online; run API contract tests and Admin APK login over Wi-Fi and cellular before changing the Admin app URL.
- Worker secret creation via the Cloudflare automation tool was blocked; no bypass was attempted. Secret must be entered by the user through Cloudflare Dashboard. No secret values are recorded in state.
- Final Termux ZIP: ANI-GAMES-READY-DB-ANDROID-WS-RELAY-TERMUX-FINAL.zip, SHA-256 e7b448b678819b3d811c3503dfdb04d90e1b7dbb54be98f9caad836acd633a95; source ZIP SHA-256 f67826e2031772d312d909758d552d517fb05cc6a3b5f36dd9051333c2cac1b2.
- Runtime boundaries unchanged: local API stays loopback 8788; PostgreSQL loopback 5432; main API 8787, production data, Supabase DB1/DB2 and Blynk/WoL relay are untouched. No SQL schema change or migration was executed. No Admin APK was changed.
