from pathlib import Path
import json

ROOT = Path(".")
main_path = ROOT / "main.js"
index_path = ROOT / "index.html"
renderer_path = ROOT / "renderer.js"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
version_path = ROOT / "VERSION.txt"

for path in (main_path, index_path, renderer_path, package_path, lock_path, version_path):
    if not path.is_file():
        raise SystemExit("Required V12.4.6 source missing: " + str(path))

main = main_path.read_text(encoding="utf-8")
index = index_path.read_text(encoding="utf-8")
renderer = renderer_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))

OLD = "V12.4.6-RESPONSIVE-DISPLAY-FIT"
NEW = "V12.4.7-FIVEM-FOCUS-SAFE-RECOVERY"

if NEW in index and "FIVEM_FOCUS_SAFE_RECOVERY" in main:
    print("PASS: V12.4.7 focus-safe recovery patch already applied")
    raise SystemExit(0)

if package.get("version") != "12.4.6" or lock.get("version") != "12.4.6" or OLD not in index:
    raise SystemExit("Expected exact V12.4.6 source baseline; refusing patch.")
if package.get("build", {}).get("appId") != "com.anigames.billing.v12test":
    raise SystemExit("Persistent Electron appId changed; refusing patch.")
if package.get("build", {}).get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("Persistent Electron productName changed; refusing patch.")

def once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor mismatch: expected 1, found {count}")
    return source.replace(old, new, 1)

watchdog_old = """            const stale=Date.now()-Number(timerHealth.at||0)>12000;
            const stuck=Number(timerHealth.mismatchCount||0)>=2;
            if((stale||stuck)&&Date.now()-lastTimerRecoveryAt>20000){
                lastTimerRecoveryAt=Date.now();
                scheduleRendererRecovery(mainWindow,stale?'Heartbeat timer terhenti':'Tampilan timer tidak sinkron',1800);
            }"""
watchdog_new = """            const stale=Date.now()-Number(timerHealth.at||0)>12000;
            const stuck=Number(timerHealth.mismatchCount||0)>=2;
            const billingHasForegroundFocus=typeof mainWindow.isFocused==='function'&&mainWindow.isFocused();
            // Never let a stale UI pulse steal focus from a running fullscreen game.
            // A genuine renderer failure is still handled by Electron's crash/load events.
            if((stale||stuck)&&!billingHasForegroundFocus)return;
            if((stale||stuck)&&billingHasForegroundFocus&&Date.now()-lastTimerRecoveryAt>20000){
                lastTimerRecoveryAt=Date.now();
                scheduleRendererRecovery(mainWindow,stale?'Heartbeat timer terhenti':'Tampilan timer tidak sinkron',1800);
            }"""
main = once(main, watchdog_old, watchdog_new, "Foreground-safe timer watchdog")

focus_anchor = """    const protectedWindow = mainWindow;
    protectedWindow.on('move', () => queuePersistTimerWindowPosition(protectedWindow));"""
focus_replacement = """    const protectedWindow = mainWindow;
    // FIVEM_FOCUS_SAFE_RECOVERY: defer stale-pulse recovery until the user returns to Billing.
    protectedWindow.on('focus', () => {
        if (WATCHDOG_AGENT_MODE || !billingUiReady || billingRecoveryMode ||
            !mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode || rendererRecoveryPending) return;
        const stale = Date.now() - Number(timerHealth.at || 0) > 12000;
        const stuck = Number(timerHealth.mismatchCount || 0) >= 2;
        if ((stale || stuck) && Date.now() - lastTimerRecoveryAt > 20000) {
            lastTimerRecoveryAt = Date.now();
            scheduleRendererRecovery(protectedWindow, stale ? 'Heartbeat timer terhenti setelah kembali ke Billing' : 'Tampilan timer tidak sinkron setelah kembali ke Billing', 700);
        }
    });
    protectedWindow.on('move', () => queuePersistTimerWindowPosition(protectedWindow));"""
main = once(main, focus_anchor, focus_replacement, "Deferred recovery on Billing focus")

release_old = """      if(w.isMinimized())w.restore();w.show();w.focus();"""
release_new = """      if(typeof w.showInactive==='function')w.showInactive();else w.show();"""
main = once(main, release_old, release_new, "Non-activating renderer recovery")

