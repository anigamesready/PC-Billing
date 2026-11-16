# Version & Source Ledger

Revalidate live repository refs and artifact metadata before every source/build task. These are source baselines, not proof that DB Android builds are ready.

| Product / track | Current recorded baseline | Branch | Source baseline commit | Current work branch head | Package / version code |
|---|---|---|---|---|---|
| PC Billing DB Android | V12.4.8 | `pc-billing-v12.4.8-DB-Android` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | Windows EXE; verify build metadata from current source |
| PC Billing recovery — DB1 Direct | V12.4.9 | `recovery/pc-v12.4.9-db1-direct-20261114` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `0565a8a225793e8785ca17f9079a15b753a834f1` | Windows portable EXE; `com.anigames.billing.v12test`; legacy `productName` unchanged |
| Admin DB Android | V12.1.50 | `admin-v12.1.50-DB-Android` | `9460e8dcbdbf69706408dd0507016cf0037ff153` | `3ebc8b1912aef13a4833f113c9e7a4914554b146` | versionCode 78; applicationId `com.anigames.billingadmin.v150` |
| Reseller DB Android | V1.0.6 | `reseller-v1.0.6-DB-Android` | `a67c2f6318230671a7d7776bf6040c39bca6ff97` | `62e14e8caea62c50269cd62f4122efeed19e8731` | versionCode 136; applicationId must be re-read from source/build |
| Redmi DB Android standalone server/API | API/schema v1 | `backend/db-android-core-v1` | PC DB Android baseline `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9` | Termux Node API + PostgreSQL schema 000,002–011; device install validation pending |
| Redmi DB Android API contract hotfix | server hotfix 2026-11-16 | `fix/db-android-core-api-contracts-20261116` | backend baseline `d0f94ec0e9a7f5660029fb3b02d62f7fb9b3b3a9` | `85a8be9534f5739f732c6ee6f25b4b8225eaf5f3` | Server-only patch; no database schema change |

## Build workflow caveats
- PC V12.4.8 workflow push trigger is the original `fix/pc-v12.4.8-timer-size-sync` branch, not the DB Android branch.
- Admin V12.1.50 workflow remains Supabase/dual-DB and excludes `admin-v12.1.50-DB-Android` from automatic push.
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
No new APK/EXE artifact was produced. The infrastructure helper artifact above is separate from application releases; Redmi runtime acceptance is still pending.

 
## 2026-11-16 — Current Admin login/global gateway work candidates (not released)

| Track | Repository | Branch | Current head | Base comparison | Package / status |
|---|---|---|---|---|---|
| Admin DB Android login repair | anigamesready/Admin-Ani-Games | fix/admin-db-android-login-gate-v1.51 | 8d0c241ac86ca53b9a6c2a4a76720169a0e1aee5 | admin-v12.1.50-DB-Android at 3ebc8b1912aef13a4833f113c9e7a4914554b146; 5 ahead, 0 behind | Candidate V12.1.51; versionCode 79; applicationId com.anigames.billingadmin.v150db; no verified APK artifact yet |
| DB Android global-access gateway | anigamesready/PC-Billing | infra/db-android-cloudflare-global-stage-20261116 | 8c39f86410a3cd6b0ce3521029e689d63984752e | fix/db-android-core-api-contracts-20261116 at f16d97a3dfd96f2f3598396976c3ee5d63c60e6d; 10 ahead, 0 behind | Source/CI candidate only; no verified Termux ZIP or Redmi runtime success yet |

- The old infra/db-android-cloudflare-gateway-stage branch at d1c8a4dde3ec791e29e41a32604dd15c20de14b8 is divergent from the API fix branch (49 ahead/17 behind) and must not be used as a direct install source.
- The Worker ani-games-db-android-stage-gateway is deployed at https://ani-games-db-android-stage-gateway.anigamesready.workers.dev, but current KV upstream is missing; it is not online to the Redmi.
- Gateway uses an ephemeral Quick Tunnel origin behind the stable Worker hostname, refreshed periodically; not a 24/7 named-tunnel release. No custom DNS zone/named tunnel found in the connected Cloudflare account.
- CI statuses returned no check rows in this audit, and there are no verified new release artifacts. Keep all entries marked candidate/pending until evidence is fetched.

## DB Android outbound WebSocket relay stage — 2026-11-16

- Repository: anigamesready/PC-Billing.
- Work branch: infra/db-android-ws-relay-stage-20261116.
- Exact parent baseline: infra/db-android-cloudflare-global-stage-20261116 / 388fe1808a32ac13ffeeeae6fff49cbef8e7f177.
- Current work branch head: bfe419e57eefc653879ef1092bff48f7037d083a.
- Worker: ani-games-db-android-stage-ws-relay; URL https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev.
- Durable Object namespace: ani-games-db-android-stage-ws-relay_RelayHub, ID d3deb95247764649a63e05aa94962c45, SQLite; binding RELAY_HUB, migration tag v1.
- GitHub Actions: run 43829292289, conclusion SUCCESS.
- Local verification: worker/agent Node syntax PASS; 12/12 Worker/relay regression tests PASS; 3 Bash scripts syntax PASS.
- Redmi installer ZIP: ANI-GAMES-READY-DB-ANDROID-WS-RELAY-STAGE-INSTALLER.zip, size 9.8 KiB, SHA-256 fc7a65e2899fd6a16fd274a61b3c65269ba6ca2ec353e3d24c39be35d70d4b4f.
- Source ZIP: ANI-GAMES-READY-DB-ANDROID-WS-RELAY-STAGE-SOURCE.zip, size 14,863 bytes, SHA-256 f67826e2031772d312d909758d552d517fb05cc6a3b5f36dd9051333c2cac1b2.
- No app/APK version applies. No Admin APK built or changed. Worker secret, Redmi agent installation, live /health, API end-to-end, Wi-Fi/cellular login and 24-hour tests remain pending.
