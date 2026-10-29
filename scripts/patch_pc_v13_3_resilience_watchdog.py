from pathlib import Path
import json
import re

ROOT = Path(".")
main_path = ROOT / "main.js"
index_path = ROOT / "index.html"
renderer_path = ROOT / "renderer.js"
preload_path = ROOT / "preload.js"
cloud_path = ROOT / "v11-cloud.js"
api_path = ROOT / "supabase/functions/ani-games-api/index.ts"
package_path = ROOT / "package.json"
version_path = ROOT / "VERSION.txt"

MARKER = "V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG"
OLD_MARKER = "V12.3.2-APP-EXIT-PROTECTION"
DB1_API_URL = "https://wzkjpycjizexxcxrfdvr.supabase.co/functions/v1/ani-games-api"

def replace_once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor mismatch: expected 1, got {count}")
    return source.replace(old, new, 1)

main = main_path.read_text(encoding="utf-8")
index = index_path.read_text(encoding="utf-8")
renderer = renderer_path.read_text(encoding="utf-8")
preload = preload_path.read_text(encoding="utf-8")
cloud = cloud_path.read_text(encoding="utf-8")
api = api_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))

if MARKER in main and MARKER in index:
    print("PASS: V12.3.3 resilience patch already applied")
    raise SystemExit(0)
if package.get("version") != "12.3.2" or OLD_MARKER not in index or OLD_MARKER not in renderer:
    raise SystemExit(f"Expected V12.3.2 source, got package version {package.get('version')}")

# 1) FREE TEST: an explicit server OFF setting blocks new sessions only.
# If the permission service is unreachable, allow an isolated 10-minute local test;
# no token/session is sent to the cloud until connectivity returns.
old_gate = """            // V12.3.0-TEST-POLICY-PREFLIGHT: server authorization is required; unknown/offline state blocks the test.
            try {
                const __freeTestPolicy = await window.v11CheckFreeTestPermission();
                if (__freeTestPolicy?.enabled !== true) {
                    window.alert('Silahkan hubungi admin untuk melakukan tes 082298316902');
                    return {ok:false, error:'FREE_TEST_DISABLED', message:'Silahkan hubungi admin untuk melakukan tes 082298316902'};
                }
            } catch (__freeTestError) {
                window.alert('Izin test 10 menit belum bisa diverifikasi. Test diblokir demi keamanan.\\nSilahkan hubungi admin untuk melakukan tes 082298316902');
                return {ok:false, error:'FREE_TEST_POLICY_UNAVAILABLE', message:String(__freeTestError?.message || __freeTestError || 'Status izin test tidak tersedia.')};
            }
"""
new_gate = """            // V12.3.3: an explicit online OFF setting blocks new trials; network loss must not lock the billing UI.
            let __freeTestOfflineFallback = false;
            try {
                const __freeTestPolicy = await window.v11CheckFreeTestPermission();
                if (__freeTestPolicy?.enabled !== true) {
                    showCustomModal('Sesi gratis 10 menit sedang dinonaktifkan oleh Admin. Kode unik dan Panel Admin tetap dapat digunakan.', 'FREE TEST DINONAKTIFKAN', true, '🔒');
                    return {ok:false, error:'FREE_TEST_DISABLED', message:'FREE_TEST_DISABLED'};
                }
            } catch (__freeTestError) {
                const __message = String(__freeTestError?.message || __freeTestError || '');
                const __status = Number(__freeTestError?.status || 0);
                const __offline = __message === 'PAIRING_REQUIRED'
                    || __status >= 500
                    || /Failed to fetch|fetch failed|NetworkError|ERR_INTERNET_DISCONNECTED|AbortError|timed? ?out|network unavailable|DB_ROUTE_STATUS_UNAVAILABLE|DB_ROUTE_CUTOVER_INCOMPLETE|DB_ROUTE_CUTOVER_BLOCKED|ACTIVE_DB_GATEWAY_UNAVAILABLE|GLOBAL_ROUTE_MISMATCH|GLOBAL_ROUTE_NOT_FINALIZED/i.test(__message);
                if (!__offline || __status === 401 || __status === 403 || /INVALID_DEVICE_TOKEN|TOKEN_CLOUD_DITOLAK|UNAUTHORIZED/i.test(__message)) {
                    showCustomModal('Izin test belum dapat diverifikasi. Periksa koneksi dan pairing Cloud. Kode unik dan Panel Admin tetap tersedia.', 'IZIN TEST TIDAK TERSEDIA', true, '⚠️');
                    return {ok:false, error:'FREE_TEST_POLICY_UNAVAILABLE', message:__message || 'Status izin test tidak tersedia.'};
                }
                __freeTestOfflineFallback = true;
                writeSystemLog('FREE TEST berjalan lokal karena layanan Cloud tidak tersedia; timer tidak bergantung pada koneksi.');
            }
"""
if old_gate not in index:
    raise SystemExit("FREE TEST preflight block mismatch; refusing patch.")
