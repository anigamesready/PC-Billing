from pathlib import Path
import json

root = Path(".")
main_path = root / "main.js"
index_path = root / "index.html"
renderer_path = root / "renderer.js"
package_path = root / "package.json"
version_path = root / "VERSION.txt"

main = main_path.read_text(encoding="utf-8")
index = index_path.read_text(encoding="utf-8")
renderer = renderer_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))

MARKER = "V12.3.2-APP-EXIT-PROTECTION"
OLD_MARKER = "V12.3.1-HEARTBEAT-WRITE-OPTIMIZATION"

def replace_once(text, old, new, label):
    count = text.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor mismatch: expected 1, got {count}")
    return text.replace(old, new, 1)

if MARKER in main:
    print("PASS: V12.3.2 app-exit protection already applied")
    raise SystemExit(0)
if package.get("version") != "12.3.1" or OLD_MARKER not in index:
    raise SystemExit(f"Expected V12.3.1 source, got package version {package.get('version')}")

main = replace_once(
    main,
    "let mainWindow;\nlet adminMessageWindow = null;",
    "let mainWindow;\nlet allowBillingExit = false;\nlet adminMessageWindow = null;",
    "Exit guard state",
)
main = replace_once(
    main,
    "    mainWindow.loadFile('index.html');\n    mainWindow.setAlwaysOnTop(true, 'screen-saver');",
    """    // V12.3.2: keep ordinary close shortcuts/clicks from terminating monitoring.
    const protectedWindow = mainWindow;
    protectedWindow.on('close', (event) => {
        if (allowBillingExit) return;
        event.preventDefault();
        try {
            if (protectedWindow.isMinimized()) protectedWindow.restore();
            protectedWindow.show();
            protectedWindow.focus();
        } catch (err) {
            console.error('Gagal memulihkan window Billing setelah percobaan close:', err);
        }
    });
    protectedWindow.webContents.on('render-process-gone', (_event, details) => {
        console.error('Renderer Billing berhenti; memuat ulang UI tanpa menghapus data:', details?.reason || 'unknown');
        setTimeout(() => {
            if (!protectedWindow.isDestroyed() && protectedWindow.webContents.isCrashed()) {
                protectedWindow.loadFile('index.html').catch(err => console.error('Pemulihan renderer Billing gagal:', err));
            }
        }, 1200);
    });
    protectedWindow.webContents.on('unresponsive', () => {
        console.error('Renderer Billing tidak merespons; menunggu sebelum pemulihan.');
        setTimeout(() => {
            if (!protectedWindow.isDestroyed() && protectedWindow.webContents.isCrashed()) {
                protectedWindow.loadFile('index.html').catch(err => console.error('Pemulihan renderer Billing gagal:', err));
            }
        }, 5000);
    });

    mainWindow.loadFile('index.html');
    mainWindow.setAlwaysOnTop(true, 'screen-saver');""",
    "Window close and renderer recovery hooks",
)
main = replace_once(
    main,
    "        app.relaunch();\n        setTimeout(() => app.exit(0), 100);",
    "        allowBillingExit = true;\n        app.relaunch();\n        setTimeout(() => app.exit(0), 100);",
    "Authorized restart exit",
)
main = replace_once(
    main,
    "        setTimeout(() => app.quit(), 0);\n        return { ok: true };",
    "        allowBillingExit = true;\n        setTimeout(() => app.quit(), 0);\n        return { ok: true };",
    "Authorized admin exit",
)
main = replace_once(
    main,
    "app.whenReady().then(() => {\n    createWindow();",
    """// Block Electron's ordinary quit path; only the existing explicit Admin Exit/Restart
// handlers above may set allowBillingExit. Windows session shutdown remains permitted.
app.on('before-quit', (event) => {
    if (allowBillingExit) return;
    event.preventDefault();
    try {
        if (!mainWindow || mainWindow.isDestroyed()) createWindow();
        else {
            if (mainWindow.isMinimized()) mainWindow.restore();
            mainWindow.show();
            mainWindow.focus();
        }
    } catch (err) {
        console.error('Billing menolak keluar tanpa otorisasi dan gagal fokus ulang:', err);
    }
});
app.on('query-session-end', () => { allowBillingExit = true; });

app.whenReady().then(() => {
    createWindow();""",
    "Global quit guard",
)

if index.count(OLD_MARKER) != 2:
    raise SystemExit(f"Visible app version anchors mismatch: expected 2, got {index.count(OLD_MARKER)}")
index = index.replace(OLD_MARKER, MARKER)
renderer = renderer.replace(OLD_MARKER, MARKER)
if OLD_MARKER in renderer:
    raise SystemExit("Old renderer version marker remains")
package["version"] = "12.3.2"
package["description"] = "AniGames Billing V12.3.2: V12.3.1 heartbeat/session performance plus protected ordinary close and renderer crash recovery"
if isinstance(package.get("build"), dict):
    package["build"]["productName"] = "AniGames Billing V12.3.2"

lock_path = root / "package-lock.json"
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = "12.3.2"
    if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
        lock["packages"][""]["version"] = "12.3.2"
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

main_path.write_text(main, encoding="utf-8")
index_path.write_text(index, encoding="utf-8")
renderer_path.write_text(renderer, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text(
    "AniGames Billing PC V12.3.2 — V12.3.1 heartbeat/session performance plus ordinary close/quit protection, authorized Admin exit/restart, and renderer crash recovery.\n",
    encoding="utf-8",
)

for token in [
    "let allowBillingExit = false;", "protectedWindow.on('close'", "event.preventDefault();",
    "render-process-gone", "app.on('before-quit'", "app.on('query-session-end'",
    "allowBillingExit = true;\n        app.relaunch();", "allowBillingExit = true;\n        setTimeout(() => app.quit(), 0);",
]:
    if token not in main:
        raise SystemExit("V12.3.2 main.js assertion missing: " + token)
if package.get("version") != "12.3.2" or MARKER not in index or MARKER not in renderer:
    raise SystemExit("V12.3.2 version identity mismatch")
print("PASS: V12.3.2 ordinary close guard, authorized Admin exit/restart, renderer recovery, and version identity.")
