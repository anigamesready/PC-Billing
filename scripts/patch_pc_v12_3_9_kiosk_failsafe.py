from pathlib import Path
import json

R=Path('.')
mp=R/'main.js'; pp=R/'preload.js'; ip=R/'index.html'; rp=R/'renderer.js'; pkgp=R/'package.json'; lockp=R/'package-lock.json'; vp=R/'VERSION.txt'
main=mp.read_text(encoding='utf-8'); preload=pp.read_text(encoding='utf-8'); index=ip.read_text(encoding='utf-8'); renderer=rp.read_text(encoding='utf-8'); pkg=json.loads(pkgp.read_text(encoding='utf-8')); lock=json.loads(lockp.read_text(encoding='utf-8')) if lockp.exists() else None
TAG='V12.3.9-KIOSK-FAILSAFE'
if "ipcMain.on('billing-renderer-ready'" in main and TAG in index:
    print('PASS: V12.3.9 kiosk fail-safe already applied'); raise SystemExit(0)
if pkg.get('version')!='12.3.8' or "app.requestSingleInstanceLock({" not in main or "APP_VERSION = 'V12.3.8-AUTO-WOL-LAN-MAC'" not in index:
    raise SystemExit('Unexpected source baseline; expected V12.3.8 with single-instance and WOL fixes')

def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, got {n}')
    return s.replace(a,b,1)

main=once(main,"const { app, BrowserWindow, ipcMain, dialog, safeStorage } = require('electron');","const { app, BrowserWindow, ipcMain, dialog, safeStorage, globalShortcut } = require('electron');",'Electron import')
main=once(main,"let closePromptPending = false;\n\nlet mainWindow;","""let closePromptPending = false;
// V12.3.9: renderer readiness is required before the main process enables kiosk mode.
let billingUiReady = false, billingRecoveryMode = true, rendererReadyTimeout = null;
let rendererRecoveryStartedAt = 0, rendererRecoveryAttempts = 0, rendererRecoveryPending = false;
let mainWindow;""",'Recovery state')

helpers=r'''function clearRendererReadyTimeout(){if(rendererReadyTimeout)clearTimeout(rendererReadyTimeout);rendererReadyTimeout=null;}
function applyLoginKioskMode(w=mainWindow){if(!w||w.isDestroyed())return;w.setKiosk(true);w.setFullScreen(true);w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);if(w.isMinimized())w.restore();w.show();w.focus();}
function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);if(w.isMinimized())w.restore();w.setSize(500,76,true);w.center();w.show();}
function releaseDesktopLock(reason='recovery'){
  billingUiReady=false;billingRecoveryMode=true;clearRendererReadyTimeout();
  try{const w=mainWindow;if(w&&!w.isDestroyed()){w.setKiosk(false);w.setFullScreen(false);w.setAlwaysOnTop(false);w.setIgnoreMouseEvents(false);w.setFocusable(true);w.setResizable(true);w.setMinimizable(true);w.setSize(800,520,true);w.center();w.minimize();}}
  catch(e){console.error('Gagal melepas lock desktop:',e?.message||e);}
  writeMainProcessState(false);console.error('[AniGames V12.3.9] Desktop unlocked:',String(reason));
}
function armRendererReadyTimeout(w){clearRendererReadyTimeout();rendererReadyTimeout=setTimeout(()=>{if(mainWindow===w&&!w.isDestroyed()&&!billingUiReady)releaseDesktopLock('Billing UI tidak siap dalam 20 detik');},20000);}
function scheduleRendererRecovery(w,reason='renderer-error',delay=1600){
  if(WATCHDOG_AGENT_MODE||!w||w.isDestroyed()||mainWindow!==w)return;
  const now=Date.now();if(!rendererRecoveryStartedAt||now-rendererRecoveryStartedAt>120000){rendererRecoveryStartedAt=now;rendererRecoveryAttempts=0;}
  releaseDesktopLock(reason);if(rendererRecoveryPending)return;
  if(rendererRecoveryAttempts>=2){console.error('[AniGames V12.3.9] Limit recovery tercapai; Windows tetap terbuka.');return;}
  rendererRecoveryAttempts++;rendererRecoveryPending=true;
  setTimeout(()=>{rendererRecoveryPending=false;if(mainWindow!==w||w.isDestroyed())return;try{if(w.webContents.isCrashed())w.loadFile('index.html').catch(e=>console.error('Reload crash gagal:',e?.message||e));else w.webContents.reload();}catch(e){console.error('Recovery renderer gagal:',e?.message||e);}},Math.max(500,Number(delay)||1600));
}
function emergencyUnlockDesktop(source='Ctrl+Alt+F12'){releaseDesktopLock('Pemulihan darurat: '+source);}
'''
main=once(main,'function createWindow() {',helpers+'\nfunction createWindow() {','Recovery helpers')
main=once(main,"""        fullscreen: true,
        kiosk: true,
        alwaysOnTop: true,
        frame: false,
        transparent: true,
        resizable: false,
        minimizable: false,
        backgroundColor: '#00000000',""","""        fullscreen: false,
        kiosk: false,
        alwaysOnTop: false,
        frame: false,
        transparent: true,
        resizable: true,
        minimizable: true,
        show: true,
        backgroundColor: '#11101a',""",'Safe startup window')
