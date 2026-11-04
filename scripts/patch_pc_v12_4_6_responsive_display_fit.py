from pathlib import Path
import json

R=Path('.')
mainp,htmlp,renderp,pkgp,lockp,verp=[R/x for x in ('main.js','index.html','renderer.js','package.json','package-lock.json','VERSION.txt')]
for p in (mainp,htmlp,renderp,pkgp,lockp,verp):
    if not p.is_file(): raise SystemExit('Required V12.4.5 source missing: '+str(p))
main,html,renderer=mainp.read_text(encoding='utf-8'),htmlp.read_text(encoding='utf-8'),renderp.read_text(encoding='utf-8')
pkg,lock=json.loads(pkgp.read_text()),json.loads(lockp.read_text())
OLD,NEW='V12.4.5-ADMIN-LOGOUT-RESPONSIVE-LOGIN','V12.4.6-RESPONSIVE-DISPLAY-FIT'
if NEW in html and 'function handleBillingDisplayLayoutChange' in main:
    print('PASS: V12.4.6 already applied'); raise SystemExit(0)
if pkg.get('version')!='12.4.5' or lock.get('version')!='12.4.5' or OLD not in html:
    raise SystemExit('Expected exact V12.4.5 baseline; refusing patch.')
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron app identity changed; refusing patch.')
def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, found {n}')
    return s.replace(a,b,1)

main=once(main,
'''let timerWindowPositionSaveTimer = null;
let applyingTimerWindowGeometry = false;
let timerWindowModeActive = false;
let mainWindow;''',
'''let timerWindowPositionSaveTimer = null;
let applyingTimerWindowGeometry = false;
let timerWindowModeActive = false;
let billingDisplayHooksRegistered = false;
let billingDisplaySyncInProgress = false;
let mainWindow;''','Display synchronization state')

a=main.index('function clampTimerWindowPosition('); b=main.index('function persistTimerWindowPositionNow',a)
if a<0 or b<=a: raise SystemExit('Timer geometry helper boundaries missing.')
main=main[:a]+'''function resolveTimerWindowGeometry(position,width=500,height=76,preferredDisplay=null){
  const rawX=Number(position?.x),rawY=Number(position?.y),fallback=screen.getPrimaryDisplay();
  const rw=Math.max(1,Math.ceil(Number(width)||500)),rh=Math.max(1,Math.ceil(Number(height)||76));
  let d=preferredDisplay;
  if(!d){
    const px=Number.isFinite(rawX)?rawX+rw/2:fallback.bounds.x+fallback.bounds.width-rw/2-24;
    const py=Number.isFinite(rawY)?rawY+rh/2:fallback.bounds.y+24+rh/2;
    try{d=screen.getDisplayNearestPoint({x:Math.round(px),y:Math.round(py)});}catch(_){d=fallback;}
  }
  const area=d?.workArea||d?.bounds||fallback.workArea||fallback.bounds;
  const aw=Math.max(1,Math.floor(area.width-16)),ah=Math.max(1,Math.floor(area.height-16));
  const minW=Math.min(220,aw),maxW=Math.max(minW,Math.min(520,aw));
  const minH=Math.min(54,ah),maxH=Math.max(minH,Math.min(110,ah));
  const w=Math.max(minW,Math.min(maxW,rw)),h=Math.max(minH,Math.min(maxH,rh));
  const minX=area.x+8,minY=area.y+8,maxX=Math.max(minX,area.x+area.width-w-8),maxY=Math.max(minY,area.y+area.height-h-8);
  const x=Number.isFinite(rawX)?rawX:area.x+area.width-w-24,y=Number.isFinite(rawY)?rawY:area.y+24;
  return {x:Math.min(maxX,Math.max(minX,Math.round(x))),y:Math.min(maxY,Math.max(minY,Math.round(y))),width:w,height:h,display:d};
}
function clampTimerWindowPosition(position,width=500,height=76){
  const g=resolveTimerWindowGeometry(position,width,height);return {x:g.x,y:g.y};
}
''' + main[b:]

