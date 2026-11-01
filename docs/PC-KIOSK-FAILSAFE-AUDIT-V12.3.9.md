# PC Billing V12.3.9 — Kiosk Fail-safe Audit

## Baseline
Built from the successful V12.3.8 source/artifact on branch `fix/pc-v12.3.7-single-instance-guard`, commit `890dbe50b4b07e865d1715d5252fc44f3c0e4e08`. The V12.3.7 single-instance guard and V12.3.8 automatic wired-LAN MAC/WOL path are retained.

## Confirmed fault path
The previous `BrowserWindow` enabled `fullscreen`, `kiosk`, and `alwaysOnTop` immediately at construction, before the live `index.html` renderer proved that the billing controls and recovery flow were ready. The main process marked the app ready on `did-finish-load`, which confirms navigation completion rather than completion of the billing UI's own initialization. Renderer failure/unresponsive recovery was incomplete: login-screen failures without an active timer had no timer-health fallback, and the ordinary close/quit guard could keep intercepting a close request while the renderer was unusable.

## V12.3.9 changes
- Starts in a normal, non-kiosk, non-topmost window; kiosk mode is activated only after a renderer-ready IPC handshake from the live `index.html` page.
- The live page confirms required DOM elements and core functions after active-session recovery. Recovered sessions enter the compact timer mode; login enters kiosk mode.
- On main-frame load failure, renderer crash, renderer unresponsive state, or stale active-timer heartbeat, the main process releases kiosk/fullscreen/topmost state before a bounded reload attempt.
- Automatic renderer recovery is limited to two retries in a two-minute window. If recovery fails, the Billing window is minimized and Windows remains available.
- `Ctrl+Alt+F12` is registered as a native main-process emergency desktop-unlock shortcut. Relaunching the same EXE while in recovery mode brings the existing single instance forward and retries the renderer.
- Password-protected close remains in place during healthy operation. Close/quit is allowed when the renderer is not ready, is crashed, or the app is in recovery mode.
- The Electron `appId`, `productName`, original userData path, pairing state, local DB, active-session storage, WOL relay, and DB synchronization code are preserved.

## Regression/build checks
- Patch script is anchor-checked, idempotent, and refuses a source baseline other than V12.3.8.
- Node syntax checks: `main.js`, `preload.js`, `renderer.js`, `v11-cloud.js`, and the active inline script extracted from `index.html`.
- JSON checks and package identity/version assertions.
- Static assertions cover the renderer-ready IPC, native emergency shortcut, recovery hooks, appId/productName, WOL, watchdog, shutdown timer, global-rental and DB-route features.
- Windows portable EXE build is performed by GitHub Actions on `windows-latest`.

## Manual verification still required
Static checks/build cannot simulate an actual frozen Windows renderer or Stardesk host input. On the target PC, verify: successful login locks as before; a rental opens the compact timer; pause/expiry returns to login; launch the same EXE twice still produces one instance; deliberately force-close the renderer and verify desktop unlock/recovery; test `Ctrl+Alt+F12` and confirm taskbar/Alt+Tab/Windows controls are available. No source-level test can certify Stardesk remote-input behavior without a live PC test.

## Data-safety notes
This patch does not run migrations, clear browser/local storage, rotate pairing credentials, or replace Supabase configuration. It changes only Electron window recovery/readiness control and version metadata; the build keeps the existing persistent Electron app identity.
