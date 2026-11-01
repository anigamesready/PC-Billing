from pathlib import Path
import json

R=Path('.')
mp=R/'main.js'; ip=R/'index.html'; rp=R/'renderer.js'; pkgp=R/'package.json'; lockp=R/'package-lock.json'; vp=R/'VERSION.txt'
main=mp.read_text(encoding='utf-8'); index=ip.read_text(encoding='utf-8'); renderer=rp.read_text(encoding='utf-8')
pkg=json.loads(pkgp.read_text(encoding='utf-8')); lock=json.loads(lockp.read_text(encoding='utf-8'))
TAG='V12.4.1-LOCK-STATE-RECOVERY'
if TAG in index and 'rendererHealthySince' in main:
    print('PASS: V12.4.1 lock-state recovery patch already applied')
    raise SystemExit(0)
if pkg.get('version')!='12.4.0' or "APP_VERSION = 'V12.4.0-TIMER-WINDOW-STABILITY'" not in index:
    raise SystemExit('Unexpected baseline: expected V12.4.0 timer-window stability')

def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, found {n}')
    return s.replace(a,b,1)

main=once(main,
"let rendererRecoveryStartedAt = 0, rendererRecoveryAttempts = 0, rendererRecoveryPending = false;",
"let rendererRecoveryStartedAt = 0, rendererRecoveryAttempts = 0, rendererRecoveryPending = false;\nlet rendererHealthySince = 0, recoveryReloadInProgress = false;",
"Recovery state")

old_release="""function releaseDesktopLock(reason='recovery'){
  billingUiReady=false;billingRecoveryMode=true;timerWindowModeActive=false;clearRendererReadyTimeout();
  try{const w=mainWindow;if(w&&!w.isDestroyed()){w.setKiosk(false);w.setFullScreen(false);w.setAlwaysOnTop(false);w.setIgnoreMouseEvents(false);w.setFocusable(true);w.setResizable(true);w.setMinimizable(true);w.setSize(800,520,true);w.center();w.minimize();}}
  catch(e){console.error('Gagal melepas lock desktop:',e?.message||e);}
  writeMainProcessState(false);console.error('[AniGames V12.3.9] Desktop unlocked:',String(reason));
}"""
new_release="""function releaseDesktopLock(reason='recovery'){
  billingUiReady=false;billingRecoveryMode=true;timerWindowModeActive=false;rendererHealthySince=0;clearRendererReadyTimeout();
  try{
    const w=mainWindow;
    if(w&&!w.isDestroyed()){
      w.setKiosk(false);w.setFullScreen(false);w.setAlwaysOnTop(false);w.setIgnoreMouseEvents(false);
      w.setFocusable(true);w.setResizable(true);w.setMinimizable(true);
      const b=w.getBounds();const width=Math.min(960,Math.max(800,b.width||800));const height=Math.min(680,Math.max(520,b.height||520));
      w.setSize(width,height,true);
      if(w.isMinimized())w.restore();
      w.show();w.focus();
    }
  }catch(e){console.error('Gagal melepas lock desktop:',e?.message||e);}
  writeMainProcessState(false);console.error('[AniGames V12.4.1] Desktop unlocked; recovery window remains visible:',String(reason));
}"""
main=once(main,old_release,new_release,'Fail-open recovery window')

old_recovery="""function scheduleRendererRecovery(w,reason='renderer-error',delay=1600){
  if(WATCHDOG_AGENT_MODE||!w||w.isDestroyed()||mainWindow!==w)return;
  const now=Date.now();if(!rendererRecoveryStartedAt||now-rendererRecoveryStartedAt>120000){rendererRecoveryStartedAt=now;rendererRecoveryAttempts=0;}
  releaseDesktopLock(reason);if(rendererRecoveryPending)return;
  if(rendererRecoveryAttempts>=2){console.error('[AniGames V12.3.9] Limit recovery tercapai; Windows tetap terbuka.');return;}
  rendererRecoveryAttempts++;rendererRecoveryPending=true;
  setTimeout(()=>{rendererRecoveryPending=false;if(mainWindow!==w||w.isDestroyed())return;try{if(w.webContents.isCrashed())w.loadFile('index.html').catch(e=>console.error('Reload crash gagal:',e?.message||e));else w.webContents.reload();}catch(e){console.error('Recovery renderer gagal:',e?.message||e);}},Math.max(500,Number(delay)||1600));
}"""
new_recovery="""function scheduleRendererRecovery(w,reason='renderer-error',delay=1600){
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
}"""
main=once(main,old_recovery,new_recovery,'Bounded recovery state machine')

main=once(main,
"""    protectedWindow.webContents.on('did-start-loading', () => {
        if (billingUiReady) releaseDesktopLock('Halaman Billing dimuat ulang');
        armRendererReadyTimeout(protectedWindow);
    });""",
"""    protectedWindow.webContents.on('did-start-loading', () => {
        if (billingUiReady && !recoveryReloadInProgress) releaseDesktopLock('Halaman Billing dimuat ulang');
        armRendererReadyTimeout(protectedWindow);
    });""",
"Prevent duplicate unlock on recovery reload")

