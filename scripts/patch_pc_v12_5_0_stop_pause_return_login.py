from pathlib import Path
import json

ROOT = Path(".")
HTML = ROOT / "index.html"
MAIN = ROOT / "main.js"
PRELOAD = ROOT / "preload.js"
RENDERER = ROOT / "renderer.js"
CLOUD = ROOT / "v11-cloud.js"
PACKAGE = ROOT / "package.json"
LOCK = ROOT / "package-lock.json"
VERSION = ROOT / "VERSION.txt"

OLD_MARKER = "V12.4.9-STOP-PAUSE-AUTHORIZATION"
NEW_MARKER = "V12.5.0-STOP-PAUSE-RETURN-LOGIN"

paths = [HTML, MAIN, PRELOAD, RENDERER, CLOUD, PACKAGE, LOCK, VERSION]
for path in paths:
    if not path.is_file():
        raise SystemExit("Required V12.4.9 source missing: " + str(path))

html = HTML.read_text(encoding="utf-8")
main = MAIN.read_text(encoding="utf-8")
preload = PRELOAD.read_text(encoding="utf-8")
renderer = RENDERER.read_text(encoding="utf-8")
cloud = CLOUD.read_text(encoding="utf-8")
package = json.loads(PACKAGE.read_text(encoding="utf-8"))
lock = json.loads(LOCK.read_text(encoding="utf-8"))

if NEW_MARKER in html and "ipcMain.handle('return-billing-to-login'" in main:
    print("PASS: V12.5.0 Stop/Pause return-to-Login patch already applied")
    raise SystemExit(0)

if OLD_MARKER not in html or renderer.count(OLD_MARKER) != 1:
    raise SystemExit("PC V12.4.9 source marker mismatch; refusing patch")
if "APP='V12.4.9-DB-ANDROID'" not in cloud:
    raise SystemExit("PC V12.4.9 DB Android version anchor mismatch")
if package.get("version") != "12.4.9" or lock.get("version") != "12.4.9":
    raise SystemExit("PC package metadata is not V12.4.9")
# The source ZIP still carries the stable legacy app identity here.
# The workflow applies the isolated DB Android identity after all source patches.
if package.get("build", {}).get("appId") != "com.anigames.billing.v12test":
    raise SystemExit("Persistent Electron appId mismatch before DB Android identity isolation")
if package.get("build", {}).get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("Persistent productName mismatch before DB Android identity isolation")
if "function applyLoginKioskMode(" not in main:
    raise SystemExit("Existing native Login kiosk transition is missing")
if "ipcMain.handle('hide-billing'" not in main or "ipcMain.handle('show-billing'" not in main:
    raise SystemExit("Existing Admin Logout/Login IPC baseline missing")
if "hideBilling: () => ipcRenderer.invoke('hide-billing')" not in preload:
    raise SystemExit("Existing Electron preload bridge baseline missing")

def once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor mismatch: expected 1, found {count}")
    return source.replace(old, new, 1)

# The renderer must reveal the Login screen and hide the floating timer after the
# session-stop routine has completed. The native IPC below then restores the
# existing full-screen Login kiosk mode without changing display resolution.
login_helper_anchor = "        let stopPauseAuthorizationBusy = false;"
login_helper = """        function ensureBillingLoginViewAfterStopPause() {
            const loginScreen = document.getElementById('lock-screen');
            const timerWidget = document.getElementById('timer-widget');
            if (!loginScreen) throw new Error('BILLING_LOGIN_SCREEN_NOT_FOUND');
            loginScreen.classList.remove('hidden');
            if (timerWidget) timerWidget.classList.add('hidden');
            if (typeof fitLoginBoxToViewport === 'function') fitLoginBoxToViewport();
            if (typeof focusLoginInput === 'function') setTimeout(focusLoginInput, 120);
        }

"""
html = once(html, login_helper_anchor, login_helper + login_helper_anchor,
            "Renter Stop/Pause Login view helper")

