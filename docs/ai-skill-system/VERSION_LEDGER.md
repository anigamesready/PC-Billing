# Version & Source Ledger

Revalidate live repository refs and artifact metadata before every source/build task. These are source baselines, not proof that DB Android builds are ready.

| Product / track | Current recorded baseline | Branch | Source baseline commit | Current work branch head | Package / version code |
|---|---|---|---|---|---|
| PC Billing DB Android | V12.4.8 | `pc-billing-v12.4.8-DB-Android` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | Windows EXE; verify build metadata from current source |
| PC Billing recovery — DB1 Direct | V12.4.9 | `recovery/pc-v12.4.9-db1-direct-20261114` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `0565a8a225793e8785ca17f9079a15b753a834f1` | Windows portable EXE; `com.anigames.billing.v12test`; legacy `productName` unchanged |
| Admin DB Android source baseline | V12.1.50 | `admin-v12.1.50-DB-Android` | `9460e8dcbdbf69706408dd0507016cf0037ff153` | `3ebc8b1912aef13a4833f113c9e7a4914554b146` | Historical isolated baseline; versionCode 78; applicationId `com.anigames.billingadmin.v150` |
| Admin DB Android staging candidate | V12.1.53 | `fix/admin-db-android-clean-single-db-v1.53` | `8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5` | `1177b018725822a671fe3a2b9b9facedf75240b7` | versionCode 81; applicationId `com.anigames.billingadmin.v150db`; device acceptance pending |
| Reseller DB Android | V1.0.6 | `reseller-v1.0.6-DB-Android` | `a67c2f6318230671a7d7776bf6040c39bca6ff97` | `62e14e8caea62c50269cd62f4122efeed19e8731` | versionCode 136; applicationId must be re-read from source/build |
| Redmi DB Android standalone server/API | API/schema v1 | `backend/db-android-core-v1` | PC DB Android baseline `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9` | Termux Node API + PostgreSQL schema 000,002–011; device install validation pending |
| Redmi DB Android API contract hotfix | server hotfix 2026-11-16 | `fix/db-android-core-api-contracts-20261116` | backend baseline `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9` | `85a8be9534f5739f732c6ee6f25b4b8225eaf5f3` | Server-only patch; no database schema change |

## Build workflow caveats
- PC V12.4.8 workflow push trigger is the original `fix/pc-v12.4.8-timer-size-sync` branch, not the DB Android branch.
- The legacy Admin V12.1.50 workflow remains Supabase/dual-DB and is not the Redmi installer. The dedicated V12.1.53 workflow now triggers only on `fix/admin-db-android-clean-single-db-v1.53`.
- Reseller V1.0.6 workflow remains Supabase DB1/DB2 and excludes `reseller-v1.0.6-DB-Android` from automatic push.
- No APK/EXE was built, downloaded or verified during the 2026-11-14 activation audit.

## Infrastructure artifact ledger
- DB Android Cloudflare Termux DNS-fix helper package.
- Branch: `infra/db-android-cloudflare-gateway-stage`; runtime runner commit `143253184bca03b96ea5233ac2a76e61723b5cf5`; CI head `693289ad16a380119bba981ecdde4e2d4453ad0e`.
- Workflow run: `43689341047`; artifact ID `14151522874`; file `ANI-GAMES-READY-DB-ANDROID-CLOUDFLARE-STAGE-DNS-FIX.zip`; size 17,557 bytes; SHA-256 `84bf654ae73c4b2b6656df058d392c8c56260b3ec41cddea1c62713907018442`.
- CI: success. On-device DNS/tunnel/public API validation: pending. This helper package is not a PC Billing/Admin/Reseller release and has no application version code.

## Redmi DB Android API hotfix artifact ledger

- Branch: fix/db-android-core-api-contracts-20261116; source baseline backend/db-android-core-v1 at d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9; final branch head at release of the package: 85a8be9534f5739f732c6ee6f25b4b8225eaf5f3.
- Regression run: 43755729409 — success.
- Package/fixture run: 43755729458 — success.
- Artifact ID: 14177929336; name ANI-GAMES-READY-DB-ANDROID-API-FIX-20261116.zip; size 3,903 bytes; SHA-256 c7d11bf7e376506d0ed816a07cdc738d73009304ed7c145bf0371719a6b1dd07.
- Package contents: APPLY_DB_ANDROID_API_FIX.sh, CHECK_DB_ANDROID_API_FIX.sh, README-ID.txt, SHA256SUMS.txt.
- The package patch edits only the stage server.mjs file with a timestamped backup. It has not yet been applied to Redmi. No app version/versionCode applies.
- Master and backend baseline were not modified; the fix branch remains separate.

## Artifact ledger
Admin DB Android V12.1.53 APK is now built and verified as a staging/debug-signed candidate; its artifact details are recorded below. Device-side login and feature acceptance remain pending.

 
## 2026-11-16 — Current Admin login/global gateway work candidates (not released)

