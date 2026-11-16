# Project Registry — live revalidation 2026-11-16

This registry is a source map, not a permanent truth. Re-fetch branch heads, ancestry, workflows and artifacts before every code edit or build.

## Active product and backend tracks

| Track | Repository | Work branch | Current head SHA | Source baseline |
|---|---|---|---|---|
| PC Billing DB Android | `anigamesready/PC-Billing` | `pc-billing-v12.4.8-DB-Android` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `fix/pc-v12.4.8-timer-size-sync` — `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`; V12.4.8 |
| PC Billing recovery — DB1 Direct | `anigamesready/PC-Billing` | `recovery/pc-v12.4.9-db1-direct-20261114` | `0565a8a225793e8785ca17f9079a15b753a834f1` | `fix/pc-v12.4.8-timer-size-sync` — `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`; V12.4.9, DB1-only recovery |
| Admin DB Android | `anigamesready/Admin-Ani-Games` | `admin-v12.1.50-DB-Android` | `be56ede591c6ebc42b99a02e7731228e02ac40d4` | `fix/ani-wol-master-pairing-guard-20261112` — `9460e8dcbdbf69706408dd0507016cf0037ff153`; V12.1.50, versionCode 78, applicationId `com.anigames.billingadmin.v150` |
| Reseller DB Android | `anigamesready/Admin-Ani-Games` | `reseller-v1.0.6-DB-Android` | `62e14e8caea62c50269cd62f4122efeed19e8731` | `release/reseller-v1.0.6-remember-login-rental-status` — `a67c2f6318230671a7d7776bf6040c39bca6ff97`; V1.0.6, versionCode 136 |
| Redmi DB Android standalone server/API | `anigamesready/PC-Billing` | `backend/db-android-core-v1` | `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9` | Based on PC Billing DB Android head `f938c574dfbd17ab84b07ca940115a280d3f8d78`; Node API + schema 000,002–011 + Termux stage scripts; device validation pending |
| Redmi DB Android API contract hotfix | `anigamesready/PC-Billing` | `fix/db-android-core-api-contracts-20261116` | `85a8be9534f5739f732c6ee6f25b4b8225eaf5f3` | Isolated from backend head `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9`; server-only Auth route and RPC type corrections |

## Live GitHub verification — 2026-11-14

### PC Billing
- Repository default branch: `main`, head `9796f2d83d9f4d052c72f6467855ebc63e02299f`.
- DB Android work branch remains V12.4.8 at `f938c574dfbd17ab84b07ca940115a280d3f8d78`; its commit adds only `docs/DB-ANDROID-PC-AUDIT.md` above the exact source baseline.
- `backend/db-android-core-v1` is 123 commits ahead of PC Billing DB Android head `f938c574dfbd17ab84b07ca940115a280d3f8d78` and 0 behind; merge base is exactly that PC Billing DB Android head.
- Latest backend branch HEAD is `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9`, which includes the Termux staging API, startup/status/stop scripts, Node API, migrations, regression tests, and package/test workflows.
- The DB1 audit reports 41 tables, 161 routines (152 SECURITY DEFINER), 116 triggers across 17 trigger functions, and 14 active Edge Functions. The full catalog snapshot is reference-only; the 24-table core schema excludes Supabase route/sync, WoL Relay, Telegram and automatic shutdown scheduler tables.
- Correction to the 2026-11-14 snapshot: the live backend/db-android-core-v1 branch contains a standalone Node HTTP API, local Auth/Admin/Billing/Reseller and Device routes, Termux stage scripts, PostgreSQL migrations and smoke tests. It is a separate local DB runtime, not a Supabase replacement. CI does not prove that the Redmi device has received the latest patch or that public internet access works.
- Existing `.github/workflows/build-pc-v12-4-8-timer-size-sync.yml` auto-push trigger is only `fix/pc-v12.4.8-timer-size-sync`; DB Android is not in the push filter. The workflow extracts an older named PC source ZIP and applies a patch chain. Do not treat manual dispatch or this inherited workflow as proof of a DB Android build.
- The inherited PC patch chain contains a V13 shutdown-timer patch followed by emergency-no-shutdown and direct-Windows-shutdown patches. Verify final behavior and preserve the no-automatic-countdown decision before any future build.

### PC Billing DB1-direct recovery — 2026-11-14
- Recovery branch `recovery/pc-v12.4.9-db1-direct-20261114`, head `0565a8a225793e8785ca17f9079a15b753a834f1`, based on V12.4.8 baseline `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`.
- GitHub Actions run `43572350285` completed successfully; output is V12.4.9 Windows portable EXE.
- It pins PC device traffic to DB1 `ani-games-api`; the PC transport no longer resolves DB route status, checks DB2, or selects the shared DB gateway.
- Keep this recovery branch separate from PC DB Android local-Redmi adapter work and from master. Real PC token/heartbeat/rental acceptance tests are pending.

