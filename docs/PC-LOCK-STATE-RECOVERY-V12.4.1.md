# PC Billing V12.4.1 — Lock State / Renderer Recovery Audit

## Confirmed code-level findings in V12.4.0

1. The V12.3.9 fail-safe's `releaseDesktopLock()` disabled kiosk/fullscreen and then called `minimize()`. During a renderer crash, unresponsive event, failed load, or stale timer watchdog recovery, the Billing window therefore disappeared from the visible desktop. This matches the user's report that Billing sometimes appears to exit by itself.
2. The renderer-ready handler reset `rendererRecoveryAttempts` and `rendererRecoveryStartedAt` on every successful load. Repeated freeze/reload cycles could therefore repeatedly regain a fresh recovery budget instead of requiring a sustained healthy period.
3. The `did-start-loading` event could invoke the unlock path again while a scheduled recovery reload was already in progress, producing duplicate state transitions.
4. The kiosk mode itself is intentionally used for the login/locked state. The failure was not that kiosk exists, but that recovery transitions were not sufficiently stable and could alternate between hidden/minimized desktop and kiosk mode.

## V12.4.1 changes

- During recovery, turn off kiosk, fullscreen, and always-on-top, but keep the Billing window visible and focusable as a normal resizable window. Do not minimize it or recenter it.
- Preserve the user's ability to see the app and access the Windows taskbar/desktop while the renderer is recovering.
- Avoid duplicate recovery scheduling while a recovery is already pending.
- Do not reset the recovery attempt budget merely because the page emitted a renderer-ready event.
- Reset the bounded recovery budget only after at least 60 seconds of healthy main-process timer pulses.
- Keep a maximum of two automatic renderer reload attempts within a five-minute recovery window. If recovery still fails, leave kiosk disabled and the normal visible window in place rather than repeatedly re-locking Windows.
- Avoid a second desktop-unlock transition from `did-start-loading` when the current load is already the scheduled recovery reload.
- Preserve V12.4.0 timer position persistence, compact/full-size sizing, appId/productName, userData directory, pairing, rental data, watchdog credentials, WOL, shutdown timer, and DB routing. No database migration or production data writes are part of this patch.

## Validation requirements

Automated build checks:
- Node syntax validation for main/preload/renderer/live index script.
- Patch script compilation and baseline/version assertions.
- Static assertions that recovery does not call `.minimize()` or `.center()`.
- Static assertions that the recovery budget is not reset in the renderer-ready handler and only resets after 60 seconds of healthy pulses.
- Static assertion for duplicate-recovery protection and bounded retry count.
- Existing V12.4.0 timer position regression checks and persistent app identity checks.

Manual PC/Stardesk tests still required:
1. Start Billing normally and confirm login kiosk works as designed.
2. Start a rental, minimize/restore the timer using its own compact control, and confirm countdown continues.
3. Simulate renderer reload/restart while a rental is active; the Billing window must remain visible in a normal window during recovery, and Windows taskbar must be accessible.
4. Simulate repeated renderer recovery failure; after two attempts, kiosk must stay disabled and Billing must not disappear/minimize or re-lock the desktop.
5. After a stable minute, verify the recovery budget is reset and normal kiosk login works again after rental stop/expiry.
6. Confirm Ctrl+Alt+F12 emergency unlock, normal session end, pairing resume, and timer position persistence.

Build/static tests do not prove behavior under every physical GPU/remote-desktop failure. Install only after the EXE artifact is successfully built and verified, then perform the manual tests above.
