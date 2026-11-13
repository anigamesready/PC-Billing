# Project Registry — verified snapshot 2026-11-14

This is a starting map, not a permanent truth. Re-check GitHub before every task.

## Active product tracks

| Product | Repository | Work branch | Exact head commit | Parent/source baseline |
|---|---|---|---|---|
| PC Billing DB Android | `anigamesready/PC-Billing` | `pc-billing-v12.4.8-DB-Android` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | `fix/pc-v12.4.8-timer-size-sync` at `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`; app V12.4.8 |
| Admin DB Android | `anigamesready/Admin-Ani-Games` | `admin-v12.1.46-DB-Android` | `c97a5a6221f80841726bb9499bdef1c4759980a1` | `feature/admin-v12.1.46-monthly-yearly-member-rankings` at `26f1571f6a31ac3eaea3fc8a698fea1d157d08f3`; APK V12.1.46, versionCode 74 |
| Reseller DB Android | `anigamesready/Admin-Ani-Games` | `reseller-v1.0.6-DB-Android` | `e2147095432b37bba806b14c6948291248b28ccf` | `release/reseller-v1.0.6-remember-login-rental-status` at `a67c2f6318230671a7d7776bf6040c39bca6ff97`; APK V1.0.6, versionCode 136 |

These three branches were created from the exact baselines documented in their branch audit files. The latest commit on each DB Android branch is an audit/documentation commit; inspect its parent before treating it as a runtime change.

## Repository observations from audit

### PC Billing — `anigamesready/PC-Billing`
- Public repository; default branch `main`.
- At audit time, `main` head was `9796f2d83d...` (2026-11-01) and was not the V12.4.8 DB Android source.
- Relevant active branch `pc-billing-v12.4.8-DB-Android` head: `f938c574...` (2026-11-13).
- Its workflow `.github/workflows/build-pc-v12-4-8-timer-size-sync.yml` extracts the older named source ZIP and applies ordered patch scripts. It does not automatically build this DB Android branch on push; manual dispatch alone is not evidence of DB Android compatibility.
- Audit file: `docs/DB-ANDROID-PC-AUDIT.md`.
- Key backend contract includes device sync cursor/pull, rental lookup, session start/end, rental release, pairing/enrollment, heartbeat, command acknowledgement and offline lease/conflict handling.

### Admin — `anigamesready/Admin-Ani-Games`
- Public repository; default branch `main`.
- At audit time, `main` head was `810bb3a879...` (2026-10-15), while the Admin DB Android branch head was `c97a5a6221...` (2026-11-13).
- Admin DB Android source branch is V12.1.46 and has its own audit file.
- Existing Admin build workflow is Supabase/dual-DB dependent and is not automatically a PostgreSQL/Redmi DB build.

### Reseller — same repository, separate product track
- Work branch `reseller-v1.0.6-DB-Android`, distinct from Admin branch.
- Uses `build-reseller-apk.yml`, not the Admin APK workflow.
- Source archive is `Ani-Games-Reseller-Android-SOURCE-v11.30.0.zip`; pipeline verifies archive/template hashes and applies reseller patch chain.
- Existing remembered-login patch stores username and password in WebView localStorage; DB Android work must review this security risk and should move to revocable short-lived session credentials with Android Keystore-backed storage where feasible.
- Reseller must remain restricted to its own rental records; no direct SQL, Admin/Owner role, PC pairing, Windows, shutdown, WoL, or relay controls.

## Legacy / candidate repositories (do not assume authoritative)
- `anigamesready/Billing_Rental`: branch `main` head `590a7af8...` dated 2026-10-06; branch `audit/admin-web-source-inventory` exists. Root contains `Billing-WEB-MASTER-v11.26.0-android-mobile-ux.zip`. Needs explicit source lineage audit before Admin Web work.
- `anigamesready/Billing_Ani_Games`: `main` head `1fdaae1c...` dated 2026-10-11; includes `audit/billing-android-source-inventory`, `build/v12-admin-12.1.0`, `patch/v12-db-routing`, `release/v11.29.2-rental-delete-windows-ack`, and `reseller-v1.0.0`. Not selected as current Admin/Reseller source.
- `anigamesready/Billing`: `main` head `87d1c6c7...` dated 2026-10-10; legacy V11.29.0 Supabase Direct source archive.
- Repository default branches and push dates are not enough to select a product source.

## Required source revalidation
For every new task, query live repository metadata and:
1. enumerate relevant branches;
2. read full head SHA, commit date/message and parent;
3. inspect branch audit docs and full recursive tree;
4. inspect build workflow triggers and source archive;
5. inspect releases/workflow artifacts when the user requests a build;
6. compare candidate baselines and record the chosen lineage in the handover.

Full SHA and current workflow details must be re-fetched before any code edit/build. This snapshot must be updated when the authoritative branch changes.
