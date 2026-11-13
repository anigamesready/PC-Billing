# Project Registry — live revalidation 2026-11-14

This registry is a source map, not a permanent truth. Re-fetch branch heads, ancestry, workflows and artifacts before every code edit or build.

## Active product and backend tracks

| Track | Repository | Work branch | Current head SHA | Source baseline |
|---|---|---|---|---|
| PC Billing DB Android | `anigamesready/PC-Billing` | `pc-billing-v12.4.8-DB-Android` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `fix/pc-v12.4.8-timer-size-sync` — `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`; V12.4.8 |
| Admin DB Android | `anigamesready/Admin-Ani-Games` | `admin-v12.1.50-DB-Android` | `be56ede591c6ebc42b99a02e7731228e02ac40d4` | `fix/ani-wol-master-pairing-guard-20261112` — `9460e8dcbdbf69706408dd0507016cf0037ff153`; V12.1.50, versionCode 78, applicationId `com.anigames.billingadmin.v150` |
| Reseller DB Android | `anigamesready/Admin-Ani-Games` | `reseller-v1.0.6-DB-Android` | `62e14e8caea62c50269cd62f4122efeed19e8731` | `release/reseller-v1.0.6-remember-login-rental-status` — `a67c2f6318230671a7d7776bf6040c39bca6ff97`; V1.0.6, versionCode 136 |
| Redmi DB Android schema/API core | `anigamesready/PC-Billing` | `backend/db-android-core-v1` | `8e9797628ec4508dd5251d32d2a6faa983c7d106` | Based on PC Billing DB Android head `f938c574dfbd17ab84b07ca940115a280d3f8d78`; schema/catalog reference only, not a running API |

## Live GitHub verification — 2026-11-14

### PC Billing
- Repository default branch: `main`, head `9796f2d83d9f4d052c72f6467855ebc63e02299f`.
- DB Android work branch remains V12.4.8 at `f938c574dfbd17ab84b07ca940115a280d3f8d78`; its commit adds only `docs/DB-ANDROID-PC-AUDIT.md` above the exact source baseline.
- `backend/db-android-core-v1` is 5 commits ahead of the PC DB Android branch and 0 behind. The five additions are README, DB1 live contract audit, prerequisites SQL, full catalog snapshot SQL, and 24-table core business schema SQL.
- Latest backend branch commit `8e9797628ec4508dd5251d32d2a6faa983c7d106` adds `002_core_business_schema.sql` (466 lines); parent `aa44f0755179cff4001c1c276e4502902f47f670`.
- The DB1 audit reports 41 tables, 161 routines (152 SECURITY DEFINER), 116 triggers across 17 trigger functions, and 14 active Edge Functions. The full catalog snapshot is reference-only; the 24-table core schema excludes Supabase route/sync, WoL Relay, Telegram and automatic shutdown scheduler tables.
- This backend branch does NOT contain the Redmi Node API implementation, login/session handlers, route handlers, startup manager or tests. A schema snapshot is not a working Supabase replacement.
- Existing `.github/workflows/build-pc-v12-4-8-timer-size-sync.yml` auto-push trigger is only `fix/pc-v12.4.8-timer-size-sync`; DB Android is not in the push filter. The workflow extracts an older named PC source ZIP and applies a patch chain. Do not treat manual dispatch or this inherited workflow as proof of a DB Android build.
- The inherited PC patch chain contains a V13 shutdown-timer patch followed by emergency-no-shutdown and direct-Windows-shutdown patches. Verify final behavior and preserve the no-automatic-countdown decision before any future build.

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
