from pathlib import Path
import json

P=Path('.')
mp=P/'main.js'; ip=P/'index.html'; rp=P/'renderer.js'
pkgp=P/'package.json'; lockp=P/'package-lock.json'; vp=P/'VERSION.txt'
main=mp.read_text(encoding='utf-8')
index=ip.read_text(encoding='utf-8')
renderer=rp.read_text(encoding='utf-8')
pkg=json.loads(pkgp.read_text(encoding='utf-8'))
lock=json.loads(lockp.read_text(encoding='utf-8'))
TAG='V12.4.0-TIMER-WINDOW-STABILITY'
if TAG in index and 'ani-games-timer-window-position.json' in main:
    print('PASS: V12.4.0 timer-window patch already applied')
    raise SystemExit(0)
if pkg.get('version')!='12.3.9' or "APP_VERSION = 'V12.3.9-KIOSK-FAILSAFE'" not in index:
    raise SystemExit('Unexpected baseline: expected V12.3.9 KIOSK FAILSAFE')

def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, found {n}')
    return s.replace(a,b,1)

main=once(main,
"const { app, BrowserWindow, ipcMain, dialog, safeStorage, globalShortcut } = require('electron');",
"const { app, BrowserWindow, ipcMain, dialog, safeStorage, globalShortcut, screen } = require('electron');",
"Electron screen import")
main=once(main,
"let rendererRecoveryStartedAt = 0, rendererRecoveryAttempts = 0, rendererRecoveryPending = false;\nlet mainWindow;",
"""let rendererRecoveryStartedAt = 0, rendererRecoveryAttempts = 0, rendererRecoveryPending = false;
// V12.4.0: persist timer position independently from rental/customer data.
let timerWindowPositionSaveTimer = null;
let applyingTimerWindowGeometry = false;
let timerWindowModeActive = false;
let mainWindow;""",
"Timer state")
main=once(main,
"const BILLING_USER_DATA_DIR = app.getPath('userData');",
"const BILLING_USER_DATA_DIR = app.getPath('userData');\nconst TIMER_WINDOW_POSITION_FILE = path.join(BILLING_USER_DATA_DIR, 'ani-games-timer-window-position.json');",
"Timer position path")

old_helpers="""function clearRendererReadyTimeout(){if(rendererReadyTimeout)clearTimeout(rendererReadyTimeout);rendererReadyTimeout=null;}
function applyLoginKioskMode(w=mainWindow){if(!w||w.isDestroyed())return;w.setKiosk(true);w.setFullScreen(true);w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);if(w.isMinimized())w.restore();w.show();w.focus();}
function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);if(w.isMinimized())w.restore();w.setSize(500,76,true);w.center();w.show();}"""
new_helpers=r'''function clearRendererReadyTimeout(){if(rendererReadyTimeout)clearTimeout(rendererReadyTimeout);rendererReadyTimeout=null;}
function readTimerWindowPosition(){
  try{const p=JSON.parse(fs.readFileSync(TIMER_WINDOW_POSITION_FILE,'utf8'));const x=Number(p?.x),y=Number(p?.y);return Number.isFinite(x)&&Number.isFinite(y)?{x:Math.round(x),y:Math.round(y)}:null;}catch(_){return null;}
}
function clampTimerWindowPosition(position,width=500,height=76){
  const w=Math.max(220,Math.min(520,Math.ceil(Number(width)||500))),h=Math.max(54,Math.min(110,Math.ceil(Number(height)||76)));
  const fallback=screen.getPrimaryDisplay().workArea;
  const x=Number.isFinite(Number(position?.x))?Number(position.x):fallback.x+fallback.width-w-24;
  const y=Number.isFinite(Number(position?.y))?Number(position.y):fallback.y+24;
  let display;try{display=screen.getDisplayNearestPoint({x:Math.round(x+w/2),y:Math.round(y+h/2)});}catch(_){display=screen.getPrimaryDisplay();}
  const a=display?.workArea||fallback;
  return {x:Math.min(Math.max(a.x,a.x+a.width-w),Math.max(a.x,Math.round(x))),y:Math.min(Math.max(a.y,a.y+a.height-h),Math.max(a.y,Math.round(y)))};
}
function persistTimerWindowPositionNow(w=mainWindow){
  if(!w||w.isDestroyed()||!timerWindowModeActive||applyingTimerWindowGeometry)return;
  try{const b=w.getBounds(),p=clampTimerWindowPosition({x:b.x,y:b.y},b.width,b.height);fs.mkdirSync(path.dirname(TIMER_WINDOW_POSITION_FILE),{recursive:true});const tmp=TIMER_WINDOW_POSITION_FILE+'.tmp';fs.writeFileSync(tmp,JSON.stringify({x:p.x,y:p.y,updatedAt:Date.now()}),'utf8');fs.renameSync(tmp,TIMER_WINDOW_POSITION_FILE);}catch(e){console.error('Gagal menyimpan posisi timer:',e?.message||e);}
}
function queuePersistTimerWindowPosition(w=mainWindow){
  if(!w||w.isDestroyed()||!timerWindowModeActive||applyingTimerWindowGeometry)return;
  if(timerWindowPositionSaveTimer)clearTimeout(timerWindowPositionSaveTimer);
  timerWindowPositionSaveTimer=setTimeout(()=>{timerWindowPositionSaveTimer=null;persistTimerWindowPositionNow(w);},240);
}
function applyTimerWindowGeometry(w,width=500,height=76){
  if(!w||w.isDestroyed())return;
  const b=w.getBounds(),saved=readTimerWindowPosition(),p=clampTimerWindowPosition(saved||{x:b.x,y:b.y},width,height);
  const cw=Math.max(220,Math.min(520,Math.ceil(Number(width)||500))),ch=Math.max(54,Math.min(110,Math.ceil(Number(height)||76)));
  const content=w.getContentBounds();applyingTimerWindowGeometry=true;
  try{if(Math.abs(content.width-cw)>1||Math.abs(content.height-ch)>1)w.setContentSize(cw,ch,true);const after=w.getBounds();if(after.x!==p.x||after.y!==p.y)w.setPosition(p.x,p.y,true);const final=w.getBounds(),clamped=clampTimerWindowPosition({x:final.x,y:final.y},cw,ch);if(clamped.x!==final.x||clamped.y!==final.y)w.setPosition(clamped.x,clamped.y,true);}
  catch(e){console.error('Gagal menerapkan ukuran/posisi timer:',e?.message||e);}
  finally{setTimeout(()=>{applyingTimerWindowGeometry=false;if(timerWindowModeActive)persistTimerWindowPositionNow(w);},100);}
}
function clampActiveTimerWindowToDisplay(w=mainWindow){
  if(!w||w.isDestroyed()||!timerWindowModeActive)return;
  const b=w.getBounds(),p=clampTimerWindowPosition({x:b.x,y:b.y},b.width,b.height);
  if(p.x!==b.x||p.y!==b.y){applyingTimerWindowGeometry=true;w.setPosition(p.x,p.y,true);setTimeout(()=>{applyingTimerWindowGeometry=false;persistTimerWindowPositionNow(w);},100);}
}
function applyLoginKioskMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=false;w.setKiosk(true);w.setFullScreen(true);w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);if(w.isMinimized())w.restore();w.show();w.focus();}
function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=true;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);if(w.isMinimized())w.restore();applyTimerWindowGeometry(w,500,76);w.show();}'''
main=once(main,old_helpers,new_helpers,'Timer geometry helpers')

