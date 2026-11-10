from pathlib import Path
import json

R=Path('.')
N=('main.js','index.html','renderer.js','package.json','package-lock.json','VERSION.txt')
P={n:R/n for n in N}
for p in P.values():
    if not p.is_file(): raise SystemExit('V12.4.6 source missing: '+str(p))
m=P['main.js'].read_text(encoding='utf-8')
h=P['index.html'].read_text(encoding='utf-8')
r=P['renderer.js'].read_text(encoding='utf-8')
pkg=json.loads(P['package.json'].read_text(encoding='utf-8'))
lock=json.loads(P['package-lock.json'].read_text(encoding='utf-8'))
OLD='V12.4.6-RESPONSIVE-DISPLAY-FIT'; NEW='V12.4.7-FULLSCREEN-NONINTERFERENCE'
if NEW in h and 'BILLING_FULLSCREEN_NONINTERFERENCE' in m:
    print('PASS: V12.4.7 already applied'); raise SystemExit(0)
if pkg.get('version')!='12.4.6' or lock.get('version')!='12.4.6' or OLD not in h:
    raise SystemExit('Expected exact V12.4.6 source baseline.')
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron app identity changed.')
def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, found {n}')
    return s.replace(a,b,1)

m=once(m,
'''let billingDisplayHooksRegistered = false;
let billingDisplaySyncInProgress = false;
let mainWindow;''',
'''let billingDisplayHooksRegistered = false;
let billingDisplaySyncInProgress = false;
// BILLING_FULLSCREEN_NONINTERFERENCE
let billingInitialLoadFinished = false, billingInitialReadyCompleted = false;
let billingLoginKioskPending = false, pendingTimerWindowGeometrySync = false;
let deferredRendererRecovery = null;
let mainWindow;''','Foreground state')

m=once(m,
'''            if (mainWindow.isMinimized()) mainWindow.restore();
            if (billingRecoveryMode) { mainWindow.show(); mainWindow.focus(); mainWindow.webContents.reload(); return; }
            mainWindow.show();
            mainWindow.focus();''',
'''            if (!mainWindow.isFocused()) {
                console.info('[AniGames V12.4.7] Duplicate launch ignored while another app owns foreground.');
                return;
            }
            if (mainWindow.isMinimized()) mainWindow.restore();
            if (billingRecoveryMode) { mainWindow.show(); mainWindow.focus(); mainWindow.webContents.reload(); return; }
            mainWindow.show();
            mainWindow.focus();''','Second launch focus gate')

m=once(m,'show: false, alwaysOnTop: true, skipTaskbar: false,',
       'show: false, alwaysOnTop: false, skipTaskbar: false,','Admin message not topmost')
m=once(m,
'''        popup.setAlwaysOnTop(true, 'floating');
        popup.show();
        popup.focus();''',
'''        popup.setAlwaysOnTop(false);
        if(typeof popup.showInactive==='function')popup.showInactive();else popup.show();''',
'Admin message non-activating')

