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
preload = replace_once(
    preload,
    "    exitBilling: () => ipcRenderer.invoke('exit-billing'),",
    "    exitBilling: (options = {}) => ipcRenderer.invoke('exit-billing', options),\n    onBillingCloseAttempt: (callback) => { if (typeof callback !== 'function') return () => {}; const listener = () => callback(); ipcRenderer.on('billing-close-attempt', listener); return () => ipcRenderer.removeListener('billing-close-attempt', listener); },\n    cancelBillingClose: () => ipcRenderer.invoke('billing-close-cancelled'),\n    authorizeBillingClose: () => ipcRenderer.invoke('billing-close-authorized'),",
    "Expose password-gated close IPC",
)

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

main = replace_once(
    main,
    "let lastTimerRecoveryAt = 0;",
    "let lastTimerRecoveryAt = 0;\nlet closePromptInProgress = false;\nlet closePromptPending = false;",
    "Close password prompt state",
)
close_prompt_helper = """function requestBillingClosePassword(targetWindow) {
    if (closePromptInProgress) return;
    closePromptInProgress = true;
    closePromptPending = true;
    try {
        if (targetWindow && !targetWindow.isDestroyed() && !targetWindow.webContents.isLoading()) {
            targetWindow.webContents.send('billing-close-attempt');
            closePromptPending = false;
        }
    } catch (e) {
        closePromptPending = false;
        closePromptInProgress = false;
        console.error('Tidak bisa meminta password sebelum keluar:', e?.message || e);
    }
}
"""
main = replace_once(main, "function watchdogFiles() {", close_prompt_helper + "\nfunction watchdogFiles() {", "Close prompt helper")
old_close_guard = """    protectedWindow.on('close', (event) => {
        if (allowBillingExit) return;
        event.preventDefault();
        try {
            if (protectedWindow.isMinimized()) protectedWindow.restore();
            protectedWindow.show();
            protectedWindow.focus();
        } catch (err) {
            console.error('Gagal memulihkan window Billing setelah percobaan close:', err);
        }
    });"""
new_close_guard = """    protectedWindow.on('close', (event) => {
        if (allowBillingExit) return;
        event.preventDefault();
        requestBillingClosePassword(protectedWindow);
        try {
            if (protectedWindow.isMinimized()) protectedWindow.restore();
            protectedWindow.show();
            protectedWindow.focus();
        } catch (err) {
            console.error('Gagal memulihkan window Billing setelah percobaan close:', err);
        }
    });"""
main = replace_once(main, old_close_guard, new_close_guard, "Password-gated X and Alt-F4")

close_ipc = """ipcMain.handle('billing-close-cancelled', (event) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return { ok: false, message: 'Pemanggil tidak valid.' };
    closePromptInProgress = false;
    closePromptPending = false;
    try { if (mainWindow && !mainWindow.isDestroyed()) { mainWindow.show(); mainWindow.focus(); } } catch (_) {}
    return { ok: true };
});
ipcMain.handle('billing-close-authorized', (event) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return { ok: false, message: 'Pemanggil tidak valid.' };
    try {
        closePromptInProgress = false;
        closePromptPending = false;
        try { fs.unlinkSync(watchdogFiles().disabled); } catch (_) {}
        launchWatchdogAgent();
        removeMainProcessState();
        allowBillingExit = true;
        if (mainWindow && !mainWindow.isDestroyed()) mainWindow.close();
        else setTimeout(() => app.quit(), 0);
        return { ok: true, mode: 'normal', watchdog: 'kept_running' };
    } catch (e) {
        allowBillingExit = false;
        return { ok: false, message: String(e?.message || 'Keluar Billing gagal.') };
    }
});
"""
# Close IPC is inserted after the watchdog credential handler below.

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
main = replace_once(main, "ipcMain.handle('watchdog-credentials', (event, raw) => {", close_ipc + "\nipcMain.handle('watchdog-credentials', (event, raw) => {", "Close prompt authorization IPC")

