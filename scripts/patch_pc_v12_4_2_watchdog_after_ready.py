from pathlib import Path
import json

R=Path('.')
mp=R/'main.js'; ip=R/'index.html'; rp=R/'renderer.js'
pkgp=R/'package.json'; lockp=R/'package-lock.json'; vp=R/'VERSION.txt'
main=mp.read_text(encoding='utf-8'); index=ip.read_text(encoding='utf-8'); renderer=rp.read_text(encoding='utf-8')
pkg=json.loads(pkgp.read_text(encoding='utf-8')); lock=json.loads(lockp.read_text(encoding='utf-8'))
TAG='V12.4.2-WATCHDOG-AFTER-READY'
if TAG in index and 'startBillingWatchdogsAfterReady' in main:
    print('PASS: V12.4.2 watchdog-after-ready patch already applied')
    raise SystemExit(0)
if pkg.get('version')!='12.4.1' or "APP_VERSION = 'V12.4.1-LOCK-STATE-RECOVERY'" not in index:
    raise SystemExit('Unexpected baseline: expected V12.4.1 lock-state recovery')

def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, found {n}')
    return s.replace(a,b,1)

main=once(main,
"let rendererHealthySince = 0, recoveryReloadInProgress = false;",
"let rendererHealthySince = 0, recoveryReloadInProgress = false;\nlet billingWatchdogsStarted = false, billingTimerWatchdog = null;",
"Watchdog start state")

watchdog_start_helper=r'''function startBillingWatchdogsAfterReady(){
    if(WATCHDOG_AGENT_MODE||!billingUiReady||billingRecoveryMode||billingWatchdogsStarted)return;
    billingWatchdogsStarted=true;
    // The detached process is started only after the live Billing renderer reports READY.
    launchWatchdogAgent();
    // The in-process timer watchdog also starts after READY; it remains the only
    // component allowed to reload the Billing renderer while the main Electron process is alive.
    if(!billingTimerWatchdog){
        billingTimerWatchdog=setInterval(()=>{
            if(!billingUiReady||billingRecoveryMode||!mainWindow||mainWindow.isDestroyed()||!timerHealth.activeCode||rendererRecoveryPending)return;
            const stale=Date.now()-Number(timerHealth.at||0)>12000;
            const stuck=Number(timerHealth.mismatchCount||0)>=2;
            if((stale||stuck)&&Date.now()-lastTimerRecoveryAt>20000){
                lastTimerRecoveryAt=Date.now();
                scheduleRendererRecovery(mainWindow,stale?'Heartbeat timer terhenti':'Tampilan timer tidak sinkron',1800);
            }
        },5000);
    }
}
'''
main=once(main,"app.whenReady().then(() => {",watchdog_start_helper+"\napp.whenReady().then(() => {","Watchdog start helper insertion")

oldboot="""app.whenReady().then(() => {
    if (DUPLICATE_BILLING_PROCESS) { app.quit(); return; }
    if (WATCHDOG_AGENT_MODE) { runWatchdogAgent(); return; }
    writeMainProcessState(false);
    launchWatchdogAgent();
    // Timer watchdog unlocks Windows before any renderer reload.
    setInterval(() => {
        if (!billingUiReady || billingRecoveryMode || !mainWindow || mainWindow.isDestroyed() || !timerHealth.activeCode || rendererRecoveryPending) return;
        const stale = Date.now() - Number(timerHealth.at || 0) > 12000;
        const stuck = Number(timerHealth.mismatchCount || 0) >= 2;
        if ((stale || stuck) && Date.now() - lastTimerRecoveryAt > 20000) {
            lastTimerRecoveryAt = Date.now();
            scheduleRendererRecovery(mainWindow, stale ? 'Heartbeat timer terhenti' : 'Tampilan timer tidak sinkron', 1800);
        }
    }, 5000);
    if (!globalShortcut.register('Control+Alt+F12', () => emergencyUnlockDesktop('Ctrl+Alt+F12'))) console.error('Hotkey darurat Ctrl+Alt+F12 tidak tersedia.');
    createWindow();
});"""
newboot="""app.whenReady().then(() => {
    if (DUPLICATE_BILLING_PROCESS) { app.quit(); return; }
    if (WATCHDOG_AGENT_MODE) { runWatchdogAgent(); return; }
    writeMainProcessState(false);
    // Emergency unlock is available during startup; watchdogs are deliberately not started here.
    if (!globalShortcut.register('Control+Alt+F12', () => emergencyUnlockDesktop('Ctrl+Alt+F12'))) console.error('Hotkey darurat Ctrl+Alt+F12 tidak tersedia.');
    createWindow();
});"""
main=once(main,oldboot,newboot,'Deferred watchdog boot')

