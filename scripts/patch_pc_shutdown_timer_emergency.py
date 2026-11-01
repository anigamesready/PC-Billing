from pathlib import Path
import json
import re

ROOT = Path(".")
main_path = ROOT / "main.js"
html_path = ROOT / "index.html"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
version_path = ROOT / "VERSION.txt"

if not main_path.is_file() or not html_path.is_file():
    raise SystemExit("Required Electron files main.js/index.html missing; refusing emergency patch.")

main = main_path.read_text(encoding="utf-8")
html = html_path.read_text(encoding="utf-8")

# Abort any Windows shutdown countdown left by an older build before the window
# and its renderer start. This is harmless when no OS shutdown is pending.
startup_marker = "ANI_GAMES_EMERGENCY_CANCEL_PENDING_SHUTDOWN"
if startup_marker not in main:
    helper = """
// ANI_GAMES_EMERGENCY_CANCEL_PENDING_SHUTDOWN
function cancelPendingWindowsShutdownOnLaunch() {
    return new Promise((resolve) => {
        if (process.platform !== 'win32') return resolve();
        const { execFile } = require('child_process');
        execFile('shutdown.exe', ['/a'], { windowsHide: true }, () => resolve());
    });
}

"""
    ready_pattern = re.compile(r"app\.whenReady\(\)\.then\(\s*\(\)\s*=>\s*\{")
    main, count = ready_pattern.subn(
        "app.whenReady().then(async () => {\n    await cancelPendingWindowsShutdownOnLaunch();",
        main,
        count=1,
    )
    if count != 1:
        raise SystemExit("Electron app.whenReady startup anchor mismatch; refusing to patch.")
    ready_index = main.find("app.whenReady().then(async () => {")
    if ready_index < 0:
        raise SystemExit("Patched Electron startup block missing.")
    main = main[:ready_index] + helper + main[ready_index:]

# Block renderer-originated shutdown in this emergency build. Logoff and restart
# remain unchanged. This protects both old timer code and stale replayed commands.
power_anchor = "ipcMain.on('power-action', (event, action) => {"
if power_anchor not in main:
    power_anchor = 'ipcMain.on("power-action", (event, action) => {'
if "ANI_GAMES_EMERGENCY_BLOCK_SHUTDOWN_ACTION" not in main:
    if main.count(power_anchor) != 1:
        raise SystemExit("power-action IPC anchor mismatch; refusing to patch.")
    guard = """    // ANI_GAMES_EMERGENCY_BLOCK_SHUTDOWN_ACTION
    if (String(action || '').toLowerCase() === 'shutdown') {
        console.warn('[AniGames] Shutdown dinonaktifkan pada build emergency.');
        return;
    }
"""
    main = main.replace(power_anchor, power_anchor + "\n" + guard, 1)

if "cancelPendingWindowsShutdownOnLaunch" not in main:
    raise SystemExit("Startup shutdown cancellation function missing.")
if "shutdown.exe', ['/a']" not in main:
    raise SystemExit("Windows shutdown abort command missing.")
if "ANI_GAMES_EMERGENCY_BLOCK_SHUTDOWN_ACTION" not in main:
    raise SystemExit("Emergency shutdown IPC block missing.")

# Purge shutdown timer records from browser storage before app scripts initialize.
storage_marker = "ANI_GAMES_EMERGENCY_PURGE_SHUTDOWN_TIMER_STORAGE"
storage_script = r"""<script>
/* ANI_GAMES_EMERGENCY_PURGE_SHUTDOWN_TIMER_STORAGE */
(function () {
    window.__ANI_GAMES_SHUTDOWN_TIMER_DISABLED__ = true;
    function scrub(value) {
        if (!value || typeof value !== 'object') return { value: value, changed: false };
        let changed = false;
        if (Array.isArray(value)) {
            const out = [];
            for (const item of value) {
                const result = scrub(item);
                out.push(result.value);
                changed = changed || result.changed;
            }
            return { value: out, changed: changed };
        }
        const out = {};
        for (const key of Object.keys(value)) {
            if (/shutdown/i.test(key)) { changed = true; continue; }
            const result = scrub(value[key]);
            out[key] = result.value;
            changed = changed || result.changed;
        }
        return { value: out, changed: changed };
    }
    function purge(storage) {
        try {
            const remove = [];
            for (let i = 0; i < storage.length; i++) {
                const key = storage.key(i);
                if (!key) continue;
                if (/shutdown/i.test(key)) { remove.push(key); continue; }
                const raw = storage.getItem(key);
                if (!raw) continue;
                try {
                    const parsed = JSON.parse(raw);
                    const result = scrub(parsed);
                    if (result.changed) storage.setItem(key, JSON.stringify(result.value));
                } catch (_) {}
            }
            for (const key of remove) storage.removeItem(key);
        } catch (error) {
            console.warn('[AniGames] Gagal membersihkan storage timer shutdown lama.', error);
        }
    }
    try { purge(window.localStorage); } catch (_) {}
    try { purge(window.sessionStorage); } catch (_) {}
    try { window.localStorage.setItem('ani_games_shutdown_timer_disabled_v1', '1'); } catch (_) {}
})();
</script>
"""
if storage_marker not in html:
    head = re.search(r"<head(?:\s[^>]*)?>", html, flags=re.IGNORECASE)
    if not head:
        raise SystemExit("HTML head anchor missing; cannot safely purge old local timer before startup.")
    html = html[:head.end()] + "\n" + storage_script + html[head.end():]