index = index.replace(old_gate, new_gate, 1)

# Avoid a blocking browser alert / automatic kiosk transition when Admin disables trials.
# Existing sessions are allowed to finish, matching the server-side session policy.
old_stop = "if(d.free_test_disabled===true&&window.v11GetActiveCode?.()==='__TEST10__'){try{await window.v11ApplyRemoteCommand?.('stop',{reason:'FREE_TEST_DISABLED'})}catch(_){}status('☁️ FREE TEST ditolak oleh server • sesi lokal dihentikan');try{window.alert(d.free_test_message||'Silahkan hubungi admin untuk melakukan tes 082298316902')}catch(_){}}"
new_stop = "if(d.free_test_disabled===true&&window.v11GetActiveCode?.()==='__TEST10__'){try{console.info('FREE TEST dinonaktifkan untuk sesi baru; sesi lokal yang sedang berjalan dibiarkan selesai agar layar login/Admin tetap bisa dipakai.')}catch(_){}}"
if old_stop not in cloud:
    raise SystemExit("V12.3.1 FREE TEST auto-stop anchor mismatch; refusing patch.")
cloud = cloud.replace(old_stop, new_stop, 1)

# Synchronize the existing pairing credential to a separate Electron watchdog process.
cloud_anchor = "  const read=()=>{try{return JSON.parse(localStorage.getItem(CLOUD_KEY)||'{}')}catch(_){return{}}};"
cloud_helper = """  const read=()=>{try{return JSON.parse(localStorage.getItem(CLOUD_KEY)||'{}')}catch(_){return{}}};
  function syncWatchdogCredentials(){
    try{
      const c=read()||{},api=window.electronAPI?.syncWatchdogCredentials;
      if(typeof api==='function')void api({token:String(c.token||''),deviceId:String(c.deviceId||''),orgId:String(c.orgId||''),clientId:String(c.clientId||''),appVersion:APP}).catch(()=>{});
    }catch(_){}
  }"""
cloud = replace_once(cloud, cloud_anchor, cloud_helper, "Watchdog credential helper")
cloud = replace_once(
    cloud,
    "save({token:d.token,deviceId:d.device_id,orgId:d.org_id,clientId:d.client_id});resumeCloudAuthoritative=Boolean(d.resumed_existing);",
    "save({token:d.token,deviceId:d.device_id,orgId:d.org_id,clientId:d.client_id});syncWatchdogCredentials();resumeCloudAuthoritative=Boolean(d.resumed_existing);",
    "Pairing credential handoff",
)
cloud = replace_once(
    cloud,
    "function v11DisconnectDevice(){localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);",
    "function v11DisconnectDevice(){localStorage.removeItem(CLOUD_KEY);syncWatchdogCredentials();localStorage.removeItem(SYNC_CURSOR_KEY);",
    "Watchdog credential clear on disconnect",
)
cloud = replace_once(
    cloud,
    "window.addEventListener('load',()=>{const users=window.v11GetUsers?.()||{};",
    "window.addEventListener('load',()=>{syncWatchdogCredentials();const users=window.v11GetUsers?.()||{};",
    "Watchdog credential handoff on launch",
)

# Timer-health pulse: main process can detect a stuck renderer/timer independently of its own interval.
timer_anchor = "        let currentActiveCode = null;\n        let timerInterval = null;\n        let timerDeadlineMs = null;"
timer_pulse = """        let currentActiveCode = null;
        let timerInterval = null;
        let timerDeadlineMs = null;
        // V12.3.3 independent pulse to Electron main; it detects a frozen renderer/timer.
        setInterval(() => {
            try {
                const text = String(document.getElementById('timer-display')?.innerText || '00:00:00');
                const parts = text.split(':').map(v => Number(v));
                const displaySeconds = parts.length === 3 && parts.every(Number.isFinite)
                    ? parts[0] * 3600 + parts[1] * 60 + parts[2] : null;
                window.electronAPI?.timerHealthPulse?.({
                    activeCode: currentActiveCode ? String(currentActiveCode) : null,
                    deadlineMs: Number.isFinite(Number(timerDeadlineMs)) ? Number(timerDeadlineMs) : null,
                    displaySeconds: displaySeconds,
                    at: Date.now()
                });
            } catch (_) {}
        }, 3000);"""
index = replace_once(index, timer_anchor, timer_pulse, "Independent timer-health pulse")

# Expose only narrow IPC surfaces. The pairing token is encrypted with OS-backed safeStorage by main.js.
preload_anchor = "    readBackupFile: (filePath) => ipcRenderer.invoke('read-backup-file', String(filePath || ''))\n});"
preload_new = """    readBackupFile: (filePath) => ipcRenderer.invoke('read-backup-file', String(filePath || '')),
    syncWatchdogCredentials: (credentials) => ipcRenderer.invoke('watchdog-credentials', credentials),
    timerHealthPulse: (payload) => ipcRenderer.send('timer-health-pulse', payload)
});"""
preload = replace_once(preload, preload_anchor, preload_new, "Preload watchdog IPC")

# Main process: spawn a detached sibling Electron process. It survives an ordinary process kill
# and listens only for restart_billing commands; it never consumes normal rental/admin commands.
main = replace_once(
    main,
    "const { app, BrowserWindow, ipcMain, dialog } = require('electron');",
    "const { app, BrowserWindow, ipcMain, dialog, safeStorage } = require('electron');",
    "safeStorage import",
)
main = replace_once(
    main,
    "const fs = require('fs');\nconst { execFile } = require('child_process');",
    "const fs = require('fs');\nconst { execFile, spawn } = require('child_process');\n// V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG\nconst WATCHDOG_AGENT_MODE = process.argv.includes('--ani-watchdog-agent');\nconst DB1_API_URL = 'https://wzkjpycjizexxcxrfdvr.supabase.co/functions/v1/ani-games-api';\nconst DB1_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI';\nlet timerHealth = { at: 0, activeCode: null, deadlineMs: null, displaySeconds: null, mismatchCount: 0 };\nlet lastTimerRecoveryAt = 0;",
    "Watchdog mode constants",
)

watchdog_helpers = r"""
function watchdogFiles() {
    const dir = app.getPath('userData');
    return {
        dir,
        main: path.join(dir, 'ani-games-billing-main.json'),
        agent: path.join(dir, 'ani-games-watchdog.pid'),
        credentials: path.join(dir, 'ani-games-watchdog-credentials.bin'),
        disabled: path.join(dir, 'ani-games-watchdog-disabled.flag')
    };
}
function readJsonFile(file) {
    try { return JSON.parse(fs.readFileSync(file, 'utf8')); } catch (_) { return null; }
}
function isPidAlive(pid) {
    const n = Number(pid);
    if (!Number.isInteger(n) || n <= 0) return false;
    try { process.kill(n, 0); return true; }
    catch (e) { return e && e.code === 'EPERM'; }
}
function writeMainProcessState(ready) {
    try {
        const files = watchdogFiles();
        fs.mkdirSync(files.dir, { recursive: true });
        fs.writeFileSync(files.main, JSON.stringify({
            pid: process.pid, ready: Boolean(ready), updatedAt: Date.now(),
            execPath: process.execPath
        }), 'utf8');
    } catch (e) { console.error('Gagal menyimpan status proses Billing:', e?.message || e); }
}
function removeMainProcessState() {
    try {
        const files = watchdogFiles(), state = readJsonFile(files.main);
        if (Number(state?.pid) === process.pid) fs.unlinkSync(files.main);
    } catch (_) {}
}
function launchWatchdogAgent() {
    if (WATCHDOG_AGENT_MODE) return;
    try {
        const files = watchdogFiles();
        fs.mkdirSync(files.dir, { recursive: true });
        try { fs.unlinkSync(files.disabled); } catch (_) {}
        let current = 0;
        try { current = Number(String(fs.readFileSync(files.agent, 'utf8')).trim()); } catch (_) {}
        if (isPidAlive(current)) return;
        const child = spawn(process.execPath, ['--ani-watchdog-agent'], {
            detached: true, stdio: 'ignore', windowsHide: true
        });
        child.unref();
    } catch (e) { console.error('Watchdog tidak dapat dijalankan:', e?.message || e); }
}
function stopWatchdogAgent() {
    try {
        const files = watchdogFiles();
        fs.mkdirSync(files.dir, { recursive: true });
        fs.writeFileSync(files.disabled, String(Date.now()), 'utf8');
        const pid = Number(String(fs.readFileSync(files.agent, 'utf8')).trim());
        if (isPidAlive(pid) && pid !== process.pid) process.kill(pid);
    } catch (_) {}
}
function readWatchdogCredentials() {
    try {
        const files = watchdogFiles();
        if (!safeStorage.isEncryptionAvailable()) return null;
        const raw = safeStorage.decryptString(fs.readFileSync(files.credentials));
        const value = JSON.parse(raw);
        if (!value || typeof value !== 'object' || !value.token || !value.deviceId || !value.clientId) return null;
        return value;
    } catch (_) { return null; }
}
async function watchdogRequest(pathname, credentials, extra = {}) {
    const response = await fetch(DB1_API_URL + '/' + pathname, {
        method: 'POST',
        headers: { apikey: DB1_ANON_KEY, 'content-type': 'application/json' },
        body: JSON.stringify({ token: credentials.token, ...extra }),
        signal: AbortSignal.timeout(7000)
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || data?.ok === false) throw new Error(String(data?.error || ('HTTP ' + response.status)));
    return data;
}
async function waitForBillingReady(launchAt, timeoutMs = 30000) {
    const started = Date.now();
    while (Date.now() - started < timeoutMs) {
        const state = readJsonFile(watchdogFiles().main);
        // Portable Electron launchers may create a child process; match the fresh main-state PID, not the wrapper PID.
        if (Number(state?.updatedAt || 0) >= launchAt && state?.ready === true && isPidAlive(state?.pid)) return true;
        await new Promise(resolve => setTimeout(resolve, 500));
    }
    return false;
}
async function watchdogTick(state) {
    const files = watchdogFiles();
    if (fs.existsSync(files.disabled)) { app.quit(); return; }
    const mainState = readJsonFile(files.main);
    if (isPidAlive(mainState?.pid)) { state.missingSince = 0; return; }
    if (!state.missingSince) state.missingSince = Date.now();
    // Avoid mistaking the normal Electron relaunch handoff for a crash.
    if (Date.now() - state.missingSince < 12000 || state.busy || Date.now() - state.lastPollAt < 8000) return;
    const credentials = readWatchdogCredentials();
    if (!credentials) return;
    state.busy = true;
    state.lastPollAt = Date.now();
    try {
        const data = await watchdogRequest('device/watchdog', credentials, {
            deviceId: credentials.deviceId, clientId: credentials.clientId, appVersion: 'V12.3.3-watchdog'
        });
        for (const command of (Array.isArray(data.commands) ? data.commands : [])) {
            if (String(command?.command || '') !== 'restart_billing') continue;
            const targetId = String(command?.payload?.targetDeviceId || command?.payload?.deviceId || '');
            if (targetId && targetId !== String(credentials.deviceId)) {
                await watchdogRequest('device/ack', credentials, {
                    commandId: command.id, status: 'failed',
                    result: { ok: false, message: 'WATCHDOG_TARGET_DEVICE_MISMATCH' }
                }).catch(() => {});
                continue;
            }
            let child = null;
            try {
                const launchAt = Date.now();
                child = spawn(process.execPath, [], { detached: true, stdio: 'ignore', windowsHide: false });
                child.unref();
                const ready = await waitForBillingReady(launchAt, 30000);
                await watchdogRequest('device/ack', credentials, {
                    commandId: command.id, status: ready ? 'completed' : 'failed',
                    result: { ok: ready, phase: ready ? 'watchdog_app_ready' : 'watchdog_launch_timeout', pid: child.pid || null }
                }).catch(() => {});
                if (ready) { state.missingSince = 0; return; }
            } catch (e) {
                await watchdogRequest('device/ack', credentials, {
                    commandId: command.id, status: 'failed',
                    result: { ok: false, message: String(e?.message || 'WATCHDOG_LAUNCH_FAILED').slice(0, 180) }
                }).catch(() => {});
            }
        }
    } catch (e) {
        // Network/API outages are intentionally silent here; the local Billing remains available for manual launch.
    } finally { state.busy = false; }
}
function runWatchdogAgent() {
    const files = watchdogFiles();
    fs.mkdirSync(files.dir, { recursive: true });
    try {
        const oldPid = Number(String(fs.readFileSync(files.agent, 'utf8')).trim());
        if (isPidAlive(oldPid) && oldPid !== process.pid) { app.quit(); return; }
    } catch (_) {}
    try { fs.writeFileSync(files.agent, String(process.pid), 'utf8'); } catch (_) {}
    const state = { missingSince: 0, lastPollAt: 0, busy: false };
    const tick = () => { void watchdogTick(state); };
    tick();
    const timer = setInterval(tick, 5000);
    app.on('before-quit', () => {
        clearInterval(timer);
        try {
            const pid = Number(String(fs.readFileSync(files.agent, 'utf8')).trim());
            if (pid === process.pid) fs.unlinkSync(files.agent);
        } catch (_) {}
    });
}
"""

main_anchor = "const approvedBackupRoots = new Set();"
main = replace_once(main, main_anchor, main_anchor + "\n" + watchdog_helpers, "Watchdog helper insertion")

# Secure credential IPC: OS-backed encryption; never log or expose the pairing token.
credential_anchor = "ipcMain.handle('restart-billing', (event) => {"
credential_handler = """ipcMain.handle('watchdog-credentials', (event, raw) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return { ok: false, message: 'Pemanggil tidak valid.' };
    try {
        const files = watchdogFiles();
        const value = raw && typeof raw === 'object' ? raw : {};
        const token = String(value.token || '').trim();
        if (!token) {
            try { fs.unlinkSync(files.credentials); } catch (_) {}
            return { ok: true, cleared: true };
        }
        if (token.length > 512 || !String(value.deviceId || '').trim() || !String(value.clientId || '').trim()) {
            return { ok: false, message: 'Identitas watchdog tidak valid.' };
        }
        if (!safeStorage.isEncryptionAvailable()) return { ok: false, message: 'Enkripsi penyimpanan OS tidak tersedia; watchdog tidak diaktifkan.' };
        fs.mkdirSync(files.dir, { recursive: true });
        const encrypted = safeStorage.encryptString(JSON.stringify({
            token, deviceId: String(value.deviceId), clientId: String(value.clientId),
            orgId: String(value.orgId || ''), appVersion: String(value.appVersion || '')
        }));
        fs.writeFileSync(files.credentials, encrypted);
        return { ok: true };
    } catch (e) {
        return { ok: false, message: String(e?.message || 'Penyimpanan kredensial watchdog gagal.') };
    }
});
ipcMain.on('timer-health-pulse', (event, payload) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return;
    const p = payload && typeof payload === 'object' ? payload : {};
    const activeCode = String(p.activeCode || '').trim().slice(0, 128) || null;
    const deadlineMs = Number(p.deadlineMs);
    const displaySeconds = Number(p.displaySeconds);
    let mismatchCount = 0;
    if (activeCode && Number.isFinite(deadlineMs) && deadlineMs > 0 && Number.isFinite(displaySeconds)) {
        const expected = Math.max(0, Math.ceil((deadlineMs - Date.now()) / 1000));
        mismatchCount = Math.abs(expected - displaySeconds) >= 2 ? (timerHealth.mismatchCount || 0) + 1 : 0;
    }
    timerHealth = { at: Date.now(), activeCode, deadlineMs: Number.isFinite(deadlineMs) ? deadlineMs : null,
        displaySeconds: Number.isFinite(displaySeconds) ? displaySeconds : null, mismatchCount };
});

"""
main = replace_once(main, credential_anchor, credential_handler + credential_anchor, "Watchdog IPC insertion")

# Restart keeps the watchdog running; explicit total exit deliberately stops it.
main = replace_once(
    main,
    "        allowBillingExit = true;\n        app.relaunch();",
    "        try { fs.unlinkSync(watchdogFiles().disabled); } catch (_) {}\n        launchWatchdogAgent();\n        allowBillingExit = true;\n        app.relaunch();",
    "Watchdog remains available during restart",
)
main = replace_once(
    main,
    "        allowBillingExit = true;\n        setTimeout(() => app.quit(), 0);",
    "        stopWatchdogAgent();\n        removeMainProcessState();\n        allowBillingExit = true;\n        setTimeout(() => app.quit(), 0);",
    "Stop watchdog on explicit total exit",
)

# A renderer that reports stale/frozen timer state is reloaded by the Electron main process.
main = replace_once(
    main,
    "    protectedWindow.webContents.on('unresponsive', () => {\n        console.error('Renderer Billing tidak merespons; menunggu sebelum pemulihan.');\n        setTimeout(() => {\n            if (!protectedWindow.isDestroyed() && protectedWindow.webContents.isCrashed()) {\n                protectedWindow.loadFile('index.html').catch(err => console.error('Pemulihan renderer Billing gagal:', err));\n            }\n        }, 5000);\n    });",
    """    protectedWindow.webContents.on('unresponsive', () => {
        console.error('Renderer Billing tidak merespons; timer-health akan menentukan pemulihan.');
        setTimeout(() => {
            if (WATCHDOG_AGENT_MODE || protectedWindow.isDestroyed()) return;
            const staleTimer = timerHealth.activeCode && Date.now() - timerHealth.at > 8000;
            const stuckDisplay = timerHealth.activeCode && timerHealth.mismatchCount >= 2;
            if (protectedWindow.webContents.isCrashed()) {
                protectedWindow.loadFile('index.html').catch(err => console.error('Pemulihan renderer Billing gagal:', err));
            } else if ((staleTimer || stuckDisplay) && Date.now() - lastTimerRecoveryAt > 20000) {
                lastTimerRecoveryAt = Date.now();
                protectedWindow.webContents.reload();
            }
        }, 5000);
    });""",
    "Renderer unresponsive recovery",
)

main = replace_once(
    main,
    "            mainWindow.setFocusable(true);\n            mainWindow.focus();",
    "            mainWindow.setFocusable(true);\n            mainWindow.focus();\n            writeMainProcessState(true);",
    "Billing ready state",
)
# Main boot: agent mode has no UI, while the normal app records its PID and launches the detached watcher.
main = replace_once(
    main,
    "app.on('before-quit', (event) => {\n    if (allowBillingExit) return;",
    """app.on('before-quit', (event) => {
    if (WATCHDOG_AGENT_MODE) return;
    if (allowBillingExit) { removeMainProcessState(); return; }""",
    "Agent must be allowed to exit",
)
main = replace_once(
    main,
    "app.whenReady().then(() => {\n    createWindow();",
    """app.whenReady().then(() => {
    if (WATCHDOG_AGENT_MODE) { runWatchdogAgent(); return; }
    writeMainProcessState(false);
    launchWatchdogAgent();
    // Main-process watchdog can recover a frozen renderer while a rental timer is active.
    setInterval(() => {
        if (!mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode) return;
        const stale = Date.now() - Number(timerHealth.at || 0) > 12000;
        const stuck = Number(timerHealth.mismatchCount || 0) >= 2;
        if ((stale || stuck) && Date.now() - lastTimerRecoveryAt > 20000) {
            lastTimerRecoveryAt = Date.now();
            try { mainWindow.webContents.reload(); } catch (e) { console.error('Pemulihan timer gagal:', e?.message || e); }
        }
    }, 5000);
    createWindow();""",
    "Main launch / watchdog branch",
)
main = replace_once(
    main,
    "app.on('window-all-closed', () => {\n    if (process.platform !== 'darwin') app.quit();\n});",
    "if (!WATCHDOG_AGENT_MODE) app.on('window-all-closed', () => {\n    if (process.platform !== 'darwin') app.quit();\n});",
    "Agent must not auto-quit on no windows",
)

