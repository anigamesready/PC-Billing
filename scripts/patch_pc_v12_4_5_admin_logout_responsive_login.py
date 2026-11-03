from pathlib import Path
import json

R=Path('.')
names=('main.js','preload.js','index.html','v11-cloud.js','package.json','package-lock.json','VERSION.txt')
paths={n:R/n for n in names}
for p in paths.values():
    if not p.is_file(): raise SystemExit('Required V12.4.4 source missing: '+str(p))
main=paths['main.js'].read_text(encoding='utf-8')
pre=paths['preload.js'].read_text(encoding='utf-8')
html=paths['index.html'].read_text(encoding='utf-8')
cloud=paths['v11-cloud.js'].read_text(encoding='utf-8')
pkg=json.loads(paths['package.json'].read_text(encoding='utf-8'))
lock=json.loads(paths['package-lock.json'].read_text(encoding='utf-8'))
OLD='V12.4.4-ADMIN-WINDOWS-CONTROLS'
NEW='V12.4.5-ADMIN-LOGOUT-RESPONSIVE-LOGIN'
if NEW in html and "ipcMain.handle('hide-billing'" in main:
    print('PASS: V12.4.5 already applied'); raise SystemExit(0)
if pkg.get('version')!='12.4.4' or html.count(OLD)!=2:
    raise SystemExit('Expected exact V12.4.4 baseline; refusing patch.')
def once(src,old,new,label):
    n=src.count(old)
    if n!=1: raise SystemExit(f'{label} anchor mismatch: expected 1, found {n}')
    return src.replace(old,new,1)

# Use the client monitor's actual geometry from startup and on every return to Login.
main=once(main,
"function createWindow() {\n    mainWindow = new BrowserWindow({\n        width: 1280,\n        height: 720,",
"function createWindow() {\n    const startupDisplay=screen.getPrimaryDisplay();\n    const startupBounds=startupDisplay.bounds;\n    mainWindow = new BrowserWindow({\n        x:startupBounds.x,\n        y:startupBounds.y,\n        width:startupBounds.width,\n        height:startupBounds.height,",
"Startup display bounds")
old="function applyLoginKioskMode(w=mainWindow){if(!w||w.isDestroyed())return;timerWindowModeActive=false;w.setKiosk(true);w.setFullScreen(true);w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);if(w.isMinimized())w.restore();w.show();w.focus();}"
new="""function applyLoginKioskMode(w=mainWindow){
  if(!w||w.isDestroyed())return;
  timerWindowModeActive=false;
  try{
    const display=screen.getDisplayMatching(w.getBounds()),bounds=display.bounds;
    if(w.isFullScreen())w.setFullScreen(false);
    w.setKiosk(false);
    w.setBounds({x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height});
    w.setResizable(false);w.setMinimizable(false);w.setFocusable(true);
    w.setKiosk(true);w.setFullScreen(true);
    w.setAlwaysOnTop(true,'screen-saver');w.setIgnoreMouseEvents(false);
    if(w.isMinimized())w.restore();
    w.show();w.focus();
  }catch(e){console.error('Gagal menyesuaikan login Billing ke layar client:',e?.message||e);}
}"""
main=once(main,old,new,'Responsive kiosk geometry')

# Hide the visible Billing window, not the process. The hidden renderer keeps the
# cloud heartbeat and Admin/Windows command channel alive.
ipc="""ipcMain.handle('hide-billing',(event)=>{
  if(WATCHDOG_AGENT_MODE||event.sender!==mainWindow?.webContents||!billingUiReady||billingRecoveryMode||!mainWindow||mainWindow.isDestroyed())return {ok:false,message:'Billing belum siap untuk Logout.'};
  try{applyLoginKioskMode(mainWindow);mainWindow.hide();return {ok:true,mode:'hidden',background:'running'};}
  catch(e){return {ok:false,message:String(e?.message||'Gagal Logout Billing.')};}
});
ipcMain.handle('show-billing',(event)=>{
  if(WATCHDOG_AGENT_MODE||event.sender!==mainWindow?.webContents||!billingUiReady||billingRecoveryMode||!mainWindow||mainWindow.isDestroyed())return {ok:false,message:'Billing belum siap untuk Login.'};
  try{applyLoginKioskMode(mainWindow);mainWindow.show();mainWindow.focus();return {ok:true,mode:'visible'};}
  catch(e){return {ok:false,message:String(e?.message||'Gagal membuka Login Billing.')};}
});

"""
main=once(main,"ipcMain.on('resize-timer-window',(event,width,height)=>{",ipc+"ipcMain.on('resize-timer-window',(event,width,height)=>{",'Hide/show IPC')
pre=once(pre,"    exitBilling: (options = {}) => ipcRenderer.invoke('exit-billing', options),",
"    exitBilling: (options = {}) => ipcRenderer.invoke('exit-billing', options),\n    hideBilling: () => ipcRenderer.invoke('hide-billing'),\n    showBilling: () => ipcRenderer.invoke('show-billing'),",
"Preload hide/show API")