| Track | Repository | Branch | Current head | Base comparison | Package / status |
|---|---|---|---|---|---|
| Admin DB Android clean single-DB candidate | anigamesready/Admin-Ani-Games | fix/admin-db-android-clean-single-db-v1.53 | 1177b018725822a671fe3a2b9b9facedf75240b7 | fix/admin-db-android-login-gate-v1.51 at 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5; 10 ahead, 0 behind | V12.1.53; versionCode 81; applicationId com.anigames.billingadmin.v150db; CI run 43879706639 SUCCESS; valid APK artifact 14231274085; install/login acceptance pending |
| DB Android global-access gateway | anigamesready/PC-Billing | infra/db-android-cloudflare-global-stage-20261116 | 8c39f86410a3cd6b0ce3521029e689d63984752e | fix/db-android-core-api-contracts-20261116 at f16d97a3dfd96f2f3598396976c3ee5d63c60e6d; 10 ahead, 0 behind | Source/CI candidate only; no verified Termux ZIP or Redmi runtime success yet |

- The old infra/db-android-cloudflare-gateway-stage branch at d1c8a4dde3ec791e29e41a32604dd15c20de14b8 is divergent from the API fix branch (49 ahead/17 behind) and must not be used as a direct install source.
- The Worker ani-games-db-android-stage-gateway is deployed at https://ani-games-db-android-stage-gateway.anigamesready.workers.dev, but current KV upstream is missing; it is not online to the Redmi.
- Gateway uses an ephemeral Quick Tunnel origin behind the stable Worker hostname, refreshed periodically; not a 24/7 named-tunnel release. No custom DNS zone/named tunnel found in the connected Cloudflare account.
- CI statuses returned no check rows in this audit, and there are no verified new release artifacts. Keep all entries marked candidate/pending until evidence is fetched.

## DB Android outbound WebSocket relay stage — 2026-11-16

- Repository: anigamesready/PC-Billing.
- Work branch: infra/db-android-ws-relay-stage-20261116.
- Exact parent baseline: infra/db-android-cloudflare-global-stage-20261116 / 388fe1808a32ac13ffeeeae6fff49cbef8e7f177.
- Current work branch head: d86e7ecfa82d7af29bb53d067a316984b1fef69b.
- Worker: ani-games-db-android-stage-ws-relay; URL https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev.
- Durable Object namespace: ani-games-db-android-stage-ws-relay_RelayHub, ID d3deb95247764649a63e05aa94962c45, SQLite; binding RELAY_HUB, migration tag v1.
- GitHub Actions: run 43831355655, conclusion SUCCESS.
- Local verification: worker/agent Node syntax PASS; 12/12 Worker/relay regression tests PASS; 3 Bash scripts syntax PASS.
- Redmi final Termux ZIP: ANI-GAMES-READY-DB-ANDROID-WS-RELAY-TERMUX-FINAL.zip, size 11,437 bytes, SHA-256 e7b448b678819b3d811c3503dfdb04d90e1b7dbb54be98f9caad836acd633a95.
- Admin DB Android V12.1.53 now uses this Worker URL as its default gateway. User-reported Redmi health shows agent/Worker/API 8788/PostgreSQL online. Auth with valid Admin credentials, all live RPC/device route tests, Wi-Fi/cellular and 24-hour reliability remain pending.

## Admin DB Android V12.1.53 artifact ledger — 2026-11-16

- Repository: anigamesready/Admin-Ani-Games.
- Work branch: fix/admin-db-android-clean-single-db-v1.53.
- Work branch HEAD: 1177b018725822a671fe3a2b9b9facedf75240b7.
- Baseline: fix/admin-db-android-login-gate-v1.51 at 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5; 10 commits ahead, 0 behind.
- Workflow: .github/workflows/build-db-android-admin-apk.yml; only this branch is in the push trigger.
- GitHub Actions run 43879706639 — SUCCESS.
- Artifact ID 14231274085; archive AniGames-Admin-DB-Android-v12.1.53; 1,295,700 bytes; SHA-256 447a2c825ab8d0dd980f4ee74fece7823552f4a59ea3b1e85275d5931607e72a.
- Main APK: AniGames-Admin-DB-Android-V12.1.53.apk; 734,881 bytes; SHA-256 3c436460229450b66cdd72752fc65c9d2a2a39e428cc156da0017cc0253dea28; versionName 12.1.53; versionCode 81; applicationId com.anigames.billingadmin.v150db.
- Safe-test APK: AniGames-Admin-DB-Android-V12.1.53-SAFE-TEST.apk; 734,889 bytes; SHA-256 8e0cb141d634dcd9d9a79cc58eee1fa89ababfebb2c607f5f57d2f716882ea38; applicationId com.anigames.billingadmin.v150dbtest.
- Both are CI debug-signed with APK Signature Scheme v2; not production release-signed.
- APK integrity, identity, single-DB cleanup, three page JS syntax, key Admin markers and separate WoL sidecar static checks passed.
- User confirmed the Admin APK login succeeds through the Redmi HTTPS Worker gateway on 2026-11-17. Remaining: confirm fresh-install provenance if not already recorded, role/org context, Admin CRUD, PC commands/ack, exports/reports, WoL, Wi-Fi/cellular and 24-hour behavior.


