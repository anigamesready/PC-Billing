# Ani Games Billing PC V12.4.7 — FiveM Focus / Timer Reload Audit

## Symptom and evidence

The supplied recording shows FiveM gameplay, then the Billing timer remains alive while the visible desktop/game view changes. The recording does not prove that the FiveM process crashed; it is consistent with the game losing foreground focus and being minimized or covered.

## Code path found in the latest V12.4.5 build chain

1. The V12.3.3 renderer emits a timer-health pulse every 3 seconds.
2. The V12.4.2 in-process watchdog treats a pulse older than 12 seconds, or repeated timer/display mismatch, as a stuck renderer and calls scheduleRendererRecovery().
3. V12.4.1 recovery calls releaseDesktopLock(), which changes kiosk/fullscreen state before reloading the renderer.
4. The pre-fix recovery path called show() and focus() on the Billing BrowserWindow. The active timer mode also used show().

That meant a false-positive timer-health recovery during an active game could activate Billing, take foreground focus away from FiveM, and expose the Windows desktop while the timer renderer reloaded. This is the strongest code-level explanation for the observed “FiveM balik desktop + timer refresh” combination. It is not proof that the game executable itself exited.

## V12.4.7 changes

- Keep the timer watchdog and its 12-second stale-pulse threshold, but do not start a recovery reload while Billing is not the focused foreground window.
- Re-check a deferred stale/mismatch condition when Billing receives focus. A real stuck renderer can still be recovered when the user returns to Billing.
- Use Electron showInactive() during renderer recovery and active timer restoration so Billing does not activate itself over a running game.
- Preserve foreground ownership during the renderer READY transition. Normal first launch / intentional Login behavior is unchanged.
- Patch only the live Electron `index.html` runtime. The legacy `renderer.js` sidecar is deliberately left untouched because the build/runtime checks confirm Electron does not load it.
- Keep the timer-health pulse interval, rental deadline calculation, cloud heartbeat, global rental DB flow, offline queue, pairing, watchdog-agent supervision, WOL, and direct Windows controls unchanged.
- Preserve the existing Electron appId, productName, and userData directory so installed pairing tokens and rental/session storage stay in place.

## Validation boundaries

The patch script checks its exact V12.4.6 baseline and fails closed if an anchor differs. GitHub Actions additionally runs JavaScript syntax checks, the live index.html inline script check, Python compile checks, regression assertions for the pre-existing rental/DB/WOL/Windows-control paths, and a clean Windows portable EXE build.

A live FiveM + Stardesk test on the rental PCs is still required to confirm the real foreground behavior under their GPU/driver/display configuration. The supplied video is evidence of the symptom, not a Windows process dump.
