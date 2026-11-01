from pathlib import Path
import json
import re

ROOT = Path(".")
main_path = ROOT / "main.js"
html_path = ROOT / "index.html"
cloud_path = ROOT / "v11-cloud.js"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
version_path = ROOT / "VERSION.txt"

for path in (main_path, html_path, cloud_path, package_path, lock_path):
    if not path.is_file():
        raise SystemExit("Required PC source file missing: " + str(path))

main = main_path.read_text(encoding="utf-8")
html = html_path.read_text(encoding="utf-8")
cloud = cloud_path.read_text(encoding="utf-8")

# Purge the exact persisted shutdown countdown before any Billing scripts initialize.
purge_marker = "ANI_GAMES_V12_4_3_PURGE_LEGACY_SHUTDOWN_TIMER"
purge_script = r"""<script>
/* ANI_GAMES_V12_4_3_PURGE_LEGACY_SHUTDOWN_TIMER */
(function () {
    try { localStorage.removeItem('billing_shutdown_timer_v12'); } catch (_) {}
    try { sessionStorage.removeItem('billing_shutdown_timer_v12'); } catch (_) {}
    window.__ANI_GAMES_SHUTDOWN_TIMER_DISABLED__ = true;
})();
</script>
"""
if purge_marker not in html:
    head = re.search(r"<head(?:\s[^>]*)?>", html, flags=re.IGNORECASE)
    if not head:
        raise SystemExit("index.html <head> anchor missing; refusing unsafe patch.")
    html = html[:head.end()] + "\n" + purge_script + html[head.end():]

# Remove the whole 1-second countdown engine. The separate rental timer is untouched.
timer_start_marker = "// V12.1.8 scheduled shutdown."
timer_end_marker = "window.v11ApplyRemoteCommand = async (command, payload = {}) => {"
start = html.find(timer_start_marker)
end = html.find(timer_end_marker)
if start >= 0:
    if end <= start:
        raise SystemExit("Shutdown timer module boundaries invalid; refusing partial removal.")
    html = html[:start] + """// V12.4.3-EMERGENCY: legacy shutdown countdown removed.
        try { localStorage.removeItem('billing_shutdown_timer_v12'); } catch (_) {}
        window.__ANI_GAMES_SHUTDOWN_TIMER_DISABLED__ = true;

        """ + html[end:]
elif any(x in html for x in ("function v12CheckScheduledShutdown()", "V12_SHUTDOWN_TIMER_KEY")):
    raise SystemExit("Shutdown timer module found but its expected start marker changed.")

# Remove timer schedule/cancel execution and disable direct Admin shutdown in this build.
remote_start = "            if (cmd === 'cancel_shutdown_timer') {"
remote_end = "            // V12.1.1: use a dedicated Electron BrowserWindow"
start = html.find(remote_start)
end = html.find(remote_end, start if start >= 0 else 0)
replacement = """            if (cmd === 'cancel_shutdown_timer') {
                try { localStorage.removeItem('billing_shutdown_timer_v12'); } catch (_) {}
                return {ok:true, state:'canceled', message:'Timer shutdown sudah dihapus dari build PC ini.'};
            }
            if (cmd === 'schedule_shutdown') {
                return {ok:false, ignored:true, error:'SHUTDOWN_TIMER_DISABLED', message:'Fitur countdown shutdown sudah dinonaktifkan pada PC Billing.'};
            }
            if (cmd === 'shutdown') {
                return {ok:false, ignored:true, error:'SHUTDOWN_DISABLED', message:'Perintah shutdown dinonaktifkan pada build emergency.'};
            }

"""
if start >= 0:
    if end <= start:
        raise SystemExit("Remote shutdown command block boundaries invalid; refusing partial removal.")
    html = html[:start] + replacement + html[end:]
elif any(x in html for x in ("if (cmd === 'schedule_shutdown')", "if (cmd === 'cancel_shutdown_timer')")):
    raise SystemExit("Remote shutdown command cases found outside expected block.")

for forbidden in (
    "function v12CheckScheduledShutdown()",
    "function v12ShutdownScheduleFromAdmin(",
    "function v12CancelScheduledShutdown(",
    "window.__v12ShutdownTimerInterval",
    "V12_SHUTDOWN_TIMER_KEY",
):
    if forbidden in html:
        raise SystemExit("Shutdown countdown runtime remains in index.html: " + forbidden)
for required in (
    "ANI_GAMES_V12_4_3_PURGE_LEGACY_SHUTDOWN_TIMER",
    "SHUTDOWN_TIMER_DISABLED",
    "SHUTDOWN_DISABLED",
):
    if required not in html:
        raise SystemExit("Emergency shutdown guard missing from index.html: " + required)

# Stop re-publishing persisted shutdown countdown metadata to Supabase.
cloud = cloud.replace(",shutdownTimer:window.v11GetShutdownTimerStatus?.()||null", "")
if "shutdownTimer:window.v11GetShutdownTimerStatus?.()||null" in cloud:
    raise SystemExit("Shutdown timer heartbeat metadata still present.")