# Ignore future legacy schedule_shutdown commands before renderer startup.
# cancel_shutdown_timer remains allowed for cleanup acknowledgements.
guard_marker = "ANI_GAMES_EMERGENCY_BLOCK_REMOTE_SHUTDOWN_TIMER"
guard_script = r"""<script>
/* ANI_GAMES_EMERGENCY_BLOCK_REMOTE_SHUTDOWN_TIMER */
(function () {
    window.__ANI_GAMES_SHUTDOWN_TIMER_DISABLED__ = true;
    function hasScheduleCommand(value, seen) {
        if (typeof value === 'string') return value.trim().toLowerCase() === 'schedule_shutdown';
        if (!value || typeof value !== 'object') return false;
        seen = seen || new Set();
        if (seen.has(value)) return false;
        seen.add(value);
        if (typeof value.command === 'string' && value.command.trim().toLowerCase() === 'schedule_shutdown') return true;
        if (Array.isArray(value)) return value.some(function (x) { return hasScheduleCommand(x, seen); });
        return Object.keys(value).some(function (key) { return hasScheduleCommand(value[key], seen); });
    }
    const original = window.v11ApplyRemoteCommand;
    if (typeof original === 'function' && !original.__aniGamesShutdownGuard) {
        const guarded = async function () {
            const args = Array.prototype.slice.call(arguments);
            if (args.some(function (arg) { return hasScheduleCommand(arg); })) {
                console.warn('[AniGames] Perintah schedule_shutdown diabaikan: fitur timer shutdown sudah dihapus.');
                return { ok: false, ignored: true, error: 'SHUTDOWN_TIMER_DISABLED' };
            }
            return original.apply(this, args);
        };
        guarded.__aniGamesShutdownGuard = true;
        window.v11ApplyRemoteCommand = guarded;
    }
})();
</script>
"""
if guard_marker not in html:
    closing = html.lower().rfind("</body>")
    if closing < 0:
        raise SystemExit("HTML body closing anchor missing; cannot install remote-command guard.")
    html = html[:closing] + "\n" + guard_script + "\n" + html[closing:]

# Bump the build identity only from the known prior pipeline version.
package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if package.get("version") != "12.1.7" or lock.get("version") != "12.1.7":
    raise SystemExit("Expected source version 12.1.7 after existing patches; refusing to bump unknown baseline.")
package["version"] = "12.1.8"
lock["version"] = "12.1.8"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.1.8"

version_lines = [line for line in html.splitlines() if "const APP_VERSION =" in line]
if len(version_lines) != 1:
    raise SystemExit(f"Expected exactly one APP_VERSION constant, found {len(version_lines)}.")
html = html.replace(version_lines[0], version_lines[0].split("const APP_VERSION =")[0] + "const APP_VERSION = 'V12.1.8-EMERGENCY-NO-SHUTDOWN';", 1)

main_path.write_text(main, encoding="utf-8")
html_path.write_text(html, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text("V12.1.8-EMERGENCY-NO-SHUTDOWN\n", encoding="utf-8")

audit = """# V12.1.8 Emergency Shutdown Removal

- PC build startup runs shutdown.exe /a before opening the billing window to cancel legacy Windows shutdown countdowns.
- Renderer IPC rejects the shutdown action. Logoff and restart remain unchanged.
- Browser local/session storage keys and JSON properties containing shutdown are purged before app scripts initialize.
- Legacy schedule_shutdown remote commands are ignored. cancel_shutdown_timer remains allowed for cleanup acknowledgements.
- Pairing, cloud token, rental records, sync cursors, rental sessions, watchdog, and Wake-on-LAN code are not intentionally changed.
- Build identity: V12.1.8-EMERGENCY-NO-SHUTDOWN.
"""
(ROOT / "EMERGENCY-SHUTDOWN-REMOVAL-AUDIT.md").write_text(audit, encoding="utf-8")
print("PASS: emergency shutdown removal and startup abort guard installed.")
