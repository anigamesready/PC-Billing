from pathlib import Path
import json

ROOT = Path(".")
html_path = ROOT / "index.html"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
version_path = ROOT / "VERSION.txt"

html = html_path.read_text(encoding="utf-8")

# Electron's BrowserWindow loads index.html directly. renderer.js is not loaded by
# this project, so alert emitters must be applied and verified in index.html.
if "renderer.js is not loaded by Electron." not in html:
    raise SystemExit("Expected live renderer marker is missing from index.html; refusing to patch the wrong runtime.")

# Make the visible in-app footer identify this actual build, not the stale V11.21 label.
version_lines = [line for line in html.splitlines() if "const APP_VERSION =" in line]
if len(version_lines) != 1:
    raise SystemExit(f"Expected one APP_VERSION constant in live index.html, found {len(version_lines)}")
old_version_line = version_lines[0]
indent = old_version_line[:old_version_line.index("const APP_VERSION =")]
new_version_line = indent + "const APP_VERSION = 'V12.1.5-LIVE-ALERT-RUNTIME-FIX';"
html = html.replace(old_version_line, new_version_line, 1)

# Timer expiry and the local end-session button both pass through pauseSession().
if "window.v11EmitAdminAlert?.(eventType, message" not in html:
    old_lines = [line for line in html.splitlines() if "if (endedCode) writeSystemLog(" in line]
    if len(old_lines) != 1:
        raise SystemExit(f"pauseSession log anchor expected once in live index.html, found {len(old_lines)}; refusing to patch")
    old_line = old_lines[0]
    replacement = """            const endedUser = endedCode ? dbUsers[endedCode] : null;
            const expiredByTimer = Boolean(endedCode && Number(endedUser?.remainingSeconds || 0) <= 0);
            if (endedCode && !expiredByTimer) writeSystemLog('Sesi ' + endedCode + ' dihentikan/ditutup. Sisa waktu tersimpan.');
            if (endedCode && endedCode !== TEST_SESSION_CODE && !window.v11SyncApplying) {
                const eventType = expiredByTimer ? 'session_expired' : 'session_stopped';
                const message = expiredByTimer
                    ? ('Rental ' + endedCode + ' selesai karena waktu habis.')
                    : ('Rental ' + endedCode + ' dihentikan manual.');
                window.v11EmitAdminAlert?.(eventType, message, {
                    code: endedCode,
                    remainingSeconds: Math.max(0, Number(endedUser?.remainingSeconds) || 0)
                });
            }"""
    html = html.replace(old_line, replacement, 1)

# A remote stop/logout is intentionally marked as a cloud-applied command while
# stopping the local timer. Emit one explicit event after leaving that suppression
# window, otherwise the generic pauseSession guard hides the Admin-initiated stop.
remote_stop_anchor = """            if (cmd === 'stop' || cmd === 'logout') {
                localStorage.removeItem('billing_remote_paused_code');
                window.v11SyncApplying = true;
                try { if (currentActiveCode) pauseSession(false); else saveDB(); } finally { window.v11SyncApplying = false; }
                return {ok:true, message:'Sesi dihentikan/dikeluarkan.'};
            }"""
remote_stop_replacement = """            if (cmd === 'stop' || cmd === 'logout') {
                localStorage.removeItem('billing_remote_paused_code');
                if (currentActiveCode) {
                    const stoppedCode = currentActiveCode;
                    window.v11SyncApplying = true;
                    try { pauseSession(false); } finally { window.v11SyncApplying = false; }
                    if (stoppedCode !== TEST_SESSION_CODE) {
                        const stoppedUser = dbUsers[stoppedCode];
                        window.v11EmitAdminAlert?.('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {
                            code: stoppedCode,
                            remainingSeconds: Math.max(0, Number(stoppedUser?.remainingSeconds) || 0)
                        });
                    }
                } else {
                    saveDB();
                }
                return {ok:true, message:'Sesi dihentikan/dikeluarkan.'};
            }"""
if "dihentikan manual dari Admin Android." not in html:
    if html.count(remote_stop_anchor) != 1:
        raise SystemExit("Live stop/logout command anchor expected once in index.html; refusing to patch")
    html = html.replace(remote_stop_anchor, remote_stop_replacement, 1)

# Guard against a green build that only patched the unused renderer.js again.
for required in (
    "function pauseSession(",
    "const APP_VERSION = 'V12.1.5-LIVE-ALERT-RUNTIME-FIX';",
    "window.v11EmitAdminAlert?.(eventType, message",
    "dihentikan manual dari Admin Android.",
    "session_expired",
    "session_stopped",
    '<script src="v11-cloud.js"></script>',
):
    if required not in html:
        raise SystemExit("Live index.html regression token missing: " + required)
if html.count("window.v11EmitAdminAlert?.(eventType, message") != 1:
    raise SystemExit("Expected exactly one event-driven pauseSession alert call in live index.html")
if html.count("dihentikan manual dari Admin Android.") != 1:
    raise SystemExit("Expected exactly one explicit Admin stop/logout alert in live index.html")

package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if package.get("version") != "12.1.4":
    raise SystemExit("Expected PC baseline 12.1.4 after existing patches; refusing to bump blindly")
if lock.get("version") != "12.1.4":
    raise SystemExit("Unexpected package-lock version; refusing to bump blindly")
package["version"] = "12.1.5"
lock["version"] = "12.1.5"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.1.5"

html_path.write_text(html, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text("V12.1.5-LIVE-ALERT-RUNTIME-FIX\n", encoding="utf-8")
print("PASS: patched the actual Electron index.html runtime for timer expiry, local stop, and Admin stop/logout alerts; PC version 12.1.5.")