cloud_path.write_text(cloud, encoding="utf-8")

# Cancel a stale Windows shutdown.exe countdown before Billing opens.
startup_marker = "ANI_GAMES_V12_4_3_CANCEL_PENDING_WINDOWS_SHUTDOWN"
if startup_marker not in main:
    helper = """
// ANI_GAMES_V12_4_3_CANCEL_PENDING_WINDOWS_SHUTDOWN
function cancelPendingWindowsShutdownOnLaunch() {
    return new Promise(resolve => {
        if (process.platform !== 'win32') return resolve();
        const { execFile } = require('child_process');
        execFile('shutdown.exe', ['/a'], { windowsHide: true }, () => resolve());
    });
}

"""
    ready_anchor = "app.whenReady().then(() => {"
    if main.count(ready_anchor) != 1:
        raise SystemExit("main.js app.whenReady anchor mismatch; refusing patch.")
    main = main.replace(
        ready_anchor,
        "app.whenReady().then(async () => {\n    if (!DUPLICATE_BILLING_PROCESS && !WATCHDOG_AGENT_MODE) await cancelPendingWindowsShutdownOnLaunch();",
        1,
    )
    ready_index = main.find("app.whenReady().then(async () => {")
    if ready_index < 0:
        raise SystemExit("main.js async startup anchor missing after patch.")
    main = main[:ready_index] + helper + main[ready_index:]

# Main-process safety backstop: no renderer can issue a shutdown in the emergency build.
power_anchor = "ipcMain.handle('power-action', async (event, action) => {"
if "ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN_IPC" not in main:
    if main.count(power_anchor) != 1:
        raise SystemExit("main.js power-action IPC anchor mismatch; refusing patch.")
    guard = """    // ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN_IPC
    if (String(action || '').toLowerCase() === 'shutdown') {
        console.warn('[AniGames] Shutdown dinonaktifkan pada build emergency V12.4.3.');
        return { ok:false, error:'SHUTDOWN_DISABLED', message:'Shutdown dinonaktifkan pada build emergency.' };
    }
"""
    main = main.replace(power_anchor, power_anchor + "\n" + guard, 1)

for required in (
    "ANI_GAMES_V12_4_3_CANCEL_PENDING_WINDOWS_SHUTDOWN",
    "shutdown.exe', ['/a']",
    "ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN_IPC",
):
    if required not in main:
        raise SystemExit("Emergency main.js guard missing: " + required)

main_path.write_text(main, encoding="utf-8")

# Bump to V12.4.3 while keeping appId/productName unchanged (preserves Electron userData).
package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if package.get("version") != "12.4.2" or lock.get("version") != "12.4.2":
    raise SystemExit("Expected source version 12.4.2 after existing patches; refusing unknown baseline.")
package["version"] = "12.4.3"
package["description"] = "AniGames Billing V12.4.3 emergency shutdown countdown removal; preserves V12.4.2 watchdog-after-ready."
lock["version"] = "12.4.3"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.4.3"

html = html.replace("V12.4.2-WATCHDOG-AFTER-READY", "V12.4.3-EMERGENCY-NO-SHUTDOWN")
if html.count("V12.4.3-EMERGENCY-NO-SHUTDOWN") < 2:
    raise SystemExit("Visible/app runtime build identity update failed.")
html_path.write_text(html, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text(
    "V12.4.3-EMERGENCY-NO-SHUTDOWN\n"
    "Shutdown countdown, persisted timer state, and remote schedule execution removed. "
    "Legacy Windows shutdown countdown is aborted before Billing opens. "
    "Pairing, rental sync, watchdog, and Wake-on-LAN are preserved.\n",
    encoding="utf-8",
)

audit = """# V12.4.3 Emergency Shutdown Removal

- Removed the local scheduled-shutdown countdown loop and its persisted timer reader/writer.
- Purged the prior billing_shutdown_timer_v12 localStorage entry before the renderer starts.
- PC no longer reports shutdownTimer state in cloud heartbeat metadata.
- schedule_shutdown is rejected; cancel_shutdown_timer only clears legacy local state and acknowledges cancellation.
- Direct shutdown commands are rejected by the renderer and main-process IPC in this emergency build.
- On startup, Billing runs shutdown.exe /a before opening its window to cancel any pending Windows shutdown countdown.
- Pairing, cloud tokens, rental data/sessions, dual-DB routing, watchdog-after-ready, and Wake-on-LAN code paths are preserved.
- Electron appId and productName are preserved to avoid changing the userData directory.
"""
(ROOT / "EMERGENCY-SHUTDOWN-REMOVAL-AUDIT.md").write_text(audit, encoding="utf-8")
print("PASS: V12.4.3 shutdown countdown removed, stale timer purged, startup abort added, direct shutdown blocked.")