old_authorizer = """        async function authorizeStopPauseAndStop(event) {
            if (event) { event.preventDefault(); event.stopPropagation(); }
            if (!currentActiveCode || stopPauseAuthorizationBusy) return;
            stopPauseAuthorizationBusy = true;
            try {
                if (typeof window.v11CheckStopPausePermission !== 'function') {
                    throw new Error('BILLING_STOP_PAUSE_POLICY_UNAVAILABLE');
                }
                const policy = await window.v11CheckStopPausePermission();
                const allowed = policy?.allow_stop_pause === true || policy?.enabled === true;
                setStopPauseAuthorizationVisual(!allowed);
                if (!allowed) {
                    showCustomModal(
                        'Akses PAUSE / STOP sedang dikunci oleh Admin. Silakan hubungi Admin untuk meminta akses dibuka. Timer rental tetap berjalan.',
                        'AKSES PAUSE / STOP DIKUNCI', false, '🔒'
                    );
                    return;
                }
                stopActiveSession();
            } catch (error) {
                setStopPauseAuthorizationVisual(true);
                showCustomModal(
                    'Izin PAUSE / STOP tidak dapat diverifikasi dari server. Demi keamanan, tombol tetap dikunci dan timer tetap berjalan. Silakan hubungi Admin.',
                    'IZIN TIDAK TERSEDIA', true, '🔒'
                );
                console.warn('[Billing] Stop/Pause authorization unavailable:', error?.message || error);
            } finally {
                stopPauseAuthorizationBusy = false;
            }
        }
"""
new_authorizer = """        async function authorizeStopPauseAndStop(event) {
            if (event) { event.preventDefault(); event.stopPropagation(); }
            if (!currentActiveCode || stopPauseAuthorizationBusy) return;
            stopPauseAuthorizationBusy = true;
            let stopIssued = false;
            try {
                if (typeof window.v11CheckStopPausePermission !== 'function') {
                    throw new Error('BILLING_STOP_PAUSE_POLICY_UNAVAILABLE');
                }
                const policy = await window.v11CheckStopPausePermission();
                const allowed = policy?.allow_stop_pause === true || policy?.enabled === true;
                setStopPauseAuthorizationVisual(!allowed);
                if (!allowed) {
                    showCustomModal(
                        'Akses PAUSE / STOP sedang dikunci oleh Admin. Silakan hubungi Admin untuk meminta akses dibuka. Timer rental tetap berjalan.',
                        'AKSES PAUSE / STOP DIKUNCI', false, '🔒'
                    );
                    return;
                }
                stopIssued = true;
                await Promise.resolve(stopActiveSession());
                ensureBillingLoginViewAfterStopPause();
                if (typeof window.electronAPI?.returnBillingToLogin !== 'function') {
                    throw new Error('BILLING_LOGIN_MODE_IPC_UNAVAILABLE');
                }
                const loginResult = await window.electronAPI.returnBillingToLogin();
                if (!loginResult || loginResult.ok !== true) {
                    throw new Error(loginResult?.message || 'BILLING_LOGIN_MODE_NOT_RESTORED');
                }
            } catch (error) {
                setStopPauseAuthorizationVisual(true);
                const message = stopIssued
                    ? 'Perintah Stop/Pause sudah diteruskan, tetapi layar Login Billing belum berhasil dipulihkan. Jangan mulai sesi baru dulu; minta Admin memeriksa Billing.'
                    : 'Izin PAUSE / STOP tidak dapat diverifikasi dari server. Demi keamanan, tombol tetap dikunci dan timer tetap berjalan. Silakan hubungi Admin.';
                showCustomModal(
                    message,
                    stopIssued ? 'LOGIN BILLING GAGAL DIPULIHKAN' : 'IZIN TIDAK TERSEDIA',
                    true, '🔒'
                );
                console.warn('[Billing] Stop/Pause flow:', error?.message || error);
            } finally {
                stopPauseAuthorizationBusy = false;
            }
        }
"""
html = once(html, old_authorizer, new_authorizer,
            "Authorized renter Stop/Pause handler")

# Use the existing main-process kiosk helper; do not fake a fullscreen transition
# solely from the renderer.
ipc_anchor = "ipcMain.on('resize-timer-window',(event,width,height)=>{"
ipc_handler = """ipcMain.handle('return-billing-to-login', (event) => {
  if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents || !billingUiReady ||
      billingRecoveryMode || !mainWindow || mainWindow.isDestroyed()) {
    return {ok:false,message:'Billing belum siap untuk kembali ke Login.'};
  }
  try {
    applyLoginKioskMode(mainWindow);
    return {ok:true,mode:'login'};
  } catch (error) {
    console.error('Gagal mengembalikan Login Billing:', error?.message || error);
    return {ok:false,message:String(error?.message || 'Gagal memulihkan Login Billing.')};
  }
});
"""
main = once(main, ipc_anchor, ipc_handler + ipc_anchor,
            "Native Billing Login mode IPC")