old='''function applyLoginKioskMode(w=mainWindow,targetDisplay=null,reveal=true){
  if(!w||w.isDestroyed())return;
  timerWindowModeActive=false;const wasVisible=w.isVisible(),wasMinimized=w.isMinimized();
  try{
    let d=targetDisplay;if(!d)d=screen.getDisplayMatching(w.getBounds());d=d||screen.getPrimaryDisplay();
    const b=d.bounds,current=w.getBounds();
    if(w.isFullScreen())w.setFullScreen(false);if(w.isKiosk())w.setKiosk(false);
    if(current.x!==b.x||current.y!==b.y||current.width!==b.width||current.height!==b.height)w.setBounds({x:b.x,y:b.y,width:b.width,height:b.height});
    w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);
    w.setKiosk(true);w.setFullScreen(true);w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);
    // Screen changes must not undo a deliberate Admin Logout.
    if(!reveal&&!wasVisible)w.hide();
    if(reveal||wasVisible){if(wasMinimized)w.restore();w.show();if(reveal)w.focus();}
    try{if(w.webContents&&!w.webContents.isDestroyed())w.webContents.send('billing-display-metrics-changed',{displayId:d.id,width:b.width,height:b.height,scaleFactor:d.scaleFactor||1,workArea:d.workArea||b});}catch(_){}
  }catch(e){console.error('Gagal menyesuaikan Billing ke layar client:',e?.message||e);}
}'''
neo='''function applyLoginKioskMode(w=mainWindow,targetDisplay=null,reveal=true){
  if(!w||w.isDestroyed())return;
  const visible=w.isVisible(),minimized=w.isMinimized();
  const mayActivate=Boolean(reveal||(typeof w.isFocused==='function'&&w.isFocused()));
  if(!mayActivate){
    billingLoginKioskPending=true;timerWindowModeActive=false;
    try{w.setKiosk(false);w.setFullScreen(false);w.setAlwaysOnTop(false);w.setIgnoreMouseEvents(false);}catch(e){console.error('Login deferred:',e?.message||e);}
    if(visible&&!minimized){if(typeof w.showInactive==='function')w.showInactive();else w.show();}
    return;
  }
  billingLoginKioskPending=false;timerWindowModeActive=false;
  try{
    let d=targetDisplay;if(!d)d=screen.getDisplayMatching(w.getBounds());d=d||screen.getPrimaryDisplay();
    const b=d.bounds,current=w.getBounds();
    if(w.isFullScreen())w.setFullScreen(false);if(w.isKiosk())w.setKiosk(false);
    if(current.x!==b.x||current.y!==b.y||current.width!==b.width||current.height!==b.height)w.setBounds({x:b.x,y:b.y,width:b.width,height:b.height});
    w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);
    w.setKiosk(true);w.setFullScreen(true);w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);
    if(!reveal&&!visible)w.hide();
    else if(reveal){if(minimized)w.restore();w.show();w.focus();}
    else if(visible){if(minimized)w.restore();if(typeof w.showInactive==='function')w.showInactive();else w.show();}
    try{if(w.webContents&&!w.webContents.isDestroyed())w.webContents.send('billing-display-metrics-changed',{displayId:d.id,width:b.width,height:b.height,scaleFactor:d.scaleFactor||1,workArea:d.workArea||b});}catch(_){}
  }catch(e){console.error('Gagal menyesuaikan Login Billing:',e?.message||e);}
}'''
m=once(m,old,neo,'Login mode foreground guard')

old="function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=true;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);if(w.isMinimized())w.restore();applyTimerWindowGeometry(w,500,76);w.show();}"
neo='''function applyActiveTimerWindowMode(w=mainWindow){
  if(!w||w.isDestroyed())return;
  timerWindowModeActive=true;billingLoginKioskPending=false;
  try{
    w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);
    // The active rental timer must never sit above a DirectX/OpenGL fullscreen game.
    w.setAlwaysOnTop(false);w.setFocusable(true);w.setResizable(false);w.setMinimizable(false);
    if(w.isFocused()){applyTimerWindowGeometry(w,500,76);pendingTimerWindowGeometrySync=false;}
    else pendingTimerWindowGeometrySync=true;
    if(typeof w.showInactive==='function')w.showInactive();else w.show();
  }catch(e){console.error('Gagal mengaktifkan timer background:',e?.message||e);}
}'''
m=once(m,old,neo,'Active timer non-topmost')

m=once(m,
'''    if(timerWindowModeActive){const c=w.getContentBounds();applyTimerWindowGeometry(w,c.width||500,c.height||76,d);}
    else if(billingRecoveryMode)fitRecoveryWindowToDisplay(w,d);
    else if(billingUiReady)applyLoginKioskMode(w,d,false);''',
'''    if(timerWindowModeActive){
      if(!w.isFocused()){pendingTimerWindowGeometrySync=true;return;}
      const c=w.getContentBounds();applyTimerWindowGeometry(w,c.width||500,c.height||76,d);pendingTimerWindowGeometrySync=false;
    }else if(billingRecoveryMode){if(w.isFocused())fitRecoveryWindowToDisplay(w,d);}
    else if(billingUiReady){if(w.isFocused())applyLoginKioskMode(w,d,false);else billingLoginKioskPending=true;}''',
'Display metrics foreground gate')