# Re-launching the EXE after an emergency unlock retries the existing single instance.
main=once(main,"""            if (!mainWindow || mainWindow.isDestroyed()) {
                if (app.isReady()) createWindow();
                return;
            }
            if (mainWindow.isMinimized()) mainWindow.restore();
            mainWindow.show();
            mainWindow.focus();""","""            if (!mainWindow || mainWindow.isDestroyed()) {
                if (app.isReady()) createWindow();
                return;
            }
            if (mainWindow.isMinimized()) mainWindow.restore();
            if (billingRecoveryMode) { mainWindow.show(); mainWindow.focus(); mainWindow.webContents.reload(); return; }
            mainWindow.show();
            mainWindow.focus();""",'Second-instance recovery')
main=once(main,"""    protectedWindow.on('close', (event) => {
        if (allowBillingExit) return;
        event.preventDefault();""","""    protectedWindow.on('close', (event) => {
        if (allowBillingExit) return;
        if (billingRecoveryMode || !billingUiReady || protectedWindow.webContents.isCrashed()) { allowBillingExit = true; removeMainProcessState(); return; }
        event.preventDefault();""",'Recovery close bypass')
main=once(main,"""    protectedWindow.webContents.on('render-process-gone', (_event, details) => {
        console.error('Renderer Billing berhenti; memuat ulang UI tanpa menghapus data:', details?.reason || 'unknown');
        setTimeout(() => {
            if (!protectedWindow.isDestroyed() && protectedWindow.webContents.isCrashed()) {
                protectedWindow.loadFile('index.html').catch(err => console.error('Pemulihan renderer Billing gagal:', err));
            }
        }, 1200);
    });
    protectedWindow.webContents.on('unresponsive', () => {
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
    });

    mainWindow.loadFile('index.html');
    mainWindow.setAlwaysOnTop(true, 'screen-saver');

    mainWindow.webContents.on('did-finish-load', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.setFocusable(true);
            mainWindow.focus();
            writeMainProcessState(true);
            if (closePromptPending && closePromptInProgress) { closePromptPending = false; mainWindow.webContents.send('billing-close-attempt'); }
        }
    });""","""    protectedWindow.webContents.on('did-start-loading', () => {
        if (billingUiReady) releaseDesktopLock('Halaman Billing dimuat ulang');
        armRendererReadyTimeout(protectedWindow);
    });
    protectedWindow.webContents.on('did-fail-load', (_event, code, description, _url, isMainFrame) => {
        if (isMainFrame && !WATCHDOG_AGENT_MODE) scheduleRendererRecovery(protectedWindow, 'Gagal memuat Billing: '+String(description||code||'unknown'), 1800);
    });
    protectedWindow.webContents.on('render-process-gone', (_event, details) => scheduleRendererRecovery(protectedWindow, 'Renderer berhenti: '+String(details?.reason||'unknown'), 1200));
    protectedWindow.webContents.on('unresponsive', () => scheduleRendererRecovery(protectedWindow, 'Renderer Billing tidak merespons', 2200));
    mainWindow.loadFile('index.html');
    mainWindow.webContents.on('did-finish-load', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.setFocusable(true);
            if (!billingUiReady) { mainWindow.show(); mainWindow.focus(); }
            if (closePromptPending && closePromptInProgress) { closePromptPending = false; mainWindow.webContents.send('billing-close-attempt'); }
        }
    });""",'Renderer crash/load handling')