# Restart keeps the watchdog running; explicit total exit deliberately stops it.
main = replace_once(
    main,
    "        allowBillingExit = true;\n        app.relaunch();",
    "        try { fs.unlinkSync(watchdogFiles().disabled); } catch (_) {}\n        launchWatchdogAgent();\n        allowBillingExit = true;\n        app.relaunch();",
    "Watchdog remains available during restart",
)
main = replace_once(main, "ipcMain.handle('exit-billing', (event) => {", "ipcMain.handle('exit-billing', (event, options = {}) => {", "Exit mode argument")
main = replace_once(
    main,
    "        allowBillingExit = true;\n        setTimeout(() => app.quit(), 0);",
    "        const totalExit = options && options.total === true;\n        if (totalExit) stopWatchdogAgent();\n        else { try { fs.unlinkSync(watchdogFiles().disabled); } catch (_) {} launchWatchdogAgent(); }\n        removeMainProcessState();\n        closePromptInProgress = false;\n        closePromptPending = false;\n        allowBillingExit = true;\n        setTimeout(() => app.quit(), 0);",
    "Normal exit keeps watchdog; Exit Total stops it",
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
main = replace_once(
    main,
    "            writeMainProcessState(true);",
    "            writeMainProcessState(true);\n            if (closePromptPending && closePromptInProgress) { closePromptPending = false; mainWindow.webContents.send('billing-close-attempt'); }",
    "Send pending close prompt after page load",
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


# Require the existing Admin PIN/password on ordinary X/Alt+F4 close attempts.
old_auth_markup = """<div class="modal-title">AKSES ADMIN</div>
            <p class="modal-message">Masukkan PIN Admin untuk mengakses konfigurasi billing.</p>
            <input type="password" id="admin-pin-input" class="input-code" placeholder="PIN ADMIN" style="margin-bottom: 15px; font-size: 16px;">
            <div style="display: flex; gap: 10px;">
                <button class="btn btn-secondary" style="flex: 1;" onclick="closeAdminAuth()">Batal</button>
                <button class="btn btn-primary" style="flex: 1;" onclick="submitAdminAuth()">Masuk</button>
            </div>"""
new_auth_markup = """<div class="modal-title" id="admin-auth-title">AKSES ADMIN</div>
            <p class="modal-message" id="admin-auth-message">Masukkan PIN Admin untuk mengakses konfigurasi billing.</p>
            <input type="password" id="admin-pin-input" class="input-code" placeholder="PIN ADMIN" style="margin-bottom: 15px; font-size: 16px;" autocomplete="current-password">
            <div style="display: flex; gap: 10px;">
                <button id="admin-auth-cancel" class="btn btn-secondary" style="flex: 1;" onclick="closeAdminAuth()">Batal</button>
                <button id="admin-auth-submit" class="btn btn-primary" style="flex: 1;" onclick="submitAdminAuth()">Masuk</button>
            </div>"""
index = replace_once(index, old_auth_markup, new_auth_markup, "Admin auth modal markup")

old_open_auth = """        function openAdminAuth() {
            document.getElementById('admin-pin-input').value = '';
            document.getElementById('admin-login-modal').classList.remove('hidden');
            focusAdminPinInput();
        }"""
new_open_auth = """        let adminAuthPurpose = 'admin';
        function restoreAdminAuthModalCopy() {
            document.getElementById('admin-auth-title').textContent = 'AKSES ADMIN';
            document.getElementById('admin-auth-message').textContent = 'Masukkan PIN Admin untuk mengakses konfigurasi billing.';
            document.getElementById('admin-auth-message').style.color = '';
            document.getElementById('admin-auth-cancel').textContent = 'Batal';
            document.getElementById('admin-auth-submit').textContent = 'Masuk';
        }
        function openAdminAuth() {
            adminAuthPurpose = 'admin';
            restoreAdminAuthModalCopy();
            document.getElementById('admin-pin-input').value = '';
            document.getElementById('admin-login-modal').classList.remove('hidden');
            focusAdminPinInput();
        }"""
index = replace_once(index, old_open_auth, new_open_auth, "Separate Admin login from exit authorization")

old_close_auth = """        function closeAdminAuth() {
            document.getElementById('admin-login-modal').classList.add('hidden');
        }"""
new_close_auth = """        function closeAdminAuth() {
            const closeAttempt = adminAuthPurpose === 'close';
            document.getElementById('admin-login-modal').classList.add('hidden');
            adminAuthPurpose = 'admin';
            restoreAdminAuthModalCopy();
            if (closeAttempt) void window.electronAPI?.cancelBillingClose?.();
        }"""
index = replace_once(index, old_close_auth, new_close_auth, "Cancel close prompt")

old_submit_auth = """        async function submitAdminAuth() {
            const inputPin = document.getElementById('admin-pin-input').value.trim();
            let valid = inputPin === ADMIN_PIN;
            try {
                const storedHash = localStorage.getItem(ADMIN_CUSTOM_PIN_HASH_KEY);
                if (storedHash) valid = valid || (await hashAdminPin(inputPin)) === storedHash;
                else {
                    // Kompatibilitas build lama: migrasikan password plaintext sekali setelah login sukses.
                    const legacy = localStorage.getItem(ADMIN_CUSTOM_PIN_KEY);
                    if (legacy && inputPin === legacy) {
                        localStorage.setItem(ADMIN_CUSTOM_PIN_HASH_KEY, await hashAdminPin(legacy));
                        localStorage.removeItem(ADMIN_CUSTOM_PIN_KEY);
                        valid = true;
                    }
                }
            } catch (e) {
                valid = getAdminPins().includes(inputPin);
            }
            if (valid) {
                closeAdminAuth();
                renderUserTable();
                renderThemeList();
                document.getElementById('admin-panel').classList.remove('hidden');
            } else {
                closeAdminAuth();
                showCustomModal("PIN Admin Salah!", "AKSES DITOLAK", true, "🔒");
            }
        }"""
new_submit_auth = """        async function submitAdminAuth() {
            const input = document.getElementById('admin-pin-input');
            const inputPin = input.value.trim();
            const closeAttempt = adminAuthPurpose === 'close';
            let valid = inputPin === ADMIN_PIN;
            try {
                const storedHash = localStorage.getItem(ADMIN_CUSTOM_PIN_HASH_KEY);
                if (storedHash) valid = valid || (await hashAdminPin(inputPin)) === storedHash;
                else {
                    // Kompatibilitas build lama: migrasikan password plaintext sekali setelah login sukses.
                    const legacy = localStorage.getItem(ADMIN_CUSTOM_PIN_KEY);
                    if (legacy && inputPin === legacy) {
                        localStorage.setItem(ADMIN_CUSTOM_PIN_HASH_KEY, await hashAdminPin(legacy));
                        localStorage.removeItem(ADMIN_CUSTOM_PIN_KEY);
                        valid = true;
                    }
                }
            } catch (e) {
                valid = getAdminPins().includes(inputPin);
            }
            if (valid && closeAttempt) {
                document.getElementById('admin-login-modal').classList.add('hidden');
                adminAuthPurpose = 'admin';
                restoreAdminAuthModalCopy();
                const result = await window.electronAPI?.authorizeBillingClose?.();
                if (result?.ok === false) {
                    showCustomModal('Keluar Billing gagal: ' + String(result.message || 'izin ditolak'), 'KELUAR BILLING', true, '⚠️');
                }
                return;
            }
            if (valid) {
                closeAdminAuth();
                renderUserTable();
                renderThemeList();
                document.getElementById('admin-panel').classList.remove('hidden');
            } else if (closeAttempt) {
                document.getElementById('admin-auth-message').textContent = 'Password salah. Billing tetap berjalan; coba lagi atau tekan Batal.';
                document.getElementById('admin-auth-message').style.color = '#ff6b86';
                input.value = '';
                focusAdminPinInput();
            } else {
                closeAdminAuth();
                showCustomModal("PIN Admin Salah!", "AKSES DITOLAK", true, "🔒");
            }
        }"""
index = replace_once(index, old_submit_auth, new_submit_auth, "Verify the existing Admin password before closing")

close_listener = """        window.electronAPI?.onBillingCloseAttempt?.(() => {
            adminAuthPurpose = 'close';
            restoreAdminAuthModalCopy();
            document.getElementById('admin-auth-title').textContent = 'KONFIRMASI KELUAR BILLING';
            document.getElementById('admin-auth-message').textContent = 'Masukkan password Admin Billing untuk keluar. Jika batal atau password salah, Billing tetap berjalan.';
            document.getElementById('admin-auth-cancel').textContent = 'Batal / Tetap Buka';
            document.getElementById('admin-auth-submit').textContent = 'Keluar Billing';
            document.getElementById('admin-pin-input').value = '';
            document.getElementById('admin-login-modal').classList.remove('hidden');
            focusAdminPinInput();
        });

"""
index = replace_once(index, "        document.getElementById('admin-pin-input').addEventListener('keypress', function(e) {", close_listener + "        document.getElementById('admin-pin-input').addEventListener('keypress', function(e) {", "Handle X and Alt-F4 close request")

old_exit_button = """<button type="button" class="btn btn-danger" onclick="exitBillingApp()">🚪 Exit Billing</button>"""
new_exit_button = """<button type="button" class="btn btn-danger" onclick="exitBillingApp(false)">🚪 Keluar Billing (Restart Jarak Jauh Tetap Aktif)</button>
                        <button type="button" class="btn btn-danger" onclick="exitBillingApp(true)">⛔ Exit Total / Maintenance</button>
                        <small class="theme-help" style="grid-column:1/-1">Keluar Billing menjaga agen pemulih tetap hidup. Exit Total menghentikan agen; PC tidak dapat direstart dari Admin APK sampai Billing dibuka lagi.</small>"""
index = replace_once(index, old_exit_button, new_exit_button, "Distinct normal and total exit buttons")

old_exit_fn = """        async function exitBillingApp() {
            if (!window.electronAPI?.exitBilling) return showCustomModal('Fungsi Exit Billing belum tersedia.', 'ERROR', true, '⚠️');
            if (!confirm('Yakin ingin keluar total dari Billing?')) return;
            try {
                persistActiveSession();
                saveDB();
                writeSystemLog('Exit Billing dari Admin.');
                await window.electronAPI.exitBilling();
            } catch (error) {
                showCustomModal('Exit Billing gagal: ' + error.message, 'EXIT GAGAL', true, '⚠️');
            }
        }"""
new_exit_fn = """        async function exitBillingApp(totalExit = false) {
            if (!window.electronAPI?.exitBilling) return showCustomModal('Fungsi Exit Billing belum tersedia.', 'ERROR', true, '⚠️');
            const question = totalExit
                ? 'EXIT TOTAL / MAINTENANCE akan menghentikan agen pemulih. Restart Billing dari Admin APK tidak akan berfungsi sampai aplikasi dibuka lagi. Lanjutkan?'
                : 'Keluar dari tampilan Billing? Agen pemulih tetap aktif sehingga Admin APK masih dapat memanggil Billing. Lanjutkan?';
            if (!confirm(question)) return;
            try {
                persistActiveSession();
                saveDB();
                writeSystemLog(totalExit ? 'Exit Total / Maintenance dari Admin.' : 'Keluar Billing dari Admin; agen pemulih dipertahankan.');
                await window.electronAPI.exitBilling({ total: Boolean(totalExit) });
            } catch (error) {
                showCustomModal('Keluar Billing gagal: ' + error.message, 'EXIT GAGAL', true, '⚠️');
            }
        }"""
index = replace_once(index, old_exit_fn, new_exit_fn, "Normal versus total exit handler")

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
    "AniGames Billing PC V12.3.3 — offline-safe FREE TEST, timer-health recovery, detached restart watchdog, Admin-password close guard, and explicit normal/total exit. Physical PC test still required.\n",
    encoding="utf-8",
)

for token in [
    "V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG", "WATCHDOG_AGENT_MODE", "runWatchdogAgent()", "billing-close-attempt", "authorizeBillingClose", "cancelBillingClose", "Exit Total / Maintenance", "adminAuthPurpose",
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