## DB Android Owner bootstrap recovery helper — 2026-11-16

- Repository: `anigamesready/PC-Billing`.
- Base branch/commit: `infra/db-android-ws-relay-stage-20261116` / `d86e7ecfa82d7af29bb53d067a316984b1fef69b`.
- Isolated work branch: `fix/db-android-stage-bootstrap-recovery-20261116`; final branch HEAD `8ac5491a5f7ca81a6af85256ce5a2a815a888adc`; 5 ahead / 0 behind.
- Helper source: `db-android-core/repair-stage-bootstrap.sh`; current blob SHA `ea15fce579e5acb0ea5feae60186633b3904cd98`.
- Guide: `db-android-core/BOOTSTRAP-RECOVERY-ID.md`; current blob SHA `b096a4d2d6ece290caf309a8aad49da8132af658`.
- Regression script: `db-android-core/tests/repair-stage-bootstrap.test.sh`; CI workflow: `.github/workflows/test-db-android-stage-bootstrap-recovery.yml`.
- GitHub Actions run `43896105470`, conclusion SUCCESS at helper hardening commit `91618fc083c202e08da41549ab3e0c830ee6d013`. Shell syntax, four mocked safety cases and destructive-command/secret-pattern scan passed.
- Final package: `ANI-GAMES-READY-DB-ANDROID-BOOTSTRAP-RECOVERY-20261116.zip`; 4 files; ZIP integrity PASS; SHA-256 `374b6b49b45f7cb706f069ca1467a9810a66483a1d8767bf228c93046e386287`.
- Per-file SHA-256: helper `fd45df4267be06318ac4b261d964a5de16129a123fb777bb28a1129365b40e75`; README `b300a55d82d10a5b4bd8c63c06efd36246dd2ba7ad35f6763dd4c5d5479bcaf6`; regression test `610f9dc087cf221620f57d16058d651f16d38ccea3f107da73056f94ec722ecf`.
- Status: source/CI/package complete; Redmi helper execution, Owner creation and V12.1.53 login acceptance pending. This is a staging repair utility, not an application release.

## 2026-11-17 — DB Android Termux control package

- Package: `ANI-GAMES-READY-DB-ANDROID-CONTROL-1.0.0.zip`
- Size: 11,168 bytes
- SHA-256: `d3f51d6528695891bbf8e48f727e87a1ffd0d8e538877f66dbad19a71520aa04`
- Includes controller, installer, four Termux:Widget shortcut files, README-ID, SHA256SUMS and runtime fixture tests.
- Local verification: bash syntax PASS; SHA256SUMS PASS; ZIP integrity PASS; mock runtime regression PASS for start order, soft stop, full stop, legacy API 8787 guard, other PostgreSQL client guard, installer output and widget shortcuts.
- Device application and Termux:Widget one-tap acceptance: PENDING. This is a support tool, not an APK or backend schema release.


## 2026-11-24 — DB Android Always-On Control 1.1.0 candidate

| Track | Candidate | Source baseline | Artifact | Verification | Status |
|---|---|---|---|---|---|
| Redmi DB Android control | Control 1.1.0 | Library Control 1.0.0 archive SHA-256 `d3f51d6528695891bbf8e48f727e87a1ffd0d8e538877f66dbad19a71520aa04`; PC-Billing stage context `bd11d9b4e53ece362715a772f210c7e3b13adba1` | `ANI-DB-ANDROID-ALWAYSON-1.1.0.zip`; SHA-256 `3f6e39ff7b5c7332891f4db2412d335b260bbd1afc35e4f2036e0be80d112443`; 23 KB | Bash syntax PASS; fixture tests PASS; install/runtime on Redmi NOT RUN; reboot test NOT RUN; ShellCheck unavailable | Candidate only — awaiting user install and device verification |


## 2026-11-24 — DB Android Always-On Control 1.1.0 candidate
- Repository `anigamesready/PC-Billing`; isolated work branch `fix/db-android-always-on-supervisor-20261124`; source base `bd11d9b4e53ece362715a772f210c7e3b13adba1`.
- Release manifest commit `9102a4317b89208fa665318be70b0af8209ba59f` records scope and device acceptance requirements.
- Package `ANI-GAMES-READY-DB-ANDROID-ALWAYS-ON-1.1.0.zip`; SHA-256 `01c5f25ca2f4774d5209f39b9083e39bf75b74502af9f89d56265c73f75257ac`.
- Package scripts: controller, watchdog, installer, runit run service, Termux:Boot helper, README, checksum list, fixture tests.
- 11/11 disposable fixture cases PASS. All included Bash files pass `bash -n`; all package file checksums match; `unzip -t` passes.
- No Redmi deployment or 24-hour physical test. No DB data/schema, `.env`, secrets, port 8787, Supabase, Worker deployment, or Blynk/WoL setting changed.
