# PC Billing V12.3.7 — Single-instance audit

Audit baseline: `anigamesready/PC-Billing`, build artifact `AniGames-PC-V12.3.6-WOL-RELAY`, workflow run #118, commit `248af9f1e2e256d6dd3042b2e80eb8f7819655dc`.

## Findings

- The Electron main process did not call `app.requestSingleInstanceLock()`. Repeated desktop shortcuts, auto-start entries, or manual launches could therefore create multiple Billing main processes and multiple visible billing/timer runtimes.
- The V12.3.3 watchdog was intentionally a detached second Electron process. Its PID-file check was not a system-level singleton lock and was separate from a guard for the visible Billing process.
- The PC package has a stable `appId` (`com.anigames.billing.v12test`) and stable `productName` (`AniGames Billing V12.3.3`) in the V12.3.6 package. These values are deliberately retained so later releases continue using the same Windows application identity and user-data folder.

## V12.3.7 changes

- Acquire an Electron single-instance lock for the visible Billing process before startup.
- On a second launch, exit the duplicate process and bring the already-running Billing window to the front.
- Give the detached watchdog a separate lock profile, so its legitimate background process does not collide with the Billing main-process lock and duplicate watchdog agents are rejected.
- Keep watchdog credential/state files in the original Billing user-data directory.
- Preserve `appId`, `productName`, pairing token/device ID, localStorage keys, local backups, rental data, and Supabase schema.

## Validation boundaries

The patch is guarded by exact V12.3.6 source anchors, checks the stable app identity values, and runs JavaScript syntax plus repository regression checks in the Windows GitHub Actions build. A successful build is not a substitute for a live Windows test: start Billing, launch the same EXE again from its shortcut and from the EXE file, confirm only one Billing UI/timer remains, then test restart/exit and watchdog recovery.