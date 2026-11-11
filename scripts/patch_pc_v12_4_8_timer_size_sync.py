from pathlib import Path
import json

R=Path(".")
N=("main.js","index.html","renderer.js","package.json","package-lock.json","VERSION.txt")
P={n:R/n for n in N}
for p in P.values():
    if not p.is_file(): raise SystemExit("V12.4.7 source missing: "+str(p))
m=P["main.js"].read_text(encoding="utf-8")
h=P["index.html"].read_text(encoding="utf-8")
r=P["renderer.js"].read_text(encoding="utf-8")
pkg=json.loads(P["package.json"].read_text(encoding="utf-8"))
lock=json.loads(P["package-lock.json"].read_text(encoding="utf-8"))
OLD="V12.4.7-FULLSCREEN-NONINTERFERENCE"
NEW="V12.4.8-TIMER-SIZE-SYNC"
if NEW in h and "pendingTimerWindowGeometry = null" in m:
    print("PASS: V12.4.8 already applied"); raise SystemExit(0)
if pkg.get("version")!="12.4.7" or lock.get("version")!="12.4.7" or OLD not in h or OLD not in r:
    raise SystemExit("Expected exact V12.4.7 source baseline.")
if pkg.get("build",{}).get("appId")!="com.anigames.billing.v12test" or pkg.get("build",{}).get("productName")!="AniGames Billing V12.3.3":
    raise SystemExit("Persistent Electron app identity changed.")

def once(s,a,b,label):
    n=s.count(a)
    if n!=1: raise SystemExit(f"{label} anchor mismatch: expected 1, found {n}")
    return s.replace(a,b,1)

# V12.4.7 remembered only a boolean when the native resize request arrived
# while Billing was unfocused, then reused the previous native content size.
m=once(m,
"let billingLoginKioskPending = false, pendingTimerWindowGeometrySync = false;\nlet deferredRendererRecovery = null;",
"let billingLoginKioskPending = false, pendingTimerWindowGeometrySync = false;\nlet pendingTimerWindowGeometry = null;\nlet deferredRendererRecovery = null;",
"Pending timer geometry state")

helper_old="""function clampActiveTimerWindowToDisplay(w=mainWindow,d=null){
  if(!w||w.isDestroyed()||!timerWindowModeActive)return;
  const c=w.getContentBounds();applyTimerWindowGeometry(w,c.width||500,c.height||76,d);
}"""
helper_new="""function rememberPendingTimerWindowGeometry(width=500,height=76){
  const rw=Number(width),rh=Number(height);
  pendingTimerWindowGeometry={
    width:Math.max(220,Math.min(520,Math.ceil(Number.isFinite(rw)&&rw>0?rw:500))),
    height:Math.max(54,Math.min(110,Math.ceil(Number.isFinite(rh)&&rh>0?rh:76)))
  };
  pendingTimerWindowGeometrySync=true;
}
function flushPendingTimerWindowGeometry(w=mainWindow,preferredDisplay=null){
  if(!w||w.isDestroyed()||!timerWindowModeActive||!w.isFocused())return false;
  const c=w.getContentBounds(),target=pendingTimerWindowGeometry||{width:c.width||500,height:c.height||76};
  pendingTimerWindowGeometry=null;pendingTimerWindowGeometrySync=false;
  applyTimerWindowGeometry(w,target.width,target.height,preferredDisplay);
  return true;
}
function clampActiveTimerWindowToDisplay(w=mainWindow,d=null){
  if(!w||w.isDestroyed()||!timerWindowModeActive)return;
  if(w.isFocused()){flushPendingTimerWindowGeometry(w,d);return;}
  const c=w.getContentBounds();
  if(!pendingTimerWindowGeometry)rememberPendingTimerWindowGeometry(c.width||500,c.height||76);
}"""
m=once(m,helper_old,helper_new,"Pending geometry helpers")

m=once(m,
"  billingLoginKioskPending=false;timerWindowModeActive=false;\n  try{\n    let d=targetDisplay;",
"  billingLoginKioskPending=false;timerWindowModeActive=false;\n  pendingTimerWindowGeometry=null;pendingTimerWindowGeometrySync=false;\n  try{\n    let d=targetDisplay;",
"Clear stale geometry on Login")