a=main.index('function applyTimerWindowGeometry('); b=main.index('function releaseDesktopLock',a)
if a<0 or b<=a: raise SystemExit('Timer/login/recovery helper boundaries missing.')
main=main[:a]+'''function applyTimerWindowGeometry(w,width=500,height=76,preferredDisplay=null){
  if(!w||w.isDestroyed())return;
  const b=w.getBounds(),saved=readTimerWindowPosition(),g=resolveTimerWindowGeometry(saved||{x:b.x,y:b.y},width,height,preferredDisplay);
  const c=w.getContentBounds();applyingTimerWindowGeometry=true;
  try{
    if(Math.abs(c.width-g.width)>1||Math.abs(c.height-g.height)>1)w.setContentSize(g.width,g.height,true);
    const after=w.getBounds();if(after.x!==g.x||after.y!==g.y)w.setPosition(g.x,g.y,true);
  }catch(e){console.error('Gagal menerapkan ukuran/posisi timer:',e?.message||e);}
  finally{setTimeout(()=>{applyingTimerWindowGeometry=false;if(timerWindowModeActive)persistTimerWindowPositionNow(w);},120);}
}
function clampActiveTimerWindowToDisplay(w=mainWindow,d=null){
  if(!w||w.isDestroyed()||!timerWindowModeActive)return;
  const c=w.getContentBounds();applyTimerWindowGeometry(w,c.width||500,c.height||76,d);
}
function fitRecoveryWindowToDisplay(w=mainWindow,d=null){
  if(!w||w.isDestroyed())return;
  if(!d){try{d=screen.getDisplayMatching(w.getBounds());}catch(_){}}
  d=d||screen.getPrimaryDisplay();const a=d.workArea||d.bounds,b=w.getBounds();
  const mw=Math.max(1,Math.floor(a.width-24)),mh=Math.max(1,Math.floor(a.height-24));
  const width=Math.max(Math.min(800,mw),Math.min(960,mw,Math.round(b.width||800)));
  const height=Math.max(Math.min(520,mh),Math.min(680,mh,Math.round(b.height||520)));
  const minX=a.x+12,minY=a.y+12,maxX=Math.max(minX,a.x+a.width-width-12),maxY=Math.max(minY,a.y+a.height-height-12);
  w.setBounds({x:Math.min(maxX,Math.max(minX,Math.round(b.x))),y:Math.min(maxY,Math.max(minY,Math.round(b.y))),width,height});
}
function applyLoginKioskMode(w=mainWindow,targetDisplay=null,reveal=true){
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
}
function applyActiveTimerWindowMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=true;w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);w.setAlwaysOnTop(true,'floating');w.setResizable(false);w.setMinimizable(false);if(w.isMinimized())w.restore();applyTimerWindowGeometry(w,500,76);w.show();}
function handleBillingDisplayLayoutChange(reason,changedDisplay=null){
  if(WATCHDOG_AGENT_MODE||billingDisplaySyncInProgress)return;
  const w=mainWindow;if(!w||w.isDestroyed())return;
  billingDisplaySyncInProgress=true;
  try{
    let d=null;try{d=screen.getDisplayMatching(w.getBounds());}catch(_){}
    if(changedDisplay&&d&&String(changedDisplay.id)===String(d.id))d=changedDisplay;
    d=d||screen.getPrimaryDisplay();
    if(timerWindowModeActive){const c=w.getContentBounds();applyTimerWindowGeometry(w,c.width||500,c.height||76,d);}
    else if(billingRecoveryMode)fitRecoveryWindowToDisplay(w,d);
    else if(billingUiReady)applyLoginKioskMode(w,d,false);
  }catch(e){console.error('Gagal sinkronisasi ukuran Billing dengan layar client ('+String(reason)+'):',e?.message||e);}
  finally{setTimeout(()=>{billingDisplaySyncInProgress=false;},180);}
}
''' + main[b:]

