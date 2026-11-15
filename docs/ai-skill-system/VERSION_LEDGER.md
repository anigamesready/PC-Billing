# Version & Source Ledger

Revalidate live repository refs and artifact metadata before every source/build task. These are source baselines, not proof that DB Android builds are ready.

| Product / track | Current recorded baseline | Branch | Source baseline commit | Current work branch head | Package / version code |
|---|---|---|---|---|---|
| PC Billing DB Android | V12.4.8 | `pc-billing-v12.4.8-DB-Android` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | Windows EXE; verify build metadata from current source |
| PC Billing recovery — DB1 Direct | V12.4.9 | `recovery/pc-v12.4.9-db1-direct-20261114` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `0565a8a225793e8785ca17f9079a15b753a834f1` | Windows portable EXE; `com.anigames.billing.v12test`; legacy `productName` unchanged |
| Admin DB Android | V12.1.50 | `admin-v12.1.50-DB-Android` | `9460e8dcbdbf69706408dd0507016cf0037ff153` | `be56ede591c6ebc42b99a02e7731228e02ac40d4` | versionCode 78; applicationId `com.anigames.billingadmin.v150` |
| Reseller DB Android | V1.0.6 | `reseller-v1.0.6-DB-Android` | `a67c2f6318230671a7d7776bf6040c39bca6ff97` | `62e14e8caea62c50269cd62f4122efeed19e8731` | versionCode 136; applicationId must be re-read from source/build |
| Redmi DB Android schema/API core | schema reference v1 | `backend/db-android-core-v1` | PC DB Android baseline `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `8e9797628ec4508dd5251d32d2a6faa983c7d106` | Not an app build; 24-table core schema + DB1 catalog/contract audit |

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

## Artifact ledger
No new APK/EXE artifact was produced. The infrastructure helper artifact above is separate from application releases; Redmi runtime acceptance is still pending.