# CSS: responsive width/height, compress spacing on short screens, and scale the login card
# when a remote/VDD client reports a smaller viewport. No Windows resolution is changed.
css="""
        /* V12.4.5 client viewport fit */
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
        }
"""
html=once(html,'    </style>',css+'    </style>','Login fit CSS')
fit="""        function fitLoginBoxToViewport(){
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
        requestAnimationFrame(fitLoginBoxToViewport);

"""
html=once(html,"        let lastTimerWindowSizeKey = '';",fit+"        let lastTimerWindowSizeKey = '';",'Login viewport fit runtime')
html=once(html,"            setTimeout(focusLoginInput, 120);",
"            setTimeout(() => { fitLoginBoxToViewport(); focusLoginInput(); }, 120);",
"Refit login after Stop")

# Stop stays on the login screen. Logout stops the rental, then hides the Login window.
old="""            if (cmd === 'stop' || cmd === 'logout') {
                localStorage.removeItem('billing_remote_paused_code');
                if (currentActiveCode) {
                    const stoppedCode = currentActiveCode;
                    window.v11SyncApplying = true;
                    try { pauseSession(false); } finally { window.v11SyncApplying = false; }
                    if (stoppedCode !== TEST_SESSION_CODE) {
                        const stoppedUser = dbUsers[stoppedCode];
                        emitRentalAdminAlert('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {
                            code: stoppedCode,
                            remainingSeconds: Math.max(0, Number(stoppedUser?.remainingSeconds) || 0)
                        });
                    }
                } else {
                    saveDB();
                }
                return {ok:true, message:'Sesi dihentikan/dikeluarkan.'};
            }
"""
new="""            if (cmd === 'stop' || cmd === 'logout') {
                localStorage.removeItem('billing_remote_paused_code');
                if (currentActiveCode) {
                    const stoppedCode = currentActiveCode;
                    window.v11SyncApplying = true;
                    try { pauseSession(false); } finally { window.v11SyncApplying = false; }
                    if (stoppedCode !== TEST_SESSION_CODE) {
                        const stoppedUser = dbUsers[stoppedCode];
                        emitRentalAdminAlert('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {
                            code: stoppedCode,
                            remainingSeconds: Math.max(0, Number(stoppedUser?.remainingSeconds) || 0)
                        });
                    }
                } else { saveDB(); }
                if (cmd === 'logout') {
                    localStorage.setItem('ani_games_billing_ui_state','closed');
                    try { window.v11HeartbeatNow?.('billing_ui_closed'); } catch (_) {}
                    const hidden=await window.electronAPI?.hideBilling?.();
                    if(hidden?.ok===false)return {ok:false,message:hidden.message||'Sesi berhenti, tetapi tampilan Billing gagal ditutup.'};
                    return {ok:true,message:'Sesi rental dihentikan, waktu berhenti, dan Billing ditutup. Login Billing dari Admin untuk membuka kembali.'};
                }
                return {ok:true,message:'Sesi dihentikan. Billing tetap terbuka di halaman Login.'};
            }
"""
html=once(html,old,new,'Separate Stop and Logout')
old="            if (cmd === 'refresh') { location.reload(); return {ok:true, message:'Billing direfresh.'}; }"
new="""            if (cmd === 'refresh') {
                if(localStorage.getItem('ani_games_billing_ui_state')==='closed'){
                    localStorage.setItem('ani_games_billing_ui_state','open');
                    try{window.v11HeartbeatNow?.('billing_ui_open');}catch(_){}
                    const shown=await window.electronAPI?.showBilling?.();
                    if(shown?.ok===false){localStorage.setItem('ani_games_billing_ui_state','closed');return {ok:false,message:shown.message||'Login Billing gagal dibuka.'};}
                    return {ok:true,message:'Halaman Login Billing berhasil dibuka kembali.'};
                }
                location.reload();return {ok:true,message:'Billing direfresh.'};
            }"""