### Admin
- Repository default branch: `main`, head `810bb3a879ae139e6e2dcf5d1526f1935eac7f65`.
- Current DB Android candidate is V12.1.50, not the old V12.1.46 branch. The V12.1.50 branch is 345 commits ahead of main and 0 behind; its latest commit adds only `docs/DB-ANDROID-ADMIN-V12.1.50-AUDIT.md`.
- V12.1.50 source baseline is `fix/ani-wol-master-pairing-guard-20261112` at `9460e8dcbdbf69706408dd0507016cf0037ff153`. Its source lineage includes the V12.1.46 reporting/rental behavior plus later Android WoL relay UI, reliability, role guard and manual probe work. Relay remains a separate service.
- Older `admin-v12.1.46-DB-Android` at `c97a5a6221f80841726bb9499bdef1c4759980a1` is retained as historical, not current Admin DB Android candidate.
- Existing `build-android-apk.yml` uses the Supabase/dual-DB patch chain and does not include `admin-v12.1.50-DB-Android` in its push branches. Do not use it as a Redmi PostgreSQL build.
- The Admin workflow applies a shutdown-timer patch followed later by the V12.1.40 removal patch. Verify the final no-countdown behavior; do not reintroduce automatic shutdown.

### Reseller
- Current DB Android branch head is `62e14e8caea62c50269cd62f4122efeed19e8731`, parent `e2147095432b37bba806b14c6948291248b28ccf`.
- It is 2 commits ahead of the V1.0.6 source baseline and 0 behind: one audit document plus `reference/supabase-only/fix_reseller_delete_rental_auth_gate.sql`.
- That SQL is explicitly marked REFERENCE ONLY; it depends on Supabase-only functions/schemas and must not be executed on Redmi PostgreSQL. Port business rules into the local API instead.
- Existing `build-reseller-apk.yml` push filters do not include the DB Android branch and remain Supabase DB1/DB2 dependent. Do not use this workflow as proof of a Redmi DB APK.
- V1.0.6 remembered-login source stores username and password in WebView localStorage. Treat as a security issue; do not carry plaintext password persistence into the local DB Android port. Reseller remains restricted to its own organization/rentals and must not receive Admin/Owner/PC/Windows/WoL controls.

## Redmi Termux server — last user-reported state, not live-verified
- Working directory: `/data/data/com.termux/files/home/ani-games-server`.
- Server control update 1.0.2 was reported installed; Node.js v24.22.3 API listens on port 8787.
- Last reported check showed PostgreSQL and API online and `/health` responding. A local SQL backup checksum was reported verified.
- These observations are historical user-reported evidence, not a live check of the phone during this audit. The current Termux source files and exact runtime configuration are not present in the GitHub repository tree available to this audit.

## Source and safety rules
1. Do not select `main` just because it is the default branch.
2. Keep PC Billing, Admin and Reseller source tracks separate.
3. Keep Redmi DB Android single-server work separate from Supabase DB1/DB2 dual-DB and production routing.
4. Do not apply the 41-table catalog snapshot wholesale. Review the 24-table core schema, prerequisites, constraints, indexes and missing routine/trigger ports on an empty staging DB only.
5. Do not port Supabase DB route/sync infrastructure, route-quiesce/before-image triggers, relay/Telegram sidecars or shutdown scheduler into the local single-DB runtime.
6. Implement server-side authentication, role/org scope, device identity, session revocation, rate limits, transaction locks, idempotency, audit, offline leases and command acknowledgements before connecting clients.
7. Never embed database/service-role secrets in PC/Android/Web clients or commit them to GitHub.
8. Re-fetch all full SHAs, workflows and artifact metadata before any code edit/build. Registry snapshots are not authorization to change production.


## Live GitHub verification — 2026-11-16: Redmi DB Android API hotfix

- Authoritative backend baseline: backend/db-android-core-v1 at d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9.
- Dedicated fix branch: fix/db-android-core-api-contracts-20261116 at 85a8be9534f5739f732c6ee6f25b4b8225eaf5f3. GitHub compare confirms 14 commits ahead of the backend baseline and 0 behind; the diff is limited to 7 files in db-android-core and its two CI workflows. The backend baseline and master were not edited.
- Root causes fixed:
  1. Auth compatibility routing stripped /functions/v1/ani-games-api in the outer handler but Auth re-read the original url.pathname, producing AUTH_ROUTE_NOT_FOUND. The normalized path is now passed through; prefix stripping requires a path boundary.
  2. dashboard_billing_user had an incorrect placeholder count and argument type order. Its nine values are now bound as text,text,text,text,text,text,uuid,text,uuid, matching the token-bound SQL wrapper.