old='''function releaseDesktopLock(reason='recovery'){
  billingUiReady=false;billingRecoveryMode=true;timerWindowModeActive=false;rendererHealthySince=0;clearRendererReadyTimeout();
  try{
    const w=mainWindow;
    if(w&&!w.isDestroyed()){
      w.setKiosk(false);w.setFullScreen(false);w.setAlwaysOnTop(false);w.setIgnoreMouseEvents(false);
      w.setFocusable(true);w.setResizable(true);w.setMinimizable(true);fitRecoveryWindowToDisplay(w);
      if(w.isMinimized())w.restore();w.show();w.focus();
    }
  }catch(e){console.error('Gagal melepas lock desktop:',e?.message||e);}
  writeMainProcessState(false);console.error('[AniGames V12.4.6] Desktop unlocked; recovery window fitted to client display:',String(reason));
}'''
neo='''function releaseDesktopLock(reason='recovery'){
  const w=mainWindow,focused=Boolean(w&&!w.isDestroyed()&&w.isFocused()),visible=Boolean(w&&!w.isDestroyed()&&w.isVisible()),minimized=Boolean(w&&!w.isDestroyed()&&w.isMinimized());
  billingUiReady=false;billingRecoveryMode=true;timerWindowModeActive=false;rendererHealthySince=0;clearRendererReadyTimeout();
  try{
    if(w&&!w.isDestroyed()){
      w.setKiosk(false);w.setFullScreen(false);w.setAlwaysOnTop(false);w.setIgnoreMouseEvents(false);
      w.setFocusable(true);w.setResizable(true);w.setMinimizable(true);
      if(focused){fitRecoveryWindowToDisplay(w);if(typeof w.showInactive==='function')w.showInactive();else w.show();}
      else if(visible&&!minimized){if(typeof w.showInactive==='function')w.showInactive();else w.show();}
      // Preserve hidden/minimized state. Never restore/focus over a game.
    }
  }catch(e){console.error('Gagal melepas lock desktop:',e?.message||e);}
  writeMainProcessState(false);console.error('[AniGames V12.4.7] Recovery keeps foreground ownership:',String(reason));
}'''
m=once(m,old,neo,'Non-activating recovery release')

old='''function scheduleRendererRecovery(w,reason='renderer-error',delay=1600){
  if(WATCHDOG_AGENT_MODE||!w||w.isDestroyed()||mainWindow!==w||rendererRecoveryPending)return;
  const now=Date.now();
  if(!rendererRecoveryStartedAt||now-rendererRecoveryStartedAt>300000){rendererRecoveryStartedAt=now;rendererRecoveryAttempts=0;}
  releaseDesktopLock(reason);
  if(rendererRecoveryAttempts>=2){
    console.error('[AniGames V12.4.1] Recovery limit reached; kiosk stays disabled and the normal recovery window remains visible.');
    return;
  }
  rendererRecoveryAttempts++;rendererRecoveryPending=true;recoveryReloadInProgress=true;
  setTimeout(()=>{
    rendererRecoveryPending=false;
    if(mainWindow!==w||w.isDestroyed())return;
    try{
      if(w.webContents.isCrashed())w.loadFile('index.html').catch(e=>console.error('Reload crash gagal:',e?.message||e));
      else w.webContents.reload();
    }catch(e){recoveryReloadInProgress=false;console.error('Recovery renderer gagal:',e?.message||e);}
  },Math.max(500,Number(delay)||1600));
}'''
neo='''function scheduleRendererRecovery(w,reason='renderer-error',delay=1600){
  if(WATCHDOG_AGENT_MODE||!w||w.isDestroyed()||mainWindow!==w||rendererRecoveryPending)return;
  if(!w.isFocused()){
    deferredRendererRecovery={reason:String(reason||'renderer-error'),delay:Math.max(500,Number(delay)||1600),at:Date.now()};
    console.warn('[AniGames V12.4.7] Renderer recovery deferred; another application owns foreground.');
    return;
  }
  deferredRendererRecovery=null;
  const now=Date.now();
  if(!rendererRecoveryStartedAt||now-rendererRecoveryStartedAt>300000){rendererRecoveryStartedAt=now;rendererRecoveryAttempts=0;}
  releaseDesktopLock(reason);
  if(rendererRecoveryAttempts>=2){
    console.error('[AniGames V12.4.7] Recovery limit reached without taking foreground.');
    return;
  }
  rendererRecoveryAttempts++;rendererRecoveryPending=true;recoveryReloadInProgress=true;
  setTimeout(()=>{
    rendererRecoveryPending=false;
    if(mainWindow!==w||w.isDestroyed())return;
    try{
      if(w.webContents.isCrashed())w.loadFile('index.html').catch(e=>console.error('Reload crash gagal:',e?.message||e));
      else w.webContents.reload();
    }catch(e){recoveryReloadInProgress=false;console.error('Recovery renderer gagal:',e?.message||e);}
  },Math.max(500,Number(delay)||1600));
}'''
m=once(m,old,neo,'Deferred background renderer recovery')