html=once(html,old,new,'Refresh/Login command')
cloud=once(cloud,"metadata:{clientId:c.clientId,rentalSyncReady:",
"metadata:{clientId:c.clientId,billingUiState:String(localStorage.getItem('ani_games_billing_ui_state')||'open'),rentalSyncReady:",
"Billing UI heartbeat")

if pkg.get('version')!='12.4.4' or lock.get('version')!='12.4.4': raise SystemExit('Unexpected PC package baseline.')
if pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test': raise SystemExit('Persistent Electron appId changed.')
pkg['version']='12.4.5'
pkg['description']='AniGames Billing V12.4.5: Admin Logout hides Billing UI while preserving background command control; Login restores it; client login viewport fits the active display.'
lock['version']='12.4.5'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.4.5'
html=html.replace(OLD,NEW)

for label,src,tokens in (
 ('main',main,["ipcMain.handle('hide-billing'","ipcMain.handle('show-billing'","screen.getDisplayMatching(w.getBounds())","w.setBounds({x:bounds.x,y:bounds.y,width:bounds.width,height:bounds.height})","const powerCommands = { logoff: ['/l'], restart: ['/r', '/t', '0'], shutdown: ['/s', '/t', '0'] }"]),
 ('preload',pre,["hideBilling: () => ipcRenderer.invoke","showBilling: () => ipcRenderer.invoke"]),
 ('index',html,[NEW,'fitLoginBoxToViewport','ani_games_billing_ui_state',"window.electronAPI?.hideBilling?.()","window.electronAPI?.showBilling?.()","if (cmd === 'schedule_shutdown')",'SHUTDOWN_TIMER_DISABLED']),
 ('cloud',cloud,['billingUiState:String(localStorage.getItem'])
):
    for t in tokens:
        if t not in src: raise SystemExit(f'{label} regression assertion missing: {t}')
if 'ANI_GAMES_V12_4_3_BLOCK_SHUTDOWN_IPC' in main or 'SHUTDOWN_DISABLED' in main or 'SHUTDOWN_DISABLED' in html: raise SystemExit('V12.4.4 direct Windows controls regressed.')
for t in ('function v12CheckScheduledShutdown()','function v12ShutdownScheduleFromAdmin(','function v12CancelScheduledShutdown(','V12_SHUTDOWN_TIMER_KEY'):
    if t in html: raise SystemExit('Automatic shutdown countdown was reintroduced: '+t)

paths['main.js'].write_text(main,encoding='utf-8')
paths['preload.js'].write_text(pre,encoding='utf-8')
paths['index.html'].write_text(html,encoding='utf-8')
paths['v11-cloud.js'].write_text(cloud,encoding='utf-8')
paths['package.json'].write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
paths['package-lock.json'].write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
paths['VERSION.txt'].write_text(NEW+'\nAdmin Logout stops the active rental and hides Billing; the existing background renderer keeps cloud heartbeat, pairing and all Admin/Windows commands alive. Login restores the fullscreen code-entry screen. Login geometry and card size follow the active client display; Windows resolution is not changed. Automatic shutdown countdown remains disabled.\n',encoding='utf-8')
(R/'ADMIN-LOGOUT-RESPONSIVE-LOGIN-V12.4.5-AUDIT.md').write_text(
 '# PC Billing V12.4.5 — Admin Logout + Responsive Login\n\n'
 '- Admin Logout stops the active rental timer, preserves remaining time, ends the session and hides the Billing window.\n'
 '- The renderer/main process remains alive in the background: cloud heartbeat, command polling, pairing, Windows controls, and watchdog stay connected.\n'
 '- Admin Login Billing uses the existing refresh command to restore the hidden window in fullscreen Login mode.\n'
 '- If Billing is not running, the existing Restart Billing watchdog queue remains available.\n'
 '- Login kiosk bounds are recalculated from the client display; the login card scales to the viewport. No Windows display-resolution change is made.\n'
 '- Stop remains separate: it ends the rental session but keeps the Billing Login screen visible.\n'
 '- Direct Windows logoff/restart/shutdown remain enabled; automatic shutdown countdown remains disabled.\n'
 '- Electron appId, productName, userData, pairing tokens, rental data, and WOL identity remain unchanged.\n'
 '- Static checks pass; physical Windows/VDD multi-resolution behavior still requires client-side test.\n',encoding='utf-8')
print('PASS: PC V12.4.5 Logout hides Billing after stopping the session; background commands stay alive; Login restores fullscreen; responsive client viewport; countdown remains disabled.')