ready=r'''ipcMain.on('billing-renderer-ready',(event,payload)=>{
  if(WATCHDOG_AGENT_MODE||event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
  const p=payload&&typeof payload==='object'?payload:{};const active=p.activeSession===true;const code=String(p.activeCode||'').trim().slice(0,128)||null;const deadline=Number(p.deadlineMs);
  clearRendererReadyTimeout();billingUiReady=true;billingRecoveryMode=false;rendererRecoveryAttempts=0;rendererRecoveryStartedAt=0;rendererRecoveryPending=false;
  timerHealth={at:Date.now(),activeCode:active?code:null,deadlineMs:active&&Number.isFinite(deadline)?deadline:null,displaySeconds:null,mismatchCount:0};
  writeMainProcessState(true);if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);
});

'''
main=once(main,"// IPC Handler untuk Kunci / Buka Layar Billing\nipcMain.on('set-lock-mode'",ready+"// IPC Handler untuk Kunci / Buka Layar Billing\nipcMain.on('set-lock-mode'",'Renderer-ready IPC')
main=once(main,"""ipcMain.on('set-lock-mode', (event, isLocked) => {
    try {
        const shouldLock = Boolean(isLocked);

        if (mainWindow) {
            mainWindow.setKiosk(shouldLock);
            mainWindow.setFullScreen(shouldLock);
            mainWindow.setAlwaysOnTop(shouldLock, 'screen-saver');

            if (shouldLock) {
                // Kembali ke layar login fullscreen/kiosk.
                mainWindow.setIgnoreMouseEvents(false);
                mainWindow.setFocusable(true);
                mainWindow.focus();
            } else {
                // Saat sesi aktif, jendela dibuat sekecil timer dan tetap di atas desktop.
                mainWindow.setIgnoreMouseEvents(false);
                mainWindow.setAlwaysOnTop(true, 'floating');
                mainWindow.setResizable(false);
                if (mainWindow.isMinimized()) mainWindow.restore();
                mainWindow.setSize(500, 76, true);
                mainWindow.center();
            }
        }
    } catch (err) {
        console.error("Gagal mengubah mode lock:", err);
    }
});""","""ipcMain.on('set-lock-mode',(event,isLocked)=>{
  if(event.sender!==mainWindow?.webContents||!billingUiReady||billingRecoveryMode||!mainWindow||mainWindow.isDestroyed())return;
  try{if(Boolean(isLocked))applyLoginKioskMode(mainWindow);else applyActiveTimerWindowMode(mainWindow);}
  catch(e){console.error('Gagal mengubah mode lock:',e?.message||e);releaseDesktopLock('Gagal menerapkan mode lock');}
});""",'Guarded lock-mode IPC')
# Add recovery bypass to the actual V12.3.8 before-quit block.
main=once(main,"""app.on('before-quit', (event) => {
    if (WATCHDOG_AGENT_MODE || DUPLICATE_BILLING_PROCESS) return;
    if (allowBillingExit) { removeMainProcessState(); return; }
    event.preventDefault();""","""app.on('before-quit', (event) => {
    if (WATCHDOG_AGENT_MODE || DUPLICATE_BILLING_PROCESS) return;
    if (allowBillingExit) { removeMainProcessState(); return; }
    if (billingRecoveryMode || !billingUiReady || !mainWindow || mainWindow.isDestroyed() || mainWindow.webContents.isCrashed()) { allowBillingExit = true; removeMainProcessState(); return; }
    event.preventDefault();""",'Recovery before-quit')
main=once(main,"app.on('query-session-end', () => { allowBillingExit = true; });","app.on('query-session-end', () => { allowBillingExit = true; });\napp.on('will-quit', () => { try { globalShortcut.unregisterAll(); } catch (_) {} });",'Shortcut cleanup')
main=once(main,"appVersion: 'V12.3.8-watchdog'","appVersion: 'V12.3.9-watchdog'",'Watchdog version marker')
oldwd="""    // Main-process watchdog can recover a frozen renderer while a rental timer is active.
    setInterval(() => {
        if (!mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode) return;
        const stale = Date.now() - Number(timerHealth.at || 0) > 12000;
        const stuck = Number(timerHealth.mismatchCount || 0) >= 2;
        if ((stale || stuck) && Date.now() - lastTimerRecoveryAt > 20000) {
            lastTimerRecoveryAt = Date.now();
            try { mainWindow.webContents.reload(); } catch (e) { console.error('Pemulihan timer gagal:', e?.message || e); }
        }
    }, 5000);
    createWindow();"""
newwd="""    // Timer watchdog unlocks Windows before any renderer reload.
    setInterval(() => {
        if (!billingUiReady || billingRecoveryMode || !mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode) return;
        const stale = Date.now() - Number(timerHealth.at || 0) > 12000;
        const stuck = Number(timerHealth.mismatchCount || 0) >= 2;
        if ((stale || stuck) && Date.now() - lastTimerRecoveryAt > 20000) {
            lastTimerRecoveryAt = Date.now();
            scheduleRendererRecovery(mainWindow, stale ? 'Heartbeat timer terhenti' : 'Tampilan timer tidak sinkron', 1800);
        }
    }, 5000);
    if (!globalShortcut.register('Control+Alt+F12', () => emergencyUnlockDesktop('Ctrl+Alt+F12'))) console.error('Hotkey darurat Ctrl+Alt+F12 tidak tersedia.');
    createWindow();"""