- Added a 49-entry Node RPC contract check for parameter count, order and types, plus HTTP regressions for direct/prefixed Auth and Admin Billing User create/list/update/delete.
- PostgreSQL/API regression workflow 43755729409 completed successfully at HEAD 85a8be9534f5739f732c6ee6f25b4b8225eaf5f3. Package/fixture workflow 43755729458 also succeeded.
- Termux-only patch artifact ANI-GAMES-READY-DB-ANDROID-API-FIX-20261116.zip: artifact ID 14177929336, size 3,903 bytes, SHA-256 c7d11bf7e376506d0ed816a07cdc738d73009304ed7c145bf0371719a6b1dd07. It modifies only the existing stage server/server.mjs, preserves local custom code, creates a backup and does not run SQL or touch .env, PostgreSQL, port 8787 or WoL relay.
- The patch is not yet applied on the Redmi. Stage API stays loopback-only (127.0.0.1:8788); public reachability from arbitrary networks is not established. Do not expose PostgreSQL port 5432.


## Live GitHub verification — 2026-11-16: Admin login and Redmi global access

### Admin APK
- Current Admin DB Android base: anigamesready/Admin-Ani-Games branch admin-v12.1.50-DB-Android, commit 3ebc8b1912aef13a4833f113c9e7a4914554b146.
- Isolated Admin candidate: fix/admin-db-android-login-gate-v1.51, head 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5; 5 commits ahead, zero behind the V12.1.50 base.
- Candidate versionName 12.1.51, versionCode 79, applicationId com.anigames.billingadmin.v150db. The V12.1.51 patch restores the missing setAdminAuthEnabled helper.
- Added scripts/patch_admin_db_android_api_fetch_reliability.py and wired it into the dedicated DB Android APK workflow. It removes Content-Type from bodyless health GET requests and surfaces the attempted API origin on WebView fetch failures. Treat as candidate only: CI status, artifact SHA and device login are not yet verified.
- The alternate fix/admin-v12.1.50-db-android-login-click branch is diverged from the current base; do not use it as the build source.

### Cloudflare gateway
- Worker ani-games-db-android-stage-gateway is deployed and workers.dev is enabled at https://ani-games-db-android-stage-gateway.anigamesready.workers.dev. KV namespace ani-games-db-android-stage-upstreams is bound (ID 55b2907fc76242c99774413e9986187f), but current key ani_games_ready_stage:upstream is absent. No named Cloudflare Tunnel or DNS zone exists in the connected account. This means there is no active public path to the Redmi yet.
- Old gateway branch infra/db-android-cloudflare-gateway-stage at d1c8a4dde3ec791e29e41a32604dd15c20de14b8 diverges from API fix branch fix/db-android-core-api-contracts-20261116 (49 ahead, 17 behind); do not apply it directly.
- New branch infra/db-android-cloudflare-global-stage-20261116 is based exactly on API fix branch head f16d97a3dfd96f2f3598396976c3ee5d63c60e6d; current head 8c39f86410a3cd6b0ce3521029e689d63984752e, 10 ahead, zero behind.
- New gateway branch includes Worker, allowlisted API proxy, edge client-IP trust with a shared secret, local bootstrap deny checks, Termux runner/configuration scripts and CI tests. The API patch now reuses existing local node:net and ANI_EDGE_PROXY_SECRET declarations instead of duplicating them. CI/artifact/on-device checks remain pending.
- The current origin strategy uses Quick Tunnel behind the stable Worker hostname. Quick Tunnel URL rotates; Worker registration TTL is 600 seconds and Termux runner refreshes while alive. This is staging, not a named tunnel or a guaranteed 24/7 service. The same Worker URL can be used over Wi-Fi or mobile data after origin registration, but it routes through the internet. Direct LAN-only ingress remains a separate uncompleted design.

### Hard boundaries
- Keep stage API 127.0.0.1:8788 until a separately audited LAN listener is implemented.
- PostgreSQL 127.0.0.1:5432 remains private; no port-forwarding or public DB listener.
- Keep main server port 8787, production data, Supabase DB1/DB2 and Blynk/WoL relay unchanged.
- User acceptance target recorded as Sunday 2026-11-22. See PROJECT_STATE.md and NEXT_TASKS.md for the required tests and blockers.