main=once(main,
"    // V12.3.2: keep ordinary close shortcuts/clicks from terminating monitoring.\n    const protectedWindow = mainWindow;",
"""    // V12.4.0: persist native drag/resize geometry for the floating timer.
    const protectedWindow = mainWindow;
    protectedWindow.on('move', () => queuePersistTimerWindowPosition(protectedWindow));
    protectedWindow.on('resize', () => queuePersistTimerWindowPosition(protectedWindow));
    if (!WATCHDOG_AGENT_MODE) {
        screen.on('display-metrics-changed', () => clampActiveTimerWindowToDisplay(protectedWindow));
        screen.on('display-removed', () => clampActiveTimerWindowToDisplay(protectedWindow));
        screen.on('display-added', () => clampActiveTimerWindowToDisplay(protectedWindow));
    }
    // V12.3.2: keep ordinary close shortcuts/clicks from terminating monitoring.""",
"Window move/resize hooks")
main=once(main,
"  billingUiReady=false;billingRecoveryMode=true;clearRendererReadyTimeout();\n  try{const w=mainWindow;",
"  billingUiReady=false;billingRecoveryMode=true;timerWindowModeActive=false;clearRendererReadyTimeout();\n  try{const w=mainWindow;",
"Recovery mode reset")

old_resize="""ipcMain.on('resize-timer-window', (event, width, height) => {
    if (!mainWindow || mainWindow.isDestroyed()) return;

    const safeWidth = Math.max(220, Math.ceil(Number(width) || 0));
    const safeHeight = Math.max(60, Math.ceil(Number(height) || 0));

    try {
        mainWindow.setContentSize(safeWidth, safeHeight, true);
        mainWindow.center();
    } catch (err) {
        console.error("Gagal mengubah ukuran jendela timer:", err);
    }
});"""
new_resize=r'''ipcMain.on('resize-timer-window',(event,width,height)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed()||!billingUiReady||billingRecoveryMode||!timerWindowModeActive)return;
    const cw=Math.max(220,Math.min(520,Math.ceil(Number(width)||0))),ch=Math.max(54,Math.min(110,Math.ceil(Number(height)||0)));
    try{
        const b=mainWindow.getBounds(),content=mainWindow.getContentBounds();
        if(Math.abs(content.width-cw)<=1&&Math.abs(content.height-ch)<=1)return;
        const p=clampTimerWindowPosition({x:b.x,y:b.y},cw,ch);applyingTimerWindowGeometry=true;
        mainWindow.setContentSize(cw,ch,true);
        const after=mainWindow.getBounds();if(after.x!==p.x||after.y!==p.y)mainWindow.setPosition(p.x,p.y,true);
        setTimeout(()=>{applyingTimerWindowGeometry=false;persistTimerWindowPositionNow(mainWindow);},100);
    }catch(e){applyingTimerWindowGeometry=false;console.error('Gagal mengubah ukuran timer:',e?.message||e);}
});'''
main=once(main,old_resize,new_resize,'Position-safe resize IPC')

