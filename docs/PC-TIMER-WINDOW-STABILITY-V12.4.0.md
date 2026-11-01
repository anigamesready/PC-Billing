# PC Billing V12.4.0 — Timer Window Size & Position Stability Audit

## User-visible fault confirmed in V12.3.9
The active Electron runtime had two independent paths that forced the floating timer back to the center:
- `applyActiveTimerWindowMode()` changed the main window to 500×76 and called `center()` whenever a session became active or was resumed.
- The `resize-timer-window` IPC handler called `setContentSize()` followed by `center()`. The active page also sent resize notifications after DOM/window resize events.

As a result, compact/full-size changes, session mode transitions, or a renderer resize notification could move a timer that the operator had dragged to a screen edge back to the center. The resize messages had no same-size guard, so the renderer could send redundant size updates after Electron resized the BrowserWindow.

## V12.4.0 changes
- Removes forced centering from active timer mode and from the timer resize IPC path.
- Saves the native Electron window's x/y coordinates to `ani-games-timer-window-position.json` under the existing app userData folder. This is a small local UI-preference file, separate from rental data, pairing state, and Supabase.
- Persists native window movement with a short debounce; restores the saved position on subsequent active sessions.
- Preserves the current top-left position when changing between normal timer (500×76) and compact timer (220×54).
- Clamps the window into a display's work area after monitor removal/addition or display-metrics changes, so it cannot remain outside the visible desktop.
- Adds an IPC sender/readiness/mode guard and size bounds to prevent unexpected or stale renderer messages from resizing the wrong window.
- Makes renderer size notifications idempotent using a width×height key; a resize caused by Electron's own size change does not trigger repeated resize commands.
- Keeps the existing draggable title/content region and buttons intact.

## Static and local regression checks performed
- Applied the patch to an extracted V12.3.9 source tree.
- Re-applied the patch a second time; it safely reported already applied rather than duplicating code.
- Passed Node syntax checks for `main.js`, `preload.js`, `renderer.js`, `v11-cloud.js`, and the live inline script extracted from `index.html`.
- Passed Python compile validation for the patch script and JSON parsing/version checks for package manifests.
- Executed isolated position-clamp tests: an on-screen position remains unchanged; an off-screen position is clamped to the visible work area.
- Asserted that the active timer mode and resize IPC handler no longer call `.center()`.
- Asserted that move persistence, display clamping, and renderer size deduplication are present.

## Preserved baseline
- Electron appId remains `com.anigames.billing.v12test`.
- Electron productName remains `AniGames Billing V12.3.3` to preserve the installed application identity.
- Existing userData path, pairing credentials, rental/session data, dual-DB routing, offline rental flow, watchdog, WOL, shutdown timer, and V12.3.9 kiosk fail-safe remain in the build chain.
- No Supabase migration, live database write, pairing reset, or customer/rental data modification is part of this patch.

## Manual test still required on target PC
The automated build cannot reproduce the exact monitor/DPI/remote-desktop behavior of the user's Stardesk session. After installing V12.4.0, verify:
1. Start a rental and drag the timer to a screen edge.
2. Switch to compact and back to full size; the top-left position should remain stable.
3. Pause/stop and start another rental; the prior position should be restored.
4. Reconnect Stardesk or change remote display resolution; the timer should remain visible and should not jump to center.
5. Confirm the login kiosk, Ctrl+Alt+F12 desktop recovery, and existing rental countdown still work.

Build/syntax/static tests are not a substitute for that final physical-PC verification.
