# V13 Source Provenance Correction — 2026-10-26

The user has identified the exact Admin V12.1.27 build source:
https://github.com/anigamesready/Admin-Ani-Games/actions/runs/39722321384

Verified metadata:
- Workflow result: completed / success.
- Workflow: Build AniGames Admin V12.1.27 Login Route Refresh Fix APK.
- Branch: `feature/admin-v12.1.19-global-route-continuity`.
- Commit: `9642c2f2f985eeef4df92bd9bff62df07fa625b0`.
- APK version: `12.1.27`; versionCode `55`; applicationId `com.anigames.billingadmin`.
- Artifact: `AniGames-Admin-Android-v12.1.27-final-debug-apk`, 638,800 bytes, SHA-256 reported by GitHub artifact metadata as `aaaa3f7cce49f223cfb2d6e57a0232760715777216440b0b6d7102516d4a6842`, expires 2026-11-21.
- Build steps include source extraction, sequential application of Admin patches through `patch_admin_v12_1_27_login_click_route_refresh.py`, static JS/safety assertions, Gradle build, APK package/version/signature verification, and artifact upload. Workflow success confirms build/package checks passed; it does not confirm live backend or dual-DB end-to-end readiness.

Important distinction: this run is for the **Admin Android APK**, not the PC Billing executable. The workflow starts from `AniGames-Admin-V12.1.4-ANDROID-PASSWORD-RESET-PATCH-v3.zip` and applies later Admin patches. The PC repository branch `release/v13-dual-db-base-candidate` remains a separate PC source candidate. Do not treat the Admin APK as the PC Billing source archive or automatically rename the PC executable based on this run.

The Admin repo's `docs/DUAL-DB-APP-INTEGRATION-CONTRACT.md` explicitly marks the shared resolver as a proposal, not a live endpoint. It states that production targets must not change until the backend publishes and verifies it. Therefore this exact V12.1.27 source is a valid reference for the **Admin APK baseline**, while dual-DB migration remains blocked by live route flags, row parity, auth identity, and the conflicting open rental session described in the main audit.

Links:
- [Build run](https://github.com/anigamesready/Admin-Ani-Games/actions/runs/39722321384)
- [Exact source commit](https://github.com/anigamesready/Admin-Ani-Games/commit/9642c2f2f985eeef4df92bd9bff62df07fa625b0)
- [Dual-DB contract at that commit](https://github.com/anigamesready/Admin-Ani-Games/blob/9642c2f2f985eeef4df92bd9bff62df07fa625b0/docs/DUAL-DB-APP-INTEGRATION-CONTRACT.md)

No production source branch, database row, route flag, or deployment was changed while verifying this source.