active_old = """function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=true;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);if(w.isMinimized())w.restore();applyTimerWindowGeometry(w,500,76);w.show();}"""
active_new = """function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=true;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);applyTimerWindowGeometry(w,500,76);if(typeof w.showInactive==='function')w.showInactive();else w.show();}"""
main = once(main, active_old, active_new, "Non-activating floating timer")

ready_context_old = """  const p=payload&&typeof payload==='object'?payload:{};const active=p.activeSession===true;const code=String(p.activeCode||'').trim().slice(0,128)||null;const deadline=Number(p.deadlineMs);"""
ready_context_new = """  const p=payload&&typeof payload==='object'?payload:{};const preserveForeground=Boolean(recoveryReloadInProgress||billingRecoveryMode);const active=p.activeSession===true;const code=String(p.activeCode||'').trim().slice(0,128)||null;const deadline=Number(p.deadlineMs);"""
main = once(main, ready_context_old, ready_context_new, "Capture foreground ownership before renderer READY")
main = once(main, "if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);",
            "if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow,null,!preserveForeground);",
            "Focus-safe renderer READY transition")

if index.count(OLD) < 2:
    raise SystemExit("Expected V12.4.6 runtime and visible version markers in index.html.")
if OLD not in renderer:
    raise SystemExit("Expected V12.4.6 marker in renderer.js.")
index = index.replace(OLD, NEW)
renderer = renderer.replace(OLD, NEW)
package["version"] = "12.4.7"
package["description"] = "AniGames Billing V12.4.7: focus-safe renderer watchdog and non-activating timer/recovery windows; preserves V12.4.6 responsive display fit, rental data and pairing."
lock["version"] = "12.4.7"
if isinstance(lock.get("packages"), dict) and isinstance(lock.get("packages").get(""), dict):
    lock["packages"][""]["version"] = "12.4.7"

main_path.write_text(main, encoding="utf-8")
index_path.write_text(index, encoding="utf-8")
renderer_path.write_text(renderer, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text(
    NEW + "\n"
    "Timer health recovery is deferred while another application owns foreground focus. "
    "Recovery and active timer windows use non-activating show operations. "
    "A stale timer pulse is checked again when Billing regains focus.\n",
    encoding="utf-8",
)

watchdog_start = main.index("function startBillingWatchdogsAfterReady")
watchdog_end = main.index("app.whenReady().then", watchdog_start)
watchdog = main[watchdog_start:watchdog_end]
if "mainWindow.isFocused()" not in watchdog or "if((stale||stuck)&&!billingHasForegroundFocus)return;" not in watchdog:
    raise SystemExit("Foreground focus guard missing from in-process timer watchdog.")

release_start = main.index("function releaseDesktopLock")
release_end = main.index("function armRendererReadyTimeout", release_start)
release = main[release_start:release_end]
if "showInactive" not in release or ".focus()" in release:
    raise SystemExit("Recovery still activates Billing or lacks showInactive().")

active_start = main.index("function applyActiveTimerWindowMode")
active_end = main.index("function releaseDesktopLock", active_start)
active = main[active_start:active_end]
if "showInactive" not in active or ".focus()" in active:
    raise SystemExit("Active timer window can still steal foreground focus.")

if "protectedWindow.on('focus'" not in main or "scheduleRendererRecovery(protectedWindow" not in main:
    raise SystemExit("Deferred recovery-on-focus handler is missing.")

ready_start = main.index("ipcMain.on('billing-renderer-ready'")
ready_end = main.index("ipcMain.on('set-lock-mode'", ready_start)
ready = main[ready_start:ready_end]
if "preserveForeground=Boolean(recoveryReloadInProgress||billingRecoveryMode)" not in ready:
    raise SystemExit("Renderer READY does not capture recovery foreground state.")
if "applyLoginKioskMode(mainWindow,null,!preserveForeground)" not in ready:
    raise SystemExit("Renderer READY may refocus Billing after recovery.")

if package.get("version") != "12.4.7" or lock.get("version") != "12.4.7":
    raise SystemExit("Package versions are inconsistent.")
if package.get("build", {}).get("appId") != "com.anigames.billing.v12test":
    raise SystemExit("Electron appId was changed.")
if package.get("build", {}).get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("Electron productName was changed.")
if NEW not in index or NEW not in renderer:
    raise SystemExit("Visible/runtime version markers are inconsistent.")

print("PASS: V12.4.7 focus-safe recovery; stale watchdog recovery waits until Billing is foreground; focus return re-checks stale state; renderer recovery and active timer use showInactive; package identity, pairing, and rental data paths preserved.")