old='''function releaseDesktopLock(reason='recovery'){
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
}'''
new='''function releaseDesktopLock(reason='recovery'){
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
main=once(main,old,new,'Recovery window fit')

a=main.index("ipcMain.on('resize-timer-window'");b=main.index("ipcMain.on('minimize-timer-window'",a)
if a<0 or b<=a: raise SystemExit('Timer resize IPC boundaries missing.')
main=main[:a]+'''ipcMain.on('resize-timer-window',(event,width,height)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed()||!billingUiReady||billingRecoveryMode||!timerWindowModeActive)return;
    try{
        const b=mainWindow.getBounds(),g=resolveTimerWindowGeometry({x:b.x,y:b.y},width,height),c=mainWindow.getContentBounds();
        if(Math.abs(c.width-g.width)<=1&&Math.abs(c.height-g.height)<=1&&b.x===g.x&&b.y===g.y)return;
        applyingTimerWindowGeometry=true;mainWindow.setContentSize(g.width,g.height,true);
        const after=mainWindow.getBounds();if(after.x!==g.x||after.y!==g.y)mainWindow.setPosition(g.x,g.y,true);
        setTimeout(()=>{applyingTimerWindowGeometry=false;persistTimerWindowPositionNow(mainWindow);},120);
    }catch(e){applyingTimerWindowGeometry=false;console.error('Gagal mengubah ukuran timer:',e?.message||e);}
});

