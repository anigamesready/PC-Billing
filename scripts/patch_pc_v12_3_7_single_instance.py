from pathlib import Path
import json

ROOT = Path(".")
PATHS = {
    "main": ROOT / "main.js",
    "index": ROOT / "index.html",
    "renderer": ROOT / "renderer.js",
    "cloud": ROOT / "v11-cloud.js",
    "package": ROOT / "package.json",
    "lock": ROOT / "package-lock.json",
    "version": ROOT / "VERSION.txt",
}
for key, path in PATHS.items():
    if key != "lock" and not path.is_file():
        raise SystemExit(f"Missing required source: {path}")

main = PATHS["main"].read_text(encoding="utf-8")
index = PATHS["index"].read_text(encoding="utf-8")
renderer = PATHS["renderer"].read_text(encoding="utf-8")
cloud = PATHS["cloud"].read_text(encoding="utf-8")
pkg = json.loads(PATHS["package"].read_text(encoding="utf-8"))
lock = json.loads(PATHS["lock"].read_text(encoding="utf-8")) if PATHS["lock"].is_file() else None

OLD = "V12.3.6-WOL-RELAY"
NEW = "V12.3.7-SINGLE-INSTANCE-GUARD"
APP_ID = "com.anigames.billing.v12test"
PRODUCT_NAME = "AniGames Billing V12.3.3"  # intentionally stable for userData continuity

if NEW in main and NEW in index and NEW in renderer and pkg.get("version") == "12.3.7":
    print("PASS: V12.3.7 single-instance guard already applied")
    raise SystemExit(0)
if pkg.get("version") != "12.3.6" or OLD not in index or OLD not in renderer or OLD not in cloud:
    raise SystemExit(f"Expected exact V12.3.6 source baseline; found package version {pkg.get('version')}")
if pkg.get("build", {}).get("appId") != APP_ID:
    raise SystemExit("Unexpected Electron appId; refusing to change persistent application identity")
if pkg.get("build", {}).get("productName") != PRODUCT_NAME:
    raise SystemExit("Unexpected Electron productName; refusing to change userData identity")

# The main UI and detached watchdog have independent Electron locks.
# Keep the original main userData directory unchanged to preserve pairing/localStorage/backups.
old_main_state = """let mainWindow;
let allowBillingExit = false;
let adminMessageWindow = null;"""
new_main_state = """let mainWindow;
let allowBillingExit = false;
// V12.3.7: one visible Billing process per Windows user/application identity.
// The watchdog uses a separate Electron lock profile but shares the original data directory.
const BILLING_USER_DATA_DIR = app.getPath('userData');
const WATCHDOG_LOCK_PROFILE = path.join(BILLING_USER_DATA_DIR, '.ani-watchdog-instance-lock');
if (WATCHDOG_AGENT_MODE) {
    try { fs.mkdirSync(WATCHDOG_LOCK_PROFILE, { recursive: true }); } catch (_) {}
    app.setPath('userData', WATCHDOG_LOCK_PROFILE);
}
const BILLING_SINGLE_INSTANCE_LOCK = app.requestSingleInstanceLock({
    appRole: WATCHDOG_AGENT_MODE ? 'watchdog-agent' : 'billing-main',
    appId: 'com.anigames.billing.v12test'
});
const DUPLICATE_BILLING_PROCESS = !BILLING_SINGLE_INSTANCE_LOCK;
if (DUPLICATE_BILLING_PROCESS) {
    // A duplicate must exit even though ordinary close is password-protected.
    allowBillingExit = true;
    app.quit();
} else if (!WATCHDOG_AGENT_MODE) {
    app.on('second-instance', () => {
        // Repeated shortcut/auto-start/open requests return to the already-running UI.
        try {
            if (!mainWindow || mainWindow.isDestroyed()) {
                if (app.isReady()) createWindow();
                return;
            }
            if (mainWindow.isMinimized()) mainWindow.restore();
            mainWindow.show();
            mainWindow.focus();
        } catch (e) {
            console.error('Gagal memfokuskan Billing yang sudah berjalan:', e?.message || e);
        }
    });
}
let adminMessageWindow = null;"""
if main.count(old_main_state) != 1:
    raise SystemExit(f"Main process identity anchor mismatch: {main.count(old_main_state)}")
main = main.replace(old_main_state, new_main_state, 1)

old_watchdog_dir = """function watchdogFiles() {
    const dir = app.getPath('userData');"""
new_watchdog_dir = """function watchdogFiles() {
    const dir = BILLING_USER_DATA_DIR;"""
