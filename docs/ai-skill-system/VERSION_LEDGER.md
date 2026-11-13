# Version & Source Ledger

Update this file at the start and end of every source/build task. Re-fetch full SHAs and artifact metadata before using any row.

| Product | Current recorded baseline | Branch | Source baseline commit | Work branch head (2026-11-14 snapshot) | Package / version code |
|---|---|---|---|---|---|
| PC Billing | V12.4.8 | `pc-billing-v12.4.8-DB-Android` | `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19` | `f938c574dfbd17ab84b07ca940115a280d3f8d78` | Windows EXE; verify package metadata in current source/build |
| Admin APK | V12.1.46 | `admin-v12.1.46-DB-Android` | `26f1571f6a31ac3eaea3fc8a698fea1d157d08f3` | `c97a5a6221f80841726bb9499bdef1c4759980a1` | versionCode 74; package must be re-read from manifest |
| Reseller APK | V1.0.6 | `reseller-v1.0.6-DB-Android` | `a67c2f6318230671a7d7776bf6040c39bca6ff97` | `e2147095432b37bba806b14c6948291248b28ccf` | versionCode 136; package must be re-read from manifest |

## Artifact ledger (not yet verified in this Skill System creation)
No new APK/EXE artifact was built or downloaded for this task. Do not reuse older sandbox artifacts as current releases. Record artifact path/URL, workflow run ID, exact source commit, package/version, file size and SHA-256 when a build is performed.