main=once(main,
"""ipcMain.on('billing-renderer-ready',(event,payload)=>{
  if(WATCHDOG_AGENT_MODE||event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
  const p=payload&&typeof payload==='object'?payload:{};const active=p.activeSession===true;const code=String(p.activeCode||'').trim().slice(0,128)||null;const deadline=Number(p.deadlineMs);
  clearRendererReadyTimeout();billingUiReady=true;billingRecoveryMode=false;rendererRecoveryAttempts=0;rendererRecoveryStartedAt=0;rendererRecoveryPending=false;
  timerHealth={at:Date.now(),activeCode:active?code:null,deadlineMs:active&&Number.isFinite(deadline)?deadline:null,displaySeconds:null,mismatchCount:0};
  writeMainProcessState(true);if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);
});""",
"""ipcMain.on('billing-renderer-ready',(event,payload)=>{
  if(WATCHDOG_AGENT_MODE||event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
  const p=payload&&typeof payload==='object'?payload:{};const active=p.activeSession===true;const code=String(p.activeCode||'').trim().slice(0,128)||null;const deadline=Number(p.deadlineMs);
  clearRendererReadyTimeout();billingUiReady=true;billingRecoveryMode=false;rendererHealthySince=Date.now();recoveryReloadInProgress=false;rendererRecoveryPending=false;
  timerHealth={at:Date.now(),activeCode:active?code:null,deadlineMs:active&&Number.isFinite(deadline)?deadline:null,displaySeconds:null,mismatchCount:0};
  writeMainProcessState(true);if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);
});""",
"Do not reset recovery budget on readiness")

main=once(main,
"""ipcMain.on('timer-health-pulse', (event, payload) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return;
    const p = payload && typeof payload === 'object' ? payload : {};""",
"""ipcMain.on('timer-health-pulse', (event, payload) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return;
    if (billingUiReady && !billingRecoveryMode && rendererHealthySince && Date.now()-rendererHealthySince>=60000) {
        rendererRecoveryAttempts=0;rendererRecoveryStartedAt=0;rendererHealthySince=Date.now();
    }
    const p = payload && typeof payload === 'object' ? payload : {};""",
"Reset recovery budget only after sustained health")

main=once(main,
"""        if (!billingUiReady || billingRecoveryMode || !mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode) return;""",
"""        if (!billingUiReady || billingRecoveryMode || !mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode || rendererRecoveryPending) return;""",
"Watchdog duplicate-recovery guard")

index=once(index,"const APP_VERSION = 'V12.4.0-TIMER-WINDOW-STABILITY';","const APP_VERSION = 'V12.4.1-LOCK-STATE-RECOVERY';","App version")
index=once(index,'<span id="app-version-code">V12.4.0-TIMER-WINDOW-STABILITY</span>','<span id="app-version-code">V12.4.1-LOCK-STATE-RECOVERY</span>','Visible version')
renderer=renderer.replace("const APP_VERSION = 'V12.4.0-TIMER-WINDOW-STABILITY';","const APP_VERSION = 'V12.4.1-LOCK-STATE-RECOVERY';")

pkg['version']='12.4.1'
pkg['description']='AniGames Billing V12.4.1: fail-open kiosk recovery, visible recovery window, bounded renderer reloads and stable-health recovery budget; preserves V12.4.0 timer position fix.'
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron application identity changed; refusing patch')
if lock.get('version')!='12.4.0': raise SystemExit('package-lock baseline mismatch')
lock['version']='12.4.1'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.1'

vp.write_text(TAG+'\nKiosk is disabled during renderer recovery without minimizing/hiding the Billing window. Recovery budget resets only after 60 seconds of healthy renderer pulses.\n',encoding='utf-8')
mp.write_text(main,encoding='utf-8');ip.write_text(index,encoding='utf-8');rp.write_text(renderer,encoding='utf-8')
pkgp.write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
lockp.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

for token in ('rendererHealthySince','recoveryReloadInProgress','V12.4.1'):
    if token not in main+index: raise SystemExit('Missing V12.4.1 token: '+token)
rel=main[main.index("function releaseDesktopLock"):main.index("function armRendererReadyTimeout")]
if '.minimize()' in rel or '.center()' in rel: raise SystemExit('Fail-open recovery still minimizes or recenters Billing')
ready=main[main.index("ipcMain.on('billing-renderer-ready'"):main.index("ipcMain.on('set-lock-mode'")]
if 'rendererRecoveryAttempts=0' in ready or 'rendererRecoveryStartedAt=0' in ready: raise SystemExit('Recovery budget is still reset on every renderer-ready event')
rec=main[main.index("function scheduleRendererRecovery"):main.index("function emergencyUnlockDesktop")]
if 'rendererRecoveryPending)return' not in rec or 'rendererRecoveryAttempts>=2' not in rec: raise SystemExit('Recovery duplicate/attempt guard missing')
if pkg.get('version')!='12.4.1' or lock.get('version')!='12.4.1': raise SystemExit('V12.4.1 package version mismatch')
print('PASS: V12.4.1 fail-open kiosk recovery, visible non-minimized recovery window, duplicate-reload guard, two-attempt budget, 60-second stable reset, persistent app identity.')