''' + main[b:]

oldhooks='''    if (!WATCHDOG_AGENT_MODE) {
        screen.on('display-metrics-changed', () => clampActiveTimerWindowToDisplay(protectedWindow));
        screen.on('display-removed', () => clampActiveTimerWindowToDisplay(protectedWindow));
        screen.on('display-added', () => clampActiveTimerWindowToDisplay(protectedWindow));
    }'''
newhooks='''    if (!WATCHDOG_AGENT_MODE && !billingDisplayHooksRegistered) {
        billingDisplayHooksRegistered=true;
        screen.on('display-metrics-changed', (_event,display,changedMetrics) => handleBillingDisplayLayoutChange('display-metrics-changed:'+String((changedMetrics||[]).join(',')),display));
        screen.on('display-removed', (_event,display) => handleBillingDisplayLayoutChange('display-removed',display));
        screen.on('display-added', (_event,display) => handleBillingDisplayLayoutChange('display-added',display));
    }'''
main=once(main,oldhooks,newhooks,'All-mode display event handlers')

oldcss='''        /* V12.4.5 client viewport fit */
        #lock-screen{width:100vw;height:100vh;min-height:0;max-height:100vh;overflow:hidden;padding:clamp(8px,2vh,20px);}
        #lock-screen .login-box{width:min(440px,calc(100vw - 24px));max-width:440px;max-height:calc(100vh - 16px);transform-origin:center center;}
        @media(max-height:680px){
          #lock-screen .login-box{padding:clamp(10px,2vh,20px) clamp(12px,2vw,24px);}
          #lock-screen .brand-header{gap:6px;margin-bottom:clamp(8px,1.5vh,14px);}
          #lock-screen .brand-logo{width:clamp(38px,7vh,56px);height:clamp(38px,7vh,56px);}
          #lock-screen .pc-state-badge{margin-bottom:clamp(8px,1.5vh,12px);padding:6px 10px;font-size:10px;}
          #lock-screen .instruction{font-size:12px;margin-bottom:10px;}
          #lock-screen .input-code{padding:9px;font-size:16px;margin-bottom:10px;}
          #lock-screen .btn{padding:9px 12px;}
        }
        @media(max-width:520px){
          #lock-screen .login-box{width:calc(100vw - 16px);padding-left:12px;padding-right:12px;}
          #lock-screen .brand-logo-container{gap:8px;}
          #lock-screen .brand-title{font-size:clamp(15px,4vw,22px);}
          #lock-screen .input-code{letter-spacing:clamp(1px,1vw,4px);}
        }'''
newcss='''        /* ANI_GAMES_V12_4_6_RESPONSIVE_DISPLAY_FIT */
        #lock-screen{box-sizing:border-box!important;width:100vw!important;height:var(--billing-viewport-height,100dvh)!important;min-height:var(--billing-viewport-height,100dvh)!important;max-height:none!important;overflow:auto!important;padding:clamp(12px,2.4vmin,30px)!important;overscroll-behavior:contain;}
        #lock-screen .login-box{box-sizing:border-box!important;width:clamp(340px,min(42vw,70vh),760px)!important;max-width:calc(100vw - 32px)!important;min-width:0!important;max-height:calc(var(--billing-viewport-height,100dvh) - 32px)!important;overflow-x:hidden!important;overflow-y:auto!important;overscroll-behavior:contain;padding:clamp(18px,2.6vmin,38px) clamp(16px,2.6vw,36px)!important;border-radius:clamp(14px,1.25vw,22px)!important;transform:none!important;}
        #lock-screen .admin-trigger{position:fixed!important;top:clamp(10px,2vh,25px)!important;right:clamp(10px,2vw,25px)!important;}
        #lock-screen .billing-restart-trigger{left:clamp(10px,2vw,22px)!important;bottom:clamp(10px,2vh,22px)!important;}
        #lock-screen .billing-shutdown-trigger{right:clamp(10px,2vw,22px)!important;bottom:clamp(10px,2vh,22px)!important;}
        #lock-screen .brand-header{gap:clamp(6px,1.2vh,12px)!important;margin-bottom:clamp(10px,2.4vh,24px)!important;}
        #lock-screen .brand-logo{width:clamp(48px,7.5vh,88px)!important;height:clamp(48px,7.5vh,88px)!important;}
        #lock-screen .brand-title{font-size:clamp(18px,2vw,30px)!important;line-height:1.15;}
        #lock-screen .brand-subtitle{font-size:clamp(9px,.85vw,12px)!important;letter-spacing:clamp(1px,.12vw,2px);}
        #lock-screen .pc-state-badge{margin-bottom:clamp(8px,1.5vh,16px)!important;padding:clamp(5px,.9vh,9px) clamp(8px,1.2vw,14px)!important;font-size:clamp(9px,.8vw,12px)!important;}
        #lock-screen .instruction{font-size:clamp(12px,1vw,16px)!important;margin-bottom:clamp(8px,1.8vh,20px)!important;}
        #lock-screen .input-code{padding:clamp(9px,1.5vh,16px)!important;font-size:clamp(15px,1.45vw,22px)!important;letter-spacing:clamp(1px,.25vw,4px)!important;}
        #lock-screen .btn{padding:clamp(8px,1.25vh,13px) clamp(10px,1.5vw,18px)!important;font-size:clamp(11px,.9vw,14px)!important;}
        @media(max-height:680px){#lock-screen{padding:8px!important;}#lock-screen .login-box{padding:10px 16px!important;max-height:calc(var(--billing-viewport-height,100dvh) - 16px)!important;}#lock-screen .brand-header{gap:4px!important;margin-bottom:7px!important;}#lock-screen .brand-logo{width:clamp(34px,6.5vh,52px)!important;height:clamp(34px,6.5vh,52px)!important;}#lock-screen .brand-title{font-size:clamp(16px,1.8vw,23px)!important;}#lock-screen .brand-subtitle{font-size:9px!important;}#lock-screen .pc-state-badge{margin-bottom:7px!important;padding:4px 8px!important;}#lock-screen .instruction{font-size:11px!important;margin-bottom:7px!important;}#lock-screen .input-code{padding:7px!important;font-size:15px!important;margin-bottom:7px!important;}#lock-screen .btn{padding:7px 10px!important;}}
        @media(max-height:480px){#lock-screen .login-box{padding:7px 12px!important;}#lock-screen .brand-header{margin-bottom:4px!important;}#lock-screen .brand-logo{width:30px!important;height:30px!important;}#lock-screen .pc-state-badge{margin-bottom:4px!important;}#lock-screen .instruction{margin-bottom:4px!important;}#lock-screen .input-code{padding:5px!important;margin-bottom:4px!important;}#lock-screen .btn{padding:5px 8px!important;}}
        @media(max-width:520px){#lock-screen .login-box{width:calc(100vw - 16px)!important;padding-left:12px!important;padding-right:12px!important;}#lock-screen .brand-logo-container{gap:8px!important;}#lock-screen .brand-title{font-size:clamp(15px,4vw,22px)!important;}#lock-screen .input-code{letter-spacing:clamp(1px,1vw,4px)!important;}}'''
html=once(html,oldcss,newcss,'Responsive login CSS')

oldfit='''        function fitLoginBoxToViewport(){
            const lock=document.getElementById('lock-screen'),card=lock?.querySelector('.login-box');
            if(!lock||!card||lock.classList.contains('hidden'))return;
            card.style.transform='scale(1)';
            requestAnimationFrame(()=>{
                if(lock.classList.contains('hidden'))return;
                const width=Math.max(1,card.offsetWidth),height=Math.max(1,card.offsetHeight);
                const aw=Math.max(240,window.innerWidth-24),ah=Math.max(240,window.innerHeight-24);
                const scale=Math.max(0.55,Math.min(1,aw/width,ah/height));
                card.style.transform='scale('+scale+')';
            });
        }
        window.addEventListener('resize',()=>requestAnimationFrame(fitLoginBoxToViewport),{passive:true});
        window.addEventListener('orientationchange',()=>setTimeout(fitLoginBoxToViewport,150),{passive:true});
        requestAnimationFrame(fitLoginBoxToViewport);'''
newfit='''        let loginFitAnimationFrame=0;
        function fitLoginBoxToViewport(){
            const lock=document.getElementById('lock-screen'),card=lock?.querySelector('.login-box');
            if(!lock||!card||lock.classList.contains('hidden'))return;
            const viewport=window.visualViewport;
            const width=Math.max(1,Math.round(viewport?.width||window.innerWidth||document.documentElement.clientWidth));
            const height=Math.max(1,Math.round(viewport?.height||window.innerHeight||document.documentElement.clientHeight));
            document.documentElement.style.setProperty('--billing-viewport-width',width+'px');
            document.documentElement.style.setProperty('--billing-viewport-height',height+'px');
            lock.style.setProperty('--billing-viewport-height',height+'px');
            card.style.transform='none';
            lock.classList.toggle('billing-fit-scroll',card.scrollHeight>Math.max(1,height-32));
        }
        function queueLoginViewportFit(){
            if(loginFitAnimationFrame)cancelAnimationFrame(loginFitAnimationFrame);
            loginFitAnimationFrame=requestAnimationFrame(()=>{loginFitAnimationFrame=0;fitLoginBoxToViewport();});
        }
        window.addEventListener('resize',queueLoginViewportFit,{passive:true});
        window.addEventListener('orientationchange',()=>setTimeout(queueLoginViewportFit,120),{passive:true});
        if(window.visualViewport){
            window.visualViewport.addEventListener('resize',queueLoginViewportFit,{passive:true});
            window.visualViewport.addEventListener('scroll',queueLoginViewportFit,{passive:true});
        }
        if(window.ResizeObserver){
            const loginViewportObserver=new ResizeObserver(queueLoginViewportFit);
            const lockForResize=document.getElementById('lock-screen');
            if(lockForResize)loginViewportObserver.observe(lockForResize);
        }
        requestAnimationFrame(fitLoginBoxToViewport);'''
html=once(html,oldfit,newfit,'Viewport fit runtime')
if 'setTimeout(() => { fitLoginBoxToViewport(); focusLoginInput(); }, 120);' not in html:
    html=once(html,'setTimeout(focusLoginInput, 120);','setTimeout(() => { fitLoginBoxToViewport(); focusLoginInput(); }, 120);','Refit after return to Login')

pkg['version']='12.4.6'
pkg['description']='AniGames Billing V12.4.6: responsive fullscreen display synchronization, DPI/monitor-change recovery, and viewport-fit client login.'
lock['version']='12.4.6'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.6'
html=html.replace(OLD,NEW);renderer=renderer.replace(OLD,NEW)
mainp.write_text(main,encoding='utf-8');htmlp.write_text(html,encoding='utf-8');renderp.write_text(renderer,encoding='utf-8')
pkgp.write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8');lockp.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
verp.write_text(NEW+'\nResponsive monitor/DPI/fullscreen bounds, work-area-clamped timer and recovery windows, and adaptive Login viewport. Rental/session, pairing, WOL, Admin commands, and shutdown policy preserved.\n',encoding='utf-8')
(R/'RESPONSIVE-DISPLAY-FIT-V12.4.6-AUDIT.md').write_text('''# AniGames Billing PC V12.4.6 — Responsive Display Fit Audit

## Confirmed V12.4.5 findings
- Login card was capped at 440 CSS px, so it could look undersized on larger fullscreen clients.
- Login scaler had a 0.55 minimum transform scale. A short viewport requiring a smaller ratio could still clip the card.
- Display metrics/add/remove handlers only repositioned the active timer popup; they did not reapply fullscreen Login/Kiosk bounds or fit the recovery window.
- Timer popup clamped position but not final dimensions against unusually small virtual-display work areas.

## V12.4.6 changes
- Reapplies current display bounds on monitor size/orientation/DPI changes and display add/remove events.
- Preserves hidden state after Admin Logout; display events do not reopen Billing.
- Fits timer popup dimensions and position to the active display work area.
- Fits the renderer-recovery window to the current display work area.
- Expands Login card up to 760 CSS px, uses viewport-based sizes, compresses controls on short screens, and remains scrollable rather than clipped if the physical viewport cannot fit all controls.
- Removes fixed 0.55 transform floor and tracks window resize, VisualViewport resize/scroll and ResizeObserver changes.
- Preserves appId/productName/userData, pairing, rental/session, WOL, Admin Logout/Login, direct power actions, and disabled automatic shutdown countdown.

## Validation
- Exact V12.4.5 package/version baseline required.
- Static patch assertions verify native screen event coverage, responsive viewport, timer/recovery work-area fit, and stable app identity.
- CI verifies JavaScript syntax and Windows portable packaging. Physical multi-resolution/VDD validation remains required on client machines.
''',encoding='utf-8')
for t in ['function resolveTimerWindowGeometry(','function fitRecoveryWindowToDisplay(','function handleBillingDisplayLayoutChange(','billingDisplayHooksRegistered','display-metrics-changed','display-removed','display-added','applyLoginKioskMode(w,d,false)','fitRecoveryWindowToDisplay(w)']:
    if t not in main: raise SystemExit('V12.4.6 main assertion missing: '+t)
for t in ['overflow:auto!important','max-width:calc(100vw - 32px)','ResizeObserver',"visualViewport.addEventListener('resize'","card.style.transform='none'",NEW]:
    if t not in html: raise SystemExit('V12.4.6 renderer assertion missing: '+t)
if 'Math.max(0.55' in html: raise SystemExit('Old 0.55 scale floor remains.')
if pkg.get('version')!='12.4.6' or lock.get('version')!='12.4.6': raise SystemExit('Package version mismatch.')
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test' or pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron app identity changed.')
print('PASS: V12.4.6 responsive display fit, timer and recovery work-area fit, monitor/DPI event synchronization, and stable app identity.')
