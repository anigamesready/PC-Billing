# PC Billing V12.4.2 — READY-Gated Watchdog Startup Audit

## Finding in previous startup order
The V12.3.3 boot path started both watchdog layers from Electron's `app.whenReady()` before the main Billing window was created:
- The detached watchdog agent was spawned before `createWindow()`.
- The in-process timer watchdog interval also started before `createWindow()`.

The detached process has its own Electron lock profile and does not manage the Billing window while the main PID is alive, so the two processes were not literally trying to own the same BrowserWindow. However, both watchdog layers were armed before the Billing renderer or active-session recovery was ready. This made startup ordering unnecessarily concurrent and made readiness/state interpretation harder.

## V12.4.2 architecture
- During startup, the main process writes `ready:false`, registers the emergency desktop-unlock shortcut, and creates the Billing window. It does not spawn the detached watchdog agent and does not start the in-process timer-watchdog interval.
- The existing live renderer readiness handshake remains the single gate. It is emitted only after the app's required Billing DOM and core session functions are available.
- The READY handler writes `ready:true` first, then calls `startBillingWatchdogsAfterReady()`.
- The new helper is idempotent: `billingWatchdogsStarted` prevents duplicate agent launches and a single timer handle prevents duplicate internal watchdog intervals.
- The detached watchdog agent remains a headless observer/restart supervisor. While the main Billing PID is alive it does not touch the Billing window or kiosk state.
- The in-process timer watchdog remains the only component that schedules renderer recovery while the main Electron process is alive.
- Existing normal-exit/restart paths can still ensure the detached watchdog agent remains active after a previously successful READY state.
- The Ctrl+Alt+F12 emergency unlock shortcut stays available during startup, before watchdog activation.

## State ownership
- Electron main process: sole owner of BrowserWindow, kiosk, fullscreen, z-order, and renderer reload.
- Renderer: reports readiness and timer-health pulses; it does not spawn watchdog processes or directly control the native window.
- Detached watchdog agent: handles remote restart supervision only after Billing has been ready at least once; it does not change kiosk/fullscreen or window geometry.
- Single-instance guard: main Billing instance and watchdog agent retain their separate lock profiles.

## Preserved baseline
- V12.4.1 fail-open recovery: failed renderer recovery leaves a visible normal window and Windows remains accessible.
- V12.4.0 timer position persistence and stable compact/full-size resizing.
- Existing Electron appId/productName, userData path, pairing credentials, rental/session data, WOL, shutdown timer, DB routing, and offline rental data.
- No Supabase migration, production data writes, pairing reset, or rental data changes.

## Automated checks
- Patch is baseline-checked and idempotent.
- Node syntax checks cover main/preload/renderer and the live inline page script.
- Static assertions verify no watchdog spawn/interval in the pre-window startup block; watchdog spawn and interval exist only in the READY-gated helper.
- The READY handler writes main state ready before starting either watchdog.
- One-time guard and startup emergency-unlock shortcut are preserved.
- Existing V12.4.0 timer position and V12.4.1 fail-open recovery regression assertions remain active.
- Windows portable EXE is built and packaged by GitHub Actions.

## Manual target-PC test still required
1. Start Billing from a cold boot; login UI must appear without desktop lock contention.
2. Confirm the watchdog process starts only after the Billing UI reports ready.
3. Start rental; internal timer watchdog observes timer-health pulses without opening another Billing window.
4. Force renderer recovery; only main Electron process reloads the renderer; detached agent remains passive while the main PID is alive.
5. Exit/restart from Admin; detached agent remains available and resumes remote restart supervision after the main process exits.
6. Confirm emergency Ctrl+Alt+F12 works during startup and recovery.

Static tests/build do not prove live Stardesk/Windows behavior; physical-PC verification is still required.