# New RPC route for the watchdog only. Normal device commands remain owned by the live renderer.
if "p===\"device/watchdog\"" not in api:
    api = replace_once(
        api,
        'if(p==="device/heartbeat")return out(200,{ok:true,...await rpc("device_heartbeat",{p_token:String(b.token||""),p_app_version:String(b.appVersion||""),p_metadata:b.metadata||{}})});',
        'if(p==="device/heartbeat")return out(200,{ok:true,...await rpc("device_heartbeat",{p_token:String(b.token||""),p_app_version:String(b.appVersion||""),p_metadata:b.metadata||{}})});\nif(p==="device/watchdog")return out(200,{ok:true,...await rpc("device_watchdog_poll",{p_token:String(b.token||"")})});',
        "Watchdog API route",
    )

# Align all visible runtime version identities and package metadata.
index = index.replace(OLD_MARKER, MARKER)
renderer = renderer.replace(OLD_MARKER, MARKER)
cloud = cloud.replace("APP='V12.3.1-HEARTBEAT-WRITE-OPTIMIZATION'", "APP='" + MARKER + "'")
cloud = cloud.replace("// BUILD_ID: V12.3.1-HEARTBEAT-WRITE-OPTIMIZATION", "// BUILD_ID: " + MARKER)
package["version"] = "12.3.3"
package["description"] = "AniGames Billing V12.3.3: offline-safe local free test, timer-health recovery, and detached authenticated watchdog for Admin remote restart"
if isinstance(package.get("build"), dict):
    package["build"]["productName"] = "AniGames Billing V12.3.3"
lock_path = ROOT / "package-lock.json"
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = "12.3.3"
    if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
        lock["packages"][""]["version"] = "12.3.3"
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

main_path.write_text(main, encoding="utf-8")
index_path.write_text(index, encoding="utf-8")
renderer_path.write_text(renderer, encoding="utf-8")
preload_path.write_text(preload, encoding="utf-8")
cloud_path.write_text(cloud, encoding="utf-8")
api_path.write_text(api, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text(
    "AniGames Billing PC V12.3.3 — offline-safe local FREE TEST, timer-health renderer recovery, encrypted device credential handoff, and detached agent that can process restart_billing after the main process is killed. Physical PC test still required.\n",
    encoding="utf-8",
)

for token in [
    "V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG", "WATCHDOG_AGENT_MODE", "runWatchdogAgent()",
    "device/watchdog", "watchdog-credentials", "safeStorage.encryptString", "safeStorage.decryptString",
    "timer-health-pulse", "timerHealth.mismatchCount", "stopWatchdogAgent()", "showCustomModal",
]:
    if token not in main + index + preload + cloud + api:
        raise SystemExit("V12.3.3 source assertion missing: " + token)
if package.get("version") != "12.3.3" or OLD_MARKER in index or OLD_MARKER in renderer:
    raise SystemExit("V12.3.3 version identity mismatch")
if "if(d.free_test_disabled===true&&window.v11GetActiveCode?.()==='__TEST10__'){try{await window.v11ApplyRemoteCommand?.('stop'" in cloud:
    raise SystemExit("Old auto-stop behavior for disabled FREE TEST remains")
if "FREE TEST dinonaktifkan untuk sesi baru" not in cloud:
    raise SystemExit("Existing FREE TEST continuity assertion missing")
print("PASS: V12.3.3 offline-safe FREE TEST, disabled-policy UI continuity, timer-health recovery, encrypted credentials, separate restart watchdog, and API route.")
