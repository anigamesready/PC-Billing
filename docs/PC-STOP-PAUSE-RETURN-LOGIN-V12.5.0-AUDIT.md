# PC Billing V12.5.0 — Stop/Pause Return-to-Login Audit

Audit date: 2026-11-24  
Base branch: `audit/pc-v12.4.9-db-android-parity-20261124`  
Base commit: `1491d3a11dd9aed94016b14133ac527c7948e5a1`  
Fix branch: `fix/pc-v12.5.0-stop-pause-return-login-20261124`

## Finding

The V12.4.9 renter Stop/Pause handler checked the Owner policy and then called `stopActiveSession()`. The build gate checked that the authorization helper and timer engine existed, but it did not assert that a successful renter Stop/Pause returned the UI to the Billing Login screen or restored the native Electron Login kiosk mode.

The separate Admin stop/logout command path and the automatic-expiry path were already independent. They must not be routed through the renter-only authorization handler.

## V12.5.0 correction

- Await the existing `stopActiveSession()` routine before changing screens. This supports both synchronous and Promise-returning implementations.
- Re-show `#lock-screen`, hide `#timer-widget`, refit the Login panel to the current viewport, and focus the Login input.
- Add a sender-guarded Electron IPC that calls the existing `applyLoginKioskMode(mainWindow)` helper. The main process remains the owner of kiosk/fullscreen/window state.
- Fail visibly if the native Login transition cannot be confirmed; do not report that Login was restored when the IPC fails.
- Keep the renter authorization API and fail-closed behavior.
- Keep Admin remote commands and automatic time expiry on their existing direct `pauseSession()` paths.

## Preserved contracts

- Electron `appId` and `productName` are unchanged, preserving the existing application identity and user-data location.
- Package version advances to 12.5.0 without changing the persistent application identity.
- The PC continues to use the DB Android HTTPS Worker/API contract and existing pairing identity, tokens, rental/session state, offline outbox and sync cursor.
- No database migration, API deployment, Worker deployment, pairing reset, rental/session deletion, or Blynk/WoL configuration change is part of this patch.
- Existing timer position/size, fullscreen non-interference, READY-gated watchdog, recovery, single-instance guard, Admin controls, local WoL and disabled automatic shutdown countdown remain in the build chain.

## Automated validation added

- Assert the strict order: stop session -> show Login DOM -> restore native Login kiosk.
- Assert the main-process IPC checks its sender, renderer readiness and recovery state.
- Assert the preload bridge exposes only the new Login transition action.
- Assert timer expiry, policy check, Admin panel, DB Android policy route, pairing/outbox markers, package identity and current version markers remain present.
- Run the existing DB Android runtime smoke tests together with the new Stop/Pause Login regression tests.
- Continue the build's JS syntax checks, backend API/SQL/WSS contract checks, runtime legacy-endpoint audit, locked dependency install, Windows EXE build and app.asar allow-list check.

## Manual Windows/Stardesk verification still required

A GitHub build runner cannot prove behavior on the actual Windows PC, graphics driver or Stardesk remote display. After installing the candidate, test:
1. Start a normal rental, press Pause, and confirm the timer stops and Login Billing is shown.
2. Start another rental, press Stop and the timer X button; confirm the same Login transition.
3. Turn Owner Stop/Pause permission OFF; confirm the timer keeps running and Login is not forced.
4. Trigger Admin remote Stop and Admin Logout/Login separately; confirm their existing behavior remains correct.
5. Let a short test rental expire automatically; confirm expiry still returns to Login without invoking the renter policy gate.
6. Minimize/restore the timer, switch compact/full size, and drag it to a screen edge; confirm the saved geometry remains stable.
7. Test Ctrl+Alt+F12, single-instance launch, heartbeat/reconnect, and the existing WOL/Windows controls.

Static checks and a successful EXE build are not proof of this physical-PC test. Do not replace the stable installation until the candidate passes the target-PC checks.