main=once(main,oldwd,newwd,'Main watchdog/hotkey')

preload=once(preload,"    setLockMode: (isLocked) => ipcRenderer.send('set-lock-mode', Boolean(isLocked)),","    setLockMode: (isLocked) => ipcRenderer.send('set-lock-mode', Boolean(isLocked)),\n    reportAppReady: (state = {}) => ipcRenderer.send('billing-renderer-ready', { activeSession: state.activeSession === true, activeCode: String(state.activeCode || ''), deadlineMs: Number(state.deadlineMs) || null }),",'Preload readiness bridge')
oldload="""            startAutoBackupWatcher();
        });"""
newload="""            startAutoBackupWatcher();
            const requiredElements = ['lock-screen', 'timer-widget', 'user-code-input'];
            const functionsReady = typeof recoverActiveSession === 'function' && typeof startSession === 'function' && typeof pauseSession === 'function';
            const domReady = requiredElements.every(id => Boolean(document.getElementById(id)));
            if (functionsReady && domReady) window.electronAPI?.reportAppReady?.({ activeSession: Boolean(currentActiveCode), activeCode: currentActiveCode || '', deadlineMs: Number(timerDeadlineMs) || null });
            else console.error('[AniGames V12.3.9] Billing UI gagal pemeriksaan siap; Windows tetap terbuka.');
        });"""
index=once(index,oldload,newload,'Live index renderer ready handshake')
index=once(index,'<span id="app-version-code">V12.3.8-AUTO-WOL-LAN-MAC</span>','<span id="app-version-code">V12.3.9-KIOSK-FAILSAFE</span>','Visible version')
index=once(index,"const APP_VERSION = 'V12.3.8-AUTO-WOL-LAN-MAC';","const APP_VERSION = 'V12.3.9-KIOSK-FAILSAFE';",'Active app version')
renderer=once(renderer,"const APP_VERSION = 'V12.3.8-AUTO-WOL-LAN-MAC';","const APP_VERSION = 'V12.3.9-KIOSK-FAILSAFE';",'Unused renderer version marker')

pkg['version']='12.3.9';pkg['description']='AniGames Billing V12.3.9: main-process kiosk fail-safe, renderer-ready handshake, bounded crash recovery and emergency desktop unlock; preserves WOL, pairing, billing and rental data.'
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3': raise SystemExit('Persistent Electron app identity changed; refusing patch')
if lock is not None:
    if lock.get('version')!='12.3.8': raise SystemExit('package-lock baseline mismatch')
    lock['version']='12.3.9'
    if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.3.9'

vp.write_text('AniGames Billing PC V12.3.9-KIOSK-FAILSAFE — renderer-ready kiosk activation, startup timeout, bounded renderer crash recovery and Ctrl+Alt+F12 desktop unlock. Pairing identity, session persistence, rental data, DB sync and V12.3.8 WOL are preserved.\n',encoding='utf-8')
mp.write_text(main,encoding='utf-8');pp.write_text(preload,encoding='utf-8');ip.write_text(index,encoding='utf-8');rp.write_text(renderer,encoding='utf-8');pkgp.write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
if lock is not None: lockp.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

for t in ["globalShortcut.register('Control+Alt+F12'",'function releaseDesktopLock(',"protectedWindow.webContents.on('did-fail-load'","protectedWindow.webContents.on('render-process-gone'","protectedWindow.webContents.on('unresponsive'","ipcMain.on('billing-renderer-ready'",'Limit recovery tercapai','billingRecoveryMode || !billingUiReady']:
    if t not in main: raise SystemExit('V12.3.9 main assertion missing: '+t)
for t in ['reportAppReady:','billing-renderer-ready']:
    if t not in preload: raise SystemExit('V12.3.9 preload assertion missing: '+t)
for t in ['reportAppReady?.({','functionsReady','domReady',TAG]:
    if t not in index: raise SystemExit('V12.3.9 live renderer assertion missing: '+t)
if pkg.get('version')!='12.3.9' or (lock is not None and lock.get('version')!='12.3.9'): raise SystemExit('V12.3.9 package identity mismatch')
print('PASS: V12.3.9 fail-safe, renderer handshake, bounded reload, emergency unlock and persistent app identity.')