if main.count(old_watchdog_dir) != 1:
    raise SystemExit("Watchdog shared-data directory anchor mismatch")
main = main.replace(old_watchdog_dir, new_watchdog_dir, 1)

old_before_quit = """app.on('before-quit', (event) => {
    if (WATCHDOG_AGENT_MODE) return;
    if (allowBillingExit) { removeMainProcessState(); return; }"""
new_before_quit = """app.on('before-quit', (event) => {
    if (WATCHDOG_AGENT_MODE || DUPLICATE_BILLING_PROCESS) return;
    if (allowBillingExit) { removeMainProcessState(); return; }"""
if main.count(old_before_quit) != 1:
    raise SystemExit("before-quit duplicate-exit guard anchor mismatch")
main = main.replace(old_before_quit, new_before_quit, 1)

old_ready = """app.whenReady().then(() => {
    if (WATCHDOG_AGENT_MODE) { runWatchdogAgent(); return; }
    writeMainProcessState(false);"""
new_ready = """app.whenReady().then(() => {
    if (DUPLICATE_BILLING_PROCESS) { app.quit(); return; }
    if (WATCHDOG_AGENT_MODE) { runWatchdogAgent(); return; }
    writeMainProcessState(false);"""
if main.count(old_ready) != 1:
    raise SystemExit("app.whenReady single-instance gate anchor mismatch")
main = main.replace(old_ready, new_ready, 1)

if index.count(OLD) != 3 or renderer.count(OLD) != 1 or cloud.count(OLD) != 1:
    raise SystemExit(
        f"Version marker count mismatch: index={index.count(OLD)}, renderer={renderer.count(OLD)}, cloud={cloud.count(OLD)}"
    )
index = index.replace(OLD, NEW)
renderer = renderer.replace(OLD, NEW)
cloud = cloud.replace(OLD, NEW)
main = main.replace("appVersion: 'V12.3.6-watchdog'", "appVersion: 'V12.3.7-watchdog'", 1)
if "appVersion: 'V12.3.7-watchdog'" not in main:
    raise SystemExit("Watchdog version marker update failed")

pkg["version"] = "12.3.7"
pkg["description"] = (
    "AniGames Billing V12.3.7: single visible Billing instance; isolated watchdog lock; "
    "existing PC identity, pairing and rental data preserved"
)
if pkg.get("build", {}).get("appId") != APP_ID or pkg.get("build", {}).get("productName") != PRODUCT_NAME:
    raise SystemExit("Stable Electron application identity was unexpectedly modified")
if lock is not None:
    lock["version"] = "12.3.7"
    if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
        lock["packages"][""]["version"] = "12.3.7"

PATHS["main"].write_text(main, encoding="utf-8")
PATHS["index"].write_text(index, encoding="utf-8")
PATHS["renderer"].write_text(renderer, encoding="utf-8")
PATHS["cloud"].write_text(cloud, encoding="utf-8")
PATHS["package"].write_text(json.dumps(pkg, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
if lock is not None:
    PATHS["lock"].write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
PATHS["version"].write_text(
    "AniGames Billing PC V12.3.7 — single-instance lock for visible Billing UI; separate watchdog lock profile; "
    "stable appId/productName and original userData/pairing/rental state retained.\n",
    encoding="utf-8"
)

checks = {
    "main lock request": "app.requestSingleInstanceLock({" in main,
    "main duplicate exit": "const DUPLICATE_BILLING_PROCESS = !BILLING_SINGLE_INSTANCE_LOCK;" in main,
    "second launch focuses primary": "app.on('second-instance'" in main and "mainWindow.focus();" in main,
    "watchdog separate lock profile": "app.setPath('userData', WATCHDOG_LOCK_PROFILE);" in main,
    "watchdog shared data": "const dir = BILLING_USER_DATA_DIR;" in main,
    "duplicate bypasses close guard": "if (WATCHDOG_AGENT_MODE || DUPLICATE_BILLING_PROCESS) return;" in main,
    "duplicate startup blocked": "if (DUPLICATE_BILLING_PROCESS) { app.quit(); return; }" in main,
    "pairing appId preserved": pkg["build"]["appId"] == APP_ID,
    "userData productName preserved": pkg["build"]["productName"] == PRODUCT_NAME,
    "version synchronized": NEW in index and NEW in renderer and NEW in cloud and pkg["version"] == "12.3.7",
}
for label, ok in checks.items():
    if not ok:
        raise SystemExit("Assertion failed: " + label)
    print("PASS:", label)
print("PASS: V12.3.7 single-instance patch applied without changing PC pairing/device IDs, local data keys, appId or productName.")