anchor='''    const protectedWindow = mainWindow;
    protectedWindow.on('move', () => queuePersistTimerWindowPosition(protectedWindow));'''
insert='''    const protectedWindow = mainWindow;
    protectedWindow.on('blur',()=>{if(timerWindowModeActive){try{protectedWindow.setAlwaysOnTop(false);}catch(_){}}});
    protectedWindow.on('focus',()=>{
        if(WATCHDOG_AGENT_MODE||!protectedWindow||protectedWindow.isDestroyed())return;
        if(deferredRendererRecovery&&!rendererRecoveryPending){
            const pending=deferredRendererRecovery;deferredRendererRecovery=null;
            scheduleRendererRecovery(protectedWindow,pending.reason,pending.delay);return;
        }
        if(pendingTimerWindowGeometrySync&&timerWindowModeActive){
            const c=protectedWindow.getContentBounds();applyTimerWindowGeometry(protectedWindow,c.width||500,c.height||76);pendingTimerWindowGeometrySync=false;
        }
        if(billingLoginKioskPending&&billingUiReady&&!billingRecoveryMode&&!timerWindowModeActive)applyLoginKioskMode(protectedWindow,null,false);
        if(billingUiReady&&!billingRecoveryMode&&timerHealth.activeCode&&!rendererRecoveryPending){
            const stale=Date.now()-Number(timerHealth.at||0)>12000,stuck=Number(timerHealth.mismatchCount||0)>=2;
            if((stale||stuck)&&Date.now()-lastTimerRecoveryAt>20000){lastTimerRecoveryAt=Date.now();scheduleRendererRecovery(protectedWindow,stale?'Timer heartbeat tertunda saat game berjalan':'Timer display mismatch setelah kembali ke Billing',700);}
        }
    });
    protectedWindow.on('move', () => queuePersistTimerWindowPosition(protectedWindow));'''
m=once(m,anchor,insert,'Return-to-Billing focus handler')

m=once(m,
'''        try {
            if (protectedWindow.isMinimized()) protectedWindow.restore();
            protectedWindow.show();
            protectedWindow.focus();
        } catch (err) {
            console.error('Gagal memulihkan window Billing setelah percobaan close:', err);
        }''',
'''        try {
            if(protectedWindow.isFocused())protectedWindow.show();
            else if(typeof protectedWindow.showInactive==='function')protectedWindow.showInactive();
            else protectedWindow.show();
        } catch (err) {
            console.error('Gagal mempertahankan Billing setelah percobaan close:', err);
        }''','Close guard non-activating')

m=once(m,
'''    mainWindow.webContents.on('did-finish-load', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.setFocusable(true);
            if (!billingUiReady) { mainWindow.show(); mainWindow.focus(); }
            if (closePromptPending && closePromptInProgress) { closePromptPending = false; mainWindow.webContents.send('billing-close-attempt'); }
        }
    });''',
'''    mainWindow.webContents.on('did-finish-load', () => {
        if (mainWindow && !mainWindow.isDestroyed()) {
            mainWindow.setFocusable(true);
            // Only first document load may activate Billing; automatic reloads stay behind games.
            if(!billingInitialLoadFinished){billingInitialLoadFinished=true;if(!billingUiReady){mainWindow.show();mainWindow.focus();}}
            if (closePromptPending && closePromptInProgress) { closePromptPending = false; mainWindow.webContents.send('billing-close-attempt'); }
        }
    });''','Initial-only load activation')

m=once(m,
'''  if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);
});''',
'''  const firstReady=!billingInitialReadyCompleted;billingInitialReadyCompleted=true;
  if(active)applyActiveTimerWindowMode(mainWindow);
  else applyLoginKioskMode(mainWindow,null,firstReady||mainWindow.isFocused());
});''','Focus-preserving renderer READY')