active_old="""function applyActiveTimerWindowMode(w=mainWindow){
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
}"""
active_new="""function applyActiveTimerWindowMode(w=mainWindow){
  if(!w||w.isDestroyed())return;
  timerWindowModeActive=true;billingLoginKioskPending=false;
  try{
    w.setKiosk(false);w.setFullScreen(false);w.setIgnoreMouseEvents(false);
    // Keep V12.4.7 fullscreen protection: timer never overlays or activates a game.
    w.setAlwaysOnTop(false);w.setFocusable(true);w.setResizable(false);w.setMinimizable(false);
    if(!pendingTimerWindowGeometry)rememberPendingTimerWindowGeometry(500,76);
    if(w.isFocused())flushPendingTimerWindowGeometry(w);
    if(typeof w.showInactive==='function')w.showInactive();else w.show();
  }catch(e){console.error('Gagal mengaktifkan timer background:',e?.message||e);}
}"""
m=once(m,active_old,active_new,"Active timer geometry synchronization")

display_old="""    if(timerWindowModeActive){
      if(!w.isFocused()){pendingTimerWindowGeometrySync=true;return;}
      const c=w.getContentBounds();applyTimerWindowGeometry(w,c.width||500,c.height||76,d);pendingTimerWindowGeometrySync=false;
    }else if(billingRecoveryMode){if(w.isFocused())fitRecoveryWindowToDisplay(w,d);}"""
display_new="""    if(timerWindowModeActive){
      if(!w.isFocused()){
        if(!pendingTimerWindowGeometry){const c=w.getContentBounds();rememberPendingTimerWindowGeometry(c.width||500,c.height||76);}
        return;
      }
      flushPendingTimerWindowGeometry(w,d);
    }else if(billingRecoveryMode){if(w.isFocused())fitRecoveryWindowToDisplay(w,d);}"""
m=once(m,display_old,display_new,"Display-change pending geometry preservation")

focus_old="""        if(pendingTimerWindowGeometrySync&&timerWindowModeActive){
            const c=protectedWindow.getContentBounds();applyTimerWindowGeometry(protectedWindow,c.width||500,c.height||76);pendingTimerWindowGeometrySync=false;
        }"""
focus_new="""        if(pendingTimerWindowGeometrySync&&timerWindowModeActive){
            flushPendingTimerWindowGeometry(protectedWindow);
        }"""
m=once(m,focus_old,focus_new,"Focus-return geometry flush")

resize_old="""ipcMain.on('resize-timer-window',(event,width,height)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed()||!billingUiReady||billingRecoveryMode||!timerWindowModeActive)return;
    if(!mainWindow.isFocused()){pendingTimerWindowGeometrySync=true;return;}
    try{
        const b=mainWindow.getBounds(),g=resolveTimerWindowGeometry({x:b.x,y:b.y},width,height),c=mainWindow.getContentBounds();
        if(Math.abs(c.width-g.width)<=1&&Math.abs(c.height-g.height)<=1&&b.x===g.x&&b.y===g.y)return;
        applyingTimerWindowGeometry=true;mainWindow.setContentSize(g.width,g.height,true);
        const after=mainWindow.getBounds();if(after.x!==g.x||after.y!==g.y)mainWindow.setPosition(g.x,g.y,true);
        setTimeout(()=>{applyingTimerWindowGeometry=false;persistTimerWindowPositionNow(mainWindow);},120);
    }catch(e){applyingTimerWindowGeometry=false;console.error('Gagal mengubah ukuran timer:',e?.message||e);}
});"""
resize_new="""ipcMain.on('resize-timer-window',(event,width,height)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed()||!billingUiReady||billingRecoveryMode)return;
    // Keep the exact DOM-requested size even when mode/focus IPCs arrive in either order.
    // Native geometry is only changed while Billing itself owns foreground focus.
    rememberPendingTimerWindowGeometry(width,height);
    if(!timerWindowModeActive||!mainWindow.isFocused())return;
    try{
        flushPendingTimerWindowGeometry(mainWindow);
    }catch(e){applyingTimerWindowGeometry=false;console.error('Gagal mengubah ukuran timer:',e?.message||e);}
});"""
m=once(m,resize_old,resize_new,"Resize IPC retains exact requested dimensions")

min_old="""ipcMain.on('minimize-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(!mainWindow.isFocused())pendingTimerWindowGeometrySync=true;
});"""
min_new="""ipcMain.on('minimize-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(!mainWindow.isFocused()&&!pendingTimerWindowGeometry){
        const c=mainWindow.getContentBounds();rememberPendingTimerWindowGeometry(c.width||500,c.height||76);
    }
});"""
m=once(m,min_old,min_new,"Legacy compact IPC retains native size")

restore_old="""ipcMain.on('restore-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(timerWindowModeActive&&!mainWindow.isFocused()){pendingTimerWindowGeometrySync=true;return;}
    if(timerWindowModeActive)clampActiveTimerWindowToDisplay(mainWindow);
    if(typeof mainWindow.showInactive==='function')mainWindow.showInactive();else mainWindow.show();
});"""
restore_new="""ipcMain.on('restore-timer-window',(event)=>{
    if(event.sender!==mainWindow?.webContents||!mainWindow||mainWindow.isDestroyed())return;
    if(timerWindowModeActive&&!mainWindow.isFocused()){
        if(!pendingTimerWindowGeometry){const c=mainWindow.getContentBounds();rememberPendingTimerWindowGeometry(c.width||500,c.height||76);}
        return;
    }
    if(timerWindowModeActive)clampActiveTimerWindowToDisplay(mainWindow);
    if(typeof mainWindow.showInactive==='function')mainWindow.showInactive();else mainWindow.show();
});"""
m=once(m,restore_old,restore_new,"Restore IPC preserves deferred dimensions")

# Fail closed if any V12.4.7 fullscreen-safety behavior would regress.
a=m.index("function applyActiveTimerWindowMode");b=m.index("function handleBillingDisplayLayoutChange",a);active=m[a:b]
if "w.setAlwaysOnTop(false)" not in active or "showInactive" not in active or "w.setAlwaysOnTop(true" in active or ".focus()" in active or ".restore()" in active:
    raise SystemExit("V12.4.7 active timer fullscreen protection changed.")
a=m.index("function releaseDesktopLock");b=m.index("function armRendererReadyTimeout",a);release=m[a:b]
if ".focus()" in release or ".restore()" in release or "showInactive" not in release:
    raise SystemExit("V12.4.7 recovery foreground protection changed.")
a=m.index("protectedWindow.on('focus'");b=m.index("protectedWindow.on('move'",a);focus=m[a:b]
if "flushPendingTimerWindowGeometry(protectedWindow)" not in focus:
    raise SystemExit("Focus handler does not flush exact pending timer size.")
a=m.index("ipcMain.on('resize-timer-window'");b=m.index("ipcMain.on('minimize-timer-window'",a);resize=m[a:b]
if "rememberPendingTimerWindowGeometry(width,height)" not in resize or "!timerWindowModeActive||!mainWindow.isFocused()" not in resize:
    raise SystemExit("Resize IPC does not retain the renderer's exact requested size.")
if "setAlwaysOnTop(true,'floating')" in m:
    raise SystemExit("V12.4.7 Always-on-Top timer behavior was reintroduced.")

h=h.replace(OLD,NEW)
r=r.replace(OLD,NEW)
pkg["version"]="12.4.8"
pkg["description"]="AniGames Billing V12.4.8: exact deferred timer-window size synchronization; preserves V12.4.7 fullscreen non-interference and V12.4.6 responsive Login."
lock["version"]="12.4.8"
if isinstance(lock.get("packages"),dict) and isinstance(lock["packages"].get(""),dict):
    lock["packages"][""]["version"]="12.4.8"

P["main.js"].write_text(m,encoding="utf-8")
P["index.html"].write_text(h,encoding="utf-8")
P["renderer.js"].write_text(r,encoding="utf-8")
P["package.json"].write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
P["package-lock.json"].write_text(json.dumps(lock,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
P["VERSION.txt"].write_text(NEW+"\nExact timer width/height requests are retained while unfocused and applied only after Billing safely regains foreground. V12.4.7 non-topmost and non-activating behavior is preserved.\n",encoding="utf-8")
(R/"TIMER-SIZE-SYNC-V12.4.8-AUDIT.md").write_text("""# Ani Games Ready PC V12.4.8 — Timer Size Synchronization Audit

## V12.4.7 mismatch
The renderer reports the timer widget's measured CSS size. When Billing was unfocused, the main process retained only a boolean and discarded the requested width and height. On focus return it reused the old native content size. A 220x54 native window could therefore contain a full 500x76 non-compact DOM timer, clipping its controls and panel.

## Minimal correction
- Retain the exact requested width and height, including requests arriving just before the mode IPC.
- Do not change native geometry while another application owns foreground focus.
- Flush the most recent requested dimensions when Billing safely regains focus.
- Preserve the 500x76 regular timer and 220x54 compact timer layouts.
- Clear stale pending geometry when returning to Login.
- Preserve V12.4.7 non-topmost timer, showInactive, deferred recovery and focus protection.
- Preserve app identity, userData, pairing, rental/session, Supabase routing, offline queue, WOL, Admin controls and shutdown policy.

## Validation
The build workflow checks source and runtime syntax, exact deferred-size handoff, full/compact CSS dimensions, V12.4.7 focus safety, persistent Electron identity and rental/Admin/WOL regressions before Windows EXE packaging.
""",encoding="utf-8")

print("PASS: V12.4.8 exact deferred timer geometry; V12.4.7 fullscreen non-interference and app identity preserved.")