main=once(main,
"""ipcMain.on('restore-timer-window', () => {
    if (!mainWindow || mainWindow.isDestroyed()) return;
    if (mainWindow.isMinimized()) mainWindow.restore();
    mainWindow.focus();
});""",
"""ipcMain.on('restore-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(mainWindow.isMinimized())mainWindow.restore();
    if(timerWindowModeActive)clampActiveTimerWindowToDisplay(mainWindow);
    mainWindow.show();mainWindow.focus();
});""",
"Timer restore IPC")

index=once(index,"const APP_VERSION = 'V12.3.9-KIOSK-FAILSAFE';","const APP_VERSION = 'V12.4.0-TIMER-WINDOW-STABILITY';","App version")
index=once(index,'<span id="app-version-code">V12.3.9-KIOSK-FAILSAFE</span>','<span id="app-version-code">V12.4.0-TIMER-WINDOW-STABILITY</span>','Visible version')
renderer=renderer.replace("const APP_VERSION = 'V12.3.9-KIOSK-FAILSAFE';","const APP_VERSION = 'V12.4.0-TIMER-WINDOW-STABILITY';")

old_sync="""        function syncTimerWindowSize() {
            const widget = document.getElementById('timer-widget');
            if (!widget || widget.classList.contains('hidden')) return;
            const rect = widget.getBoundingClientRect();
            if (window.electronAPI && window.electronAPI.resizeTimerWindow) {
                window.electronAPI.resizeTimerWindow(Math.ceil(rect.width), Math.ceil(rect.height));
            }
        }"""
new_sync="""        let lastTimerWindowSizeKey = '';
        function syncTimerWindowSize(force = false) {
            const widget = document.getElementById('timer-widget');
            if (!widget || widget.classList.contains('hidden')) return;
            const rect = widget.getBoundingClientRect();
            const width = Math.max(220, Math.ceil(rect.width));
            const height = Math.max(54, Math.ceil(rect.height));
            const key = width + 'x' + height;
            if (!force && key === lastTimerWindowSizeKey) return;
            lastTimerWindowSizeKey = key;
            if (window.electronAPI && window.electronAPI.resizeTimerWindow) {
                window.electronAPI.resizeTimerWindow(width, height);
            }
        }"""
index=once(index,old_sync,new_sync,'Renderer timer size dedupe')
index=index.replace("requestAnimationFrame(() => syncTimerWindowSize());","requestAnimationFrame(() => syncTimerWindowSize(true));")
index=index.replace("setTimeout(syncTimerWindowSize, 120);","setTimeout(() => syncTimerWindowSize(true), 120);")

pkg['version']='12.4.0'
pkg['description']='AniGames Billing V12.4.0: stable timer sizing, persisted window position, display-change clamping, and V12.3.9 kiosk fail-safe.'
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron app identity changed; refusing patch')
if lock.get('version')!='12.3.9': raise SystemExit('package-lock baseline mismatch')
lock['version']='12.4.0'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.0'

vp.write_text(TAG+'\nTimer position is persisted; resize keeps its position; display changes clamp it to the visible work area.\n',encoding='utf-8')
mp.write_text(main,encoding='utf-8');ip.write_text(index,encoding='utf-8');rp.write_text(renderer,encoding='utf-8')
pkgp.write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
lockp.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')

for token in ('screen.getDisplayNearestPoint(','ani-games-timer-window-position.json',"protectedWindow.on('move'", "ipcMain.on('resize-timer-window'"):
    if token not in main: raise SystemExit('V12.4.0 main token missing: '+token)
rs=main[main.index("ipcMain.on('resize-timer-window'"):main.index("ipcMain.on('minimize-timer-window'",main.index("ipcMain.on('resize-timer-window'"))]
as_=main[main.index('function applyActiveTimerWindowMode'):main.index('function releaseDesktopLock',main.index('function applyActiveTimerWindowMode'))]
if '.center()' in rs or '.center()' in as_: raise SystemExit('Active resize path still recenters')
if 'lastTimerWindowSizeKey' not in index or TAG not in index: raise SystemExit('Renderer version/size regression token missing')
if pkg.get('version')!='12.4.0' or lock.get('version')!='12.4.0': raise SystemExit('V12.4.0 package version mismatch')
print('PASS: V12.4.0 persisted timer position, no recenter on resize/session activation, display clamping, renderer size dedupe, and stable app identity.')
