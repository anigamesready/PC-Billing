# Project State — 2026-11-16

## Current Skill System status
- Hybrid BOTH workflow is being used: GitHub is the permanent instruction/state source; ChatGPT reads the repository through the connected GitHub integration at task start.
- This chat successfully read the required Skill System documents and relevant Skills from `docs/ani-games-ready-ai-skill-system`.
- The connected GitHub repository was readable. Previous setup commits also demonstrated documentation-only updates on the dedicated docs branch.
- The user has not independently confirmed creation of a ChatGPT Project or pasting the Project Instructions. Do not claim Project-level setup is complete.
- No runtime source, database, APK/EXE, server, build workflow, or production configuration was changed in this activation/audit.

## Latest verified source tracks
- PC Billing DB Android: V12.4.8, branch `pc-billing-v12.4.8-DB-Android`, head `f938c574dfbd17ab84b07ca940115a280d3f8d78`, source baseline `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`.
- Admin DB Android: newer candidate V12.1.50, branch `admin-v12.1.50-DB-Android`, head `be56ede591c6ebc42b99a02e7731228e02ac40d4`, baseline `9460e8dcbdbf69706408dd0507016cf0037ff153`. V12.1.46 is retained as historical.
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

## Redmi Termux server — latest reported state
- Working directory: `~/ani-games-server` (`/data/data/com.termux/files/home/ani-games-server`).
- Server Control 1.0.2 update was reported installed from `ANI_GAMES_READY_SERVER_CONTROL_FIX_1.0.2/UPDATE.sh`.
- Node.js v24.22.3 API uses port 8787.
- Last user-reported state on 2026-11-13: PostgreSQL ONLINE, API ONLINE, local `/health` endpoint responded, and a SQL backup checksum was verified.
- This was not re-queried from the phone in this chat. Current files, current process state, credentials/config, database contents and backup restore have not been revalidated.

## DB1-to-Redmi compatibility findings
- The DB1 live contract audit records 41 tables, 161 routines (152 SECURITY DEFINER), 116 triggers across 17 functions, and 14 active Edge Functions.
- `001_db1_catalog_snapshot.sql` is a full structure reference, not a ready-to-run replacement. `002_core_business_schema.sql` defines 24 operational business tables with constraints and indexes, but no complete local API, authentication handlers, RPC/function bodies, trigger port set or client contract tests.
- The local API still needs secure Admin/Owner/Reseller sessions, PC enrollment/device tokens, heartbeat/ack, sync cursor/pull, rental lookup/session lifecycle/release, offline leases/conflicts, global rental CRUD, reports/exports, audit, rate limits and role/org isolation.
- Do not apply schema files to the existing Redmi database until current server/schema state is inspected and a fresh staging database + restore plan are verified.
- Do not copy DB1/DB2 route/sync infrastructure, route-quiesce triggers, WoL Relay/Telegram sidecars or automatic shutdown scheduler into the local single-server path.

## Safety constraints
- Keep DB Android separate from Supabase DB1/DB2 dual-database development and production routes.
- Never expose PostgreSQL passwords, Supabase service-role keys, signing credentials or customer data in clients/docs.
- No production cutover, destructive sync or cross-database copy without explicit approval, dry-run, verified backup/restore, row-level parity, idempotency, audit and rollback.
- Do not reintroduce automatic shutdown countdown behavior.
- Reseller must remain limited to its own rentals; no Admin/Owner or PC/Windows/WoL control.

## Next action
Obtain a current, sanitized read-only copy/inventory of the Termux project at `~/ani-games-server`. Inspect source files, package dependencies, server routes, auth, schema, startup/control scripts, logs and backup/restore behavior. Then compare each endpoint against the versioned DB1 contract and define missing server work before touching any client branch.
