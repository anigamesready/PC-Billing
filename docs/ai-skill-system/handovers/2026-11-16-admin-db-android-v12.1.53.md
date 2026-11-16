# Handover — Admin APK DB Android V12.1.53 Clean Single-DB

- Date/time (Asia/Jakarta): 2026-11-16, evening WIB
- Status: BUILD COMPLETED; DEVICE ACCEPTANCE PENDING
- User request: Update the isolated Admin DB Android APK; ensure legacy Supabase DB1/DB2 runtime does not carry into this separate DB Android product; preserve original Admin functions.
- Repository: `anigamesready/Admin-Ani-Games`
- Work branch: `fix/admin-db-android-clean-single-db-v1.53`
- Exact source baseline branch + full SHA: `fix/admin-db-android-login-gate-v1.51` — `8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5`
- Previous verified Admin DB Android baseline: `admin-v12.1.50-DB-Android` — `3ebc8b1912aef13a4833f113c9e7a4914554b146`
- Current work branch head + full SHA: `1177b018725822a671fe3a2b9b9facedf75240b7`
- Branch comparison: 10 commits ahead / 0 behind the V12.1.51 login-gate baseline.
- Source archive used by workflow: `AniGames-Admin-V12.1.4-ANDROID-PASSWORD-RESET-PATCH-v3.zip`; SHA-256 was not recalculated in this build.
- Build workflow: `.github/workflows/build-db-android-admin-apk.yml`; push trigger is only `fix/admin-db-android-clean-single-db-v1.53`, plus workflow_dispatch.
- GitHub Actions run: [43879706639](https://github.com/anigamesready/Admin-Ani-Games/actions/runs/43879706639) — SUCCESS.
- App version/package: V12.1.53, versionCode 81, applicationId `com.anigames.billingadmin.v150db`.
- Backend/gateway: outbound Worker relay `https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev` to Redmi API staging port 8788; PostgreSQL 5432 remains loopback/private.

## What was inspected
- Admin source baseline and V12.1.51 login-gate patch lineage.
- Three WebView pages: `admin.html`, `index.html`, `admin-control.html`.
- Admin local API/auth adapter and Billing Control API adapter.
- Independent Supabase WoL relay sidecar.
- Redmi API RPC map in `anigamesready/PC-Billing`, branch `infra/db-android-ws-relay-stage-20261116`.
- Worker URL and allowlisted /health, /auth/v1/* and /rest/v1/rpc/* routes.
- Existing CI pipeline and generated APK identity.

## Changes made
| File | Change | Reason |
|---|---|---|
| `scripts/patch_admin_db_android_gateway_default.py` | V12.1.52: set the verified HTTPS Redmi Worker URL as the default for Admin, Admin login, and Billing Control pages; retain manual URL override. | Avoid 127.0.0.1 pointing to the Admin APK handset instead of the Redmi server. |
| `scripts/patch_admin_db_android_clean_single_db.py` | V12.1.53: physically remove the old DB1/DB2 top bar, tab, sync/preflight section, route stubs/state and legacy wording. Rename remaining Supabase variables as relay-only names. | Ensure old dual-DB selector/routing system is not shipped in this single-DB Android branch. |
| `.github/workflows/build-db-android-admin-apk.yml` | Add V12.1.52/V12.1.53 patches and checks; build final and safe-test APKs. | Enforce repeatable build identity and regression gates. |

## Verification
- V12.1.51 earlier CI run: 43788560026 SUCCESS; restored the missing Admin auth button gate helper.
- V12.1.52 first attempt failed a custom script-extraction regex; corrected and rebuilt successfully in V12.1.52 run 43876878358. V12.1.52 artifact was superseded by V12.1.53 and is not the current install recommendation.
- V12.1.53 run 43879706639: SUCCESS.
- Physical single-DB cleanup assertion: PASS. No `databaseTools`, `DB1/DB2` route state, dual-DB sync UI, route stubs or DB2 selector tokens remain in final `admin.html`.
- Core Admin markers retained: local Admin auth/context, device list, global rental list/create/update/delete, PC commands and acknowledgements, reports and theme save. PASS.
- Direct Supabase table reads (`sb.from(`) absent from Admin page. PASS.
- Separate WoL relay Supabase sidecar remains, under `RELAY_SUPABASE_URL`, `RELAY_SUPABASE_PUBLISHABLE_KEY`, and `RELAY_SUPABASE_FUNCTION_URL`. WoL relay auth/storage remains separate. PASS.
- All three pages use the HTTPS Redmi gateway default; no localhost :8787 or :8788 defaults. PASS.
- Node syntax checks for all three WebView scripts. PASS.
- Android main APK Gradle build, package ID/version/label, v2 signature verification and ZIP integrity. PASS.
- Side-by-side safe-test APK build, separate package ID/version/label and v2 signature verification. PASS.
- Downloaded artifact SHA-256: `447a2c825ab8d0dd980f4ee74fece7823552f4a59ea3b1e85275d5931607e72a` (artifact ZIP).
- Main APK: `AniGames-Admin-DB-Android-V12.1.53.apk`; 734,881 bytes; SHA-256 `3c436460229450b66cdd72752fc65c9d2a2a39e428cc156da0017cc0253dea28`.
- Safe-test APK: `AniGames-Admin-DB-Android-V12.1.53-SAFE-TEST.apk`; 734,889 bytes; SHA-256 `8e0cb141d634dcd9d9a79cc58eee1fa89ababfebb2c607f5f57d2f716882ea38`.
- Artifact ID 14231274085; expires 2026-12-16.
- Signing is the CI debug signing certificate (assembleDebug), not a production release signing key.

## Tests not run / acceptance pending
- Fresh install on the user's Redmi/Android device.
- Real Admin account login with valid credentials, refresh/logout, dashboard loading and role/organization authorization against the live Redmi DB.
- Live Admin rental CRUD, PC command/ack, report data/exports and WoL operations from the installed APK.
- Wi-Fi and cellular end-to-end tests, process/network reconnect and 24-hour phone uptime.
- A prior empty-password probe returned HTTP 401 `INVALID_CREDENTIALS`; it did not test a valid user login.
- At last user-provided Termux check: relay agent, Worker health, stage API 8788 and PostgreSQL showed online; legacy main API port 8787 was closed and was not modified. This is user-reported point-in-time evidence, not a fresh probe after build.

## Risks / blockers
- This is a staging/debug-signed APK. Do not label it production release or merge it to the stable Admin branch.
- Supabase publishable-key client remains solely for the independently existing WoL relay sidecar; it is not used for Admin rental tables/auth.
- CI/static checks do not substitute for real login and device feature acceptance.
- Keep the Redmi relay agent and stage API running while testing the APK.

## Rollback
- Stable Admin application/package was not replaced or edited.
- The DB Android app uses isolated applicationId `com.anigames.billingadmin.v150db`; safe-test uses `com.anigames.billingadmin.v150dbtest`.
- Rollback: uninstall only the DB Android candidate package if needed; leave the original stable Admin app untouched.
- Runtime server, PostgreSQL, .env, schema/data, Supabase, Blynk/WoL and port 8787 were not changed during this APK build.

## Next action
1. Install V12.1.53 on Android as the separate DB Android app.
2. Ensure Termux staging API and WebSocket relay are running, then sign in using an existing Admin account. Do not send passwords/tokens in chat.
3. Send only the result/error text and a redacted screenshot if login or a feature fails; continue targeted end-to-end testing before operational acceptance.

## User-facing summary
V12.1.53 is built and statically/regression checked. It removes the old DB1/DB2 selector and sync UI from the APK, uses the HTTPS gateway to the Redmi database by default, and preserves the Admin feature routes and separate WoL relay integration. Live login and device-side operation are still waiting for user installation and test.
