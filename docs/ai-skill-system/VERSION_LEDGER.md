# Version & Source Ledger

Revalidate live repository refs and artifact metadata before every source/build task. These are source baselines, not proof that DB Android builds are ready.

| Product / track | Current recorded baseline | Branch | Source baseline commit | Current work branch head | Package / version code |
|---|---|---|---|---|---|
| PC Billing DB Android | V12.4.8 | `pc-billing-v12.4.8-DB-Android` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | Windows EXE; verify build metadata from current source |
| Admin DB Android | V12.1.50 | `admin-v12.1.50-DB-Android` | `9460e8dcbdbf69706408dd0507016cf0037ff153` | `be56ede591c6ebc42b99a02e7731228e02ac40d4` | versionCode 78; applicationId `com.anigames.billingadmin.v150` |
| Reseller DB Android | V1.0.6 | `reseller-v1.0.6-DB-Android` | `a67c2f6318230671a7d7776bf6040c39bca6ff97` | `62e14e8caea62c50269cd62f4122efeed19e8731` | versionCode 136; applicationId must be re-read from source/build |
| Redmi DB Android schema/API core | schema reference v1 | `backend/db-android-core-v1` | PC DB Android baseline `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `8e9797628ec4508dd5251d32d2a6faa983c7d106` | Not an app build; 24-table core schema + DB1 catalog/contract audit |

## Build workflow caveats
- PC V12.4.8 workflow push trigger is the original `fix/pc-v12.4.8-timer-size-sync` branch, not the DB Android branch.
- Admin V12.1.50 workflow remains Supabase/dual-DB and excludes `admin-v12.1.50-DB-Android` from automatic push.
- Reseller V1.0.6 workflow remains Supabase DB1/DB2 and excludes `reseller-v1.0.6-DB-Android` from automatic push.
- No APK/EXE was built, downloaded or verified during the 2026-11-14 activation audit.

## Artifact ledger
No new APK/EXE artifact was produced for this task. Record exact workflow run, source commit, source archive SHA-256, patch list, package/version, file size and artifact SHA-256 whenever a future build is explicitly requested and actually completed.