preload_anchor = "    hideBilling: () => ipcRenderer.invoke('hide-billing'),"
preload_new = preload_anchor + "\n    returnBillingToLogin: () => ipcRenderer.invoke('return-billing-to-login'),"
preload = once(preload, preload_anchor, preload_new,
               "Preload Login mode bridge")

# Keep the long-lived Electron application identity and userData folder intact.
html = html.replace(OLD_MARKER, NEW_MARKER)
renderer = renderer.replace(OLD_MARKER, NEW_MARKER, 1)
cloud = cloud.replace("APP='V12.4.9-DB-ANDROID'", "APP='V12.5.0-DB-ANDROID'", 1)
cloud = cloud.replace("// BUILD_ID: " + OLD_MARKER, "// BUILD_ID: " + NEW_MARKER, 1)

package["version"] = "12.5.0"
package["description"] = (
    "AniGames Billing V12.5.0: authorized renter Stop/Pause now restores the Login screen "
    "and native full-screen Login mode; preserves the V12.4.9 DB Android identity and data."
)
lock["version"] = "12.5.0"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.5.0"

VERSION.write_text(
    NEW_MARKER + "\n"
    "Authorized renter Stop/Pause awaits the stop routine, returns the renderer to the Login screen, "
    "then asks the Electron main process to restore the existing Login kiosk mode. The existing "
    "appId, productName, userData directory, DB Android pairing and rental data remain unchanged. "
    "Admin commands and automatic expiry keep their original direct session paths.\n",
    encoding="utf-8"
)
HTML.write_text(html, encoding="utf-8")
MAIN.write_text(main, encoding="utf-8")
PRELOAD.write_text(preload, encoding="utf-8")
RENDERER.write_text(renderer, encoding="utf-8")
CLOUD.write_text(cloud, encoding="utf-8")
PACKAGE.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
LOCK.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

# Post-patch regression checks: renter flow has an ordered stop -> Login DOM ->
# native kiosk transition. Admin and expiry continue using pauseSession directly.
start = html.index("async function authorizeStopPauseAndStop")
end = html.index("function pauseStopSessionFromTimer", start)
flow = html[start:end]
if not (
    flow.index("await Promise.resolve(stopActiveSession())")
    < flow.index("ensureBillingLoginViewAfterStopPause()")
    < flow.index("window.electronAPI.returnBillingToLogin()")
):
    raise SystemExit("Stop/Pause Login transition order is invalid")
for token in [
    "function ensureBillingLoginViewAfterStopPause()",
    "document.getElementById('lock-screen')",
    "document.getElementById('timer-widget')",
    "loginScreen.classList.remove('hidden')",
    "timerWidget.classList.add('hidden')",
    "V12.5.0-STOP-PAUSE-RETURN-LOGIN",
]:
    if token not in html:
        raise SystemExit("PC Login view assertion missing: " + token)
for token in [
    "ipcMain.handle('return-billing-to-login'",
    "applyLoginKioskMode(mainWindow)",
    "event.sender !== mainWindow?.webContents",
    "billingRecoveryMode",
]:
    if token not in main:
        raise SystemExit("PC main-process Login mode assertion missing: " + token)
for token in [
    "returnBillingToLogin: () => ipcRenderer.invoke('return-billing-to-login')",
]:
    if token not in preload:
        raise SystemExit("PC preload Login bridge assertion missing: " + token)
if "function pauseSession(showNotif = false)" not in html or "if (remaining <= 0)" not in html:
    raise SystemExit("Automatic expiry/session engine was modified or removed")
if "pauseSession(false);" not in html:
    raise SystemExit("Existing Admin/session-stop path was unexpectedly removed")
# Keep the stable source identity intact at patch time. The workflow's
# dedicated isolation step assigns the already-established DB Android identity.
if package.get("build", {}).get("appId") != "com.anigames.billing.v12test":
    raise SystemExit("Persistent Electron appId changed during source patch")
if package.get("build", {}).get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("Persistent Electron productName changed during source patch")

print("PASS: V12.5.0 renter Stop/Pause restores Login DOM + native kiosk; Admin/expiry paths, DB Android pairing, app identity and data paths preserved.")