m=once(m,
'''ipcMain.on('resize-timer-window',(event,width,height)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed()||!billingUiReady||billingRecoveryMode||!timerWindowModeActive)return;
    try{''',
'''ipcMain.on('resize-timer-window',(event,width,height)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed()||!billingUiReady||billingRecoveryMode||!timerWindowModeActive)return;
    if(!mainWindow.isFocused()){pendingTimerWindowGeometrySync=true;return;}
    try{''','Timer geometry foreground gate')

m=once(m,
'''ipcMain.on('minimize-timer-window', () => {
    // Tombol '-' di UI sekarang hanya mengubah timer menjadi popup compact.
    // Tidak lagi meminimalkan jendela Electron ke taskbar.
    if (!mainWindow || mainWindow.isDestroyed()) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
});''',
'''ipcMain.on('minimize-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(!mainWindow.isFocused())pendingTimerWindowGeometrySync=true;
});''','Compact timer no native restore')

m=once(m,
'''ipcMain.on('restore-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(mainWindow.isMinimized())mainWindow.restore();
    if(timerWindowModeActive)clampActiveTimerWindowToDisplay(mainWindow);
    mainWindow.show();mainWindow.focus();
});''',
'''ipcMain.on('restore-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(timerWindowModeActive&&!mainWindow.isFocused()){pendingTimerWindowGeometrySync=true;return;}
    if(timerWindowModeActive)clampActiveTimerWindowToDisplay(mainWindow);
    if(typeof mainWindow.showInactive==='function')mainWindow.showInactive();else mainWindow.show();
});''','Timer restore non-activating')

m=once(m,
'''    try { if (mainWindow && !mainWindow.isDestroyed()) { mainWindow.show(); mainWindow.focus(); } } catch (_) {}''',
'''    try { if (mainWindow && !mainWindow.isDestroyed()) { if(mainWindow.isFocused())mainWindow.show();else if(typeof mainWindow.showInactive==='function')mainWindow.showInactive();else mainWindow.show(); } } catch (_) {}''',
'Close-cancel no focus steal')

m=once(m,
'''        else {
            if (mainWindow.isMinimized()) mainWindow.restore();
            mainWindow.show();
            mainWindow.focus();
        }''',
'''        else {
            if(mainWindow.isFocused())mainWindow.show();
            else if(typeof mainWindow.showInactive==='function')mainWindow.showInactive();
            else mainWindow.show();
        }''','Before-quit no focus steal')

m=once(m,
'''        billingTimerWatchdog=setInterval(()=>{
            if(!billingUiReady||billingRecoveryMode||!mainWindow||mainWindow.isDestroyed()||!timerHealth.activeCode||rendererRecoveryPending)return;
            const stale=Date.now()-Number(timerHealth.at||0)>12000;
            const stuck=Number(timerHealth.mismatchCount||0)>=2;
            if((stale||stuck)&&Date.now()-lastTimerRecoveryAt>20000){''',
'''        billingTimerWatchdog=setInterval(()=>{
            if(!billingUiReady||billingRecoveryMode||!mainWindow||mainWindow.isDestroyed()||!timerHealth.activeCode||rendererRecoveryPending)return;
            const stale=Date.now()-Number(timerHealth.at||0)>12000;
            const stuck=Number(timerHealth.mismatchCount||0)>=2;
            const billingHasForegroundFocus=typeof mainWindow.isFocused==='function'&&mainWindow.isFocused();
            if((stale||stuck)&&!billingHasForegroundFocus)return;
            if((stale||stuck)&&billingHasForegroundFocus&&Date.now()-lastTimerRecoveryAt>20000){''','Timer watchdog foreground-only')

if html.count(OLD)<2: raise SystemExit('Expected V12.4.6 visible/runtime version markers.')
html=html.replace(OLD,NEW)
renderer=renderer.replace("const APP_VERSION = 'V12.4.2-WATCHDOG-AFTER-READY';","const APP_VERSION = 'V12.4.7-FULLSCREEN-NONINTERFERENCE';")
pkg['version']='12.4.7';pkg['description']='AniGames Billing V12.4.7: fullscreen-safe non-topmost timer, non-activating renderer recovery and foreground-preserving display synchronization.'
lock['version']='12.4.7'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.7'