oldready="""  writeMainProcessState(true);if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);
});"""
newready="""  writeMainProcessState(true);
  startBillingWatchdogsAfterReady();
  if(active)applyActiveTimerWindowMode(mainWindow);else applyLoginKioskMode(mainWindow);
});"""
main=once(main,oldready,newready,'Start watchdog after renderer READY')

index=once(index,"const APP_VERSION = 'V12.4.1-LOCK-STATE-RECOVERY';","const APP_VERSION = 'V12.4.2-WATCHDOG-AFTER-READY';","App version")
index=once(index,'<span id="app-version-code">V12.4.1-LOCK-STATE-RECOVERY</span>','<span id="app-version-code">V12.4.2-WATCHDOG-AFTER-READY</span>','Visible version')
renderer=renderer.replace("const APP_VERSION = 'V12.4.1-LOCK-STATE-RECOVERY';","const APP_VERSION = 'V12.4.2-WATCHDOG-AFTER-READY';")

pkg['version']='12.4.2'
pkg['description']='AniGames Billing V12.4.2: start local and detached watchdogs only after live Billing renderer READY; preserves V12.4.1 fail-open recovery and V12.4.0 timer window stability.'
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron application identity changed; refusing patch')
if lock.get('version')!='12.4.1': raise SystemExit('package-lock baseline mismatch')
lock['version']='12.4.2'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.2'

vp.write_text(TAG+'\nBoth watchdogs are activated exactly once after the live Billing renderer READY handshake. Startup remains non-kiosk and emergency unlock remains available before READY.\n',encoding='utf-8')
mp.write_text(main,encoding='utf-8');ip.write_text(index,encoding='utf-8');rp.write_text(renderer,encoding='utf-8')
pkgp.write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
lockp.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

boot=main[main.index("app.whenReady().then(() => {"):main.index("});",main.index("app.whenReady().then(() => {"))+3]
if 'launchWatchdogAgent()' in boot or 'billingTimerWatchdog=setInterval' in boot:
    raise SystemExit('Watchdog still starts before Billing UI READY')
if "globalShortcut.register('Control+Alt+F12'" not in boot or 'createWindow();' not in boot:
    raise SystemExit('Startup emergency shortcut or createWindow missing')
helper=main[main.index('function startBillingWatchdogsAfterReady'):main.index("app.whenReady().then(() => {",main.index('function startBillingWatchdogsAfterReady'))]
if 'launchWatchdogAgent();' not in helper or 'billingTimerWatchdog=setInterval' not in helper:
    raise SystemExit('Watchdogs are not armed by post-ready helper')
ready=main[main.index("ipcMain.on('billing-renderer-ready'"):main.index("ipcMain.on('set-lock-mode'",main.index("ipcMain.on('billing-renderer-ready'"))]
if 'startBillingWatchdogsAfterReady();' not in ready or 'writeMainProcessState(true)' not in ready:
    raise SystemExit('Renderer READY handler does not arm watchdog after publishing ready state')
if pkg.get('version')!='12.4.2' or lock.get('version')!='12.4.2': raise SystemExit('V12.4.2 package version mismatch')
print('PASS: V12.4.2 watchdogs start once after renderer READY; startup has no watchdog launch/interval; emergency unlock and app creation remain available.')