# Fail-closed checks.
a=m.index('function applyActiveTimerWindowMode');b=m.index('function handleBillingDisplayLayoutChange',a);active=m[a:b]
if 'setAlwaysOnTop(false)' not in active or 'showInactive' not in active or 'setAlwaysOnTop(true' in active or '.focus()' in active or '.restore()' in active: raise SystemExit('Active timer still overlays/activates apps.')
a=m.index('function releaseDesktopLock');b=m.index('function armRendererReadyTimeout',a);release=m[a:b]
if '.focus()' in release or '.restore()' in release or 'showInactive' not in release: raise SystemExit('Recovery still focuses/restores Billing.')
a=m.index('function scheduleRendererRecovery');b=m.index('function emergencyUnlockDesktop',a);recovery=m[a:b]
if 'deferredRendererRecovery=' not in recovery or '!w.isFocused()' not in recovery: raise SystemExit('Renderer recovery not deferred in background.')
a=m.index('function startBillingWatchdogsAfterReady');b=m.index('// ANI_GAMES_V12_4_3_CANCEL_PENDING_WINDOWS_SHUTDOWN',a);watch=m[a:b]
if 'billingHasForegroundFocus' not in watch or 'if((stale||stuck)&&!billingHasForegroundFocus)return;' not in watch: raise SystemExit('Watchdog foreground guard missing.')
if "popup.setAlwaysOnTop(true, 'floating')" in m or 'popup.focus();' in m: raise SystemExit('Admin popup remains focus-stealing.')
if "w.setAlwaysOnTop(true,'floating')" in m: raise SystemExit('Legacy floating always-on-top mode remains.')
if pkg.get('version')!='12.4.7' or lock.get('version')!='12.4.7': raise SystemExit('Package version mismatch.')
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3': raise SystemExit('Persistent app identity changed.')

P['main.js'].write_text(m,encoding='utf-8');P['index.html'].write_text(html,encoding='utf-8');P['renderer.js'].write_text(renderer,encoding='utf-8')
P['package.json'].write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
P['package-lock.json'].write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
P['VERSION.txt'].write_text(NEW+'\nActive timer Billing is non-topmost and non-activating. Geometry changes and renderer recovery defer while another application owns foreground focus. Only initial launch or an intentional return to Billing may activate Login.\n',encoding='utf-8')
(R/'FULLSCREEN-NONINTERFERENCE-V12.4.7-AUDIT.md').write_text('''# Ani Games Ready PC V12.4.7 — Fullscreen Non-Interference Audit

## Root cause found in V12.4.6
- The active rental timer BrowserWindow used Always on Top at the floating level and could cover DirectX/OpenGL fullscreen or borderless games.
- Renderer recovery restored, showed and focused Billing. The did-finish-load handler also activated Billing after every renderer reload, not only first launch.
- render-process-gone, did-fail-load, unresponsive and timer-health watchdog could initiate recovery while a game was foreground.
- Display-mode changes could resize/reposition Billing during a game resolution change.

## V12.4.7 changes
- Active timer mode disables Always on Top and uses showInactive; no native restore/focus is issued.
- Timer geometry updates are deferred while Billing is not foreground.
- Login kiosk restoration after automatic reload/display callbacks is deferred until Billing is foreground; first launch remains unchanged.
- Renderer recovery preserves foreground ownership. Recovery and timer-health reloads are deferred while a different app owns foreground.
- Only the first document load may activate Billing; later renderer reloads cannot bring Billing above a game.
- Admin message popup is no longer topmost/focused.
- App identity, userData, pairing, rental/session storage, shared rental DB, cloud heartbeat, offline queue, WOL, Admin controls and shutdown policy are preserved.

## Validation boundary
CI validates source/runtime syntax, focus-safety assertions, existing rental/pairing/WOL/Admin regressions, and Windows EXE packaging. Live FiveM/StarDesk fullscreen testing remains required on the rental PC.
''',encoding='utf-8')
print('PASS: V12.4.7 fullscreen non-interference; active timer not topmost; background recovery/resize non-activating; app identity preserved.')
