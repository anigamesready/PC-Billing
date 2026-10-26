from pathlib import Path
import json
import re

ROOT = Path(".")
HTML = ROOT / "index.html"
RENDERER = ROOT / "renderer.js"
CLOUD = ROOT / "v11-cloud.js"
EDGE = ROOT / "supabase/functions/ani-games-api/index.ts"
PACKAGE = ROOT / "package.json"
LOCK = ROOT / "package-lock.json"
VERSION = ROOT / "VERSION.txt"
BUILD = "V12.1.8-FREE-TEST-GATE-SHUTDOWN-TIMER"
TEST_MARK = "V12.1.8-TEST-POLICY-PREFLIGHT"

def patch_test_function(path, required=False):
    if not path.is_file():
        if required:
            raise SystemExit(f"Required PC runtime file missing: {path}")
        return False
    src = path.read_text(encoding="utf-8")
    if TEST_MARK in src:
        return True
    pattern = re.compile(r"(?m)^(?P<indent>[ \t]*)(?P<async>async[ \t]+)?function[ \t]+startTenMinuteTest[ \t]*\([ \t]*\)[ \t]*\{")
    matches = list(pattern.finditer(src))
    if len(matches) != 1:
        if required:
            raise SystemExit(f"Expected exactly one startTenMinuteTest() in {path.name}, found {len(matches)}")
        return False
    m = matches[0]
    indent = m.group("indent")
    body = indent + "    "
    declaration = m.group(0)
    if not m.group("async"):
        declaration = indent + "async " + declaration[len(indent):]
    guard = f"""
{body}// {TEST_MARK}: require explicit server permission; network/unknown state fails closed.
{body}try {{
{body}    const __freeTestPolicy = await window.v11CheckFreeTestPermission();
{body}    if (__freeTestPolicy?.enabled !== true) {{
{body}        window.alert('Silahkan hubungi admin untuk melakukan tes 082298316902');
{body}        return;
{body}    }}
{body}}} catch (__freeTestErr) {{
{body}    window.alert('Izin test 10 menit belum bisa diverifikasi. Test diblokir demi keamanan.\\nSilahkan hubungi admin untuk melakukan tes 082298316902');
{body}    return;
{body}}}
"""
    src = src[:m.start()] + declaration + guard + src[m.end():]
    path.write_text(src, encoding="utf-8")
    return True

# The Electron production page is index.html. Patch renderer.js too if its duplicate function exists.
patch_test_function(HTML, required=True)
patch_test_function(RENDERER, required=False)

cloud = CLOUD.read_text(encoding="utf-8")
if "window.v11CheckFreeTestPermission" not in cloud:
    anchor = "  const fp=u=>JSON.stringify("
    if cloud.count(anchor) != 1:
        raise SystemExit("v11-cloud.js permission-helper insertion anchor mismatch")
    helpers = r"""
  window.v11CheckFreeTestPermission=async function(){
    const c=read();
    if(!c||!c.token)throw new Error('PAIRING_REQUIRED');
    const d=await request('/device/test-policy',{token:c.token},{retries:1,timeoutMs:7000});
    if(!d||typeof d.enabled!=='boolean')throw new Error(d?.error||d?.message||'FREE_TEST_POLICY_UNAVAILABLE');
    return d;
  };
  window.v11GetDeviceIdentity=function(){
    const c=read()||{};
    return {deviceId:String(c.deviceId||''),clientId:String(c.clientId||''),orgId:String(c.orgId||'')};
  };
"""
    cloud = cloud.replace(anchor, helpers + anchor, 1)

old_app_markers = [
    "APP='V11.29.5-LOW-NOISE-LOG-FIX'",
    "APP='V11.29.4-ALERT-DELIVERY-RELIABILITY'",
    "APP='V11.29.3-SUPABASE-PAIR-RESUME'"
]
if "APP='" + BUILD + "'" not in cloud:
    found = [x for x in old_app_markers if x in cloud]
    if len(found) != 1:
        raise SystemExit("Unexpected v11-cloud.js app-version marker; refusing to bump unknown base")
    cloud = cloud.replace(found[0], "APP='" + BUILD + "'", 1)
CLOUD.write_text(cloud, encoding="utf-8")

html = HTML.read_text(encoding="utf-8")
if BUILD not in html:
    version_re = re.compile(r"(?m)^(?P<indent>[ \t]*)const APP_VERSION = '[^']+';")
    html, count = version_re.subn(lambda m: m.group("indent") + "const APP_VERSION = '" + BUILD + "';", html, count=1)
    if count != 1:
        raise SystemExit("Live index.html APP_VERSION marker mismatch")

# Run the target-PC shutdown timer locally (not on the server), with persisted deadline and rental guards.
shutdown_runtime = r"""
// V12.1.8: target-bound shutdown countdown lives on the paired Windows PC.
const __ANI_SHUTDOWN_KEY = 'ani_games_pc_local_shutdown_timer_v1';
let __aniShutdownTickHandle = null;
function __aniReadShutdownTimer() {
 try { const v = JSON.parse(localStorage.getItem(__ANI_SHUTDOWN_KEY) || 'null'); return v && typeof v === 'object' ? v : null; }
 catch (_) { return null; }
}
function __aniSaveShutdownTimer(v) {
 try { localStorage.setItem(__ANI_SHUTDOWN_KEY, JSON.stringify(v)); return true; } catch (_) { return false; }
}
function __aniShutdownIdentity() {
 try { return window.v11GetDeviceIdentity?.() || {}; } catch (_) { return {}; }
}
function __aniShutdownRentalBlocker() {
 if (typeof currentActiveCode !== 'undefined' && currentActiveCode) return 'Sesi ' + String(currentActiveCode) + ' masih aktif.';
 const paused = String(localStorage.getItem('billing_remote_paused_code') || '').trim();
 if (paused) return 'Sesi ' + paused + ' masih paused/terbuka.';
 return '';
}
function __aniShutdownFinishBlocked(state, message) {
 state.state = 'blocked_active_session'; state.updatedAt = new Date().toISOString(); state.message = message;
 __aniSaveShutdownTimer(state);
 if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle);
 __aniShutdownTickHandle = null;
 try { window.alert('Timer shutdown dibatalkan demi keamanan. ' + message); } catch (_) {}
 try { if (typeof writeSystemLog === 'function') writeSystemLog('Timer shutdown diblokir: ' + message); } catch (_) {}
}
function __aniShutdownTick() {
 const state = __aniReadShutdownTimer();
 if (!state || state.state !== 'scheduled') {
  if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle);
  __aniShutdownTickHandle = null; return;
 }
 const ident = __aniShutdownIdentity();
 if (!ident.deviceId || String(ident.deviceId) !== String(state.targetDeviceId)) {
  state.state='shutdown_failed'; state.updatedAt=new Date().toISOString(); state.message='Identitas PC berubah/tidak cocok; timer tidak dijalankan.';
  __aniSaveShutdownTimer(state); if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle); __aniShutdownTickHandle=null; return;
 }
 const deadline = Date.parse(state.deadlineAt || '');
 if (!Number.isFinite(deadline)) {
  state.state='shutdown_failed'; state.updatedAt=new Date().toISOString(); state.message='Deadline timer shutdown tidak valid.';
  __aniSaveShutdownTimer(state); if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle); __aniShutdownTickHandle=null; return;
 }
 if (deadline > Date.now()) return;
 if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle);
 __aniShutdownTickHandle = null;
 const blocker = __aniShutdownRentalBlocker();
 if (blocker) { __aniShutdownFinishBlocked(state, blocker); return; }
 state.state='shutdown_requested'; state.updatedAt=new Date().toISOString();
 state.message='Deadline selesai; permintaan shutdown Windows dikirim dari PC.';
 __aniSaveShutdownTimer(state);
 try {
  if (window.electronAPI && typeof window.electronAPI.powerAction === 'function') {
   window.electronAPI.powerAction('shutdown');
   try { if (typeof writeSystemLog === 'function') writeSystemLog('Timer shutdown Admin selesai; perintah Windows dikirim.'); } catch (_) {}
  } else {
   state.state='shutdown_failed'; state.message='Pengaman gagal: IPC powerAction tidak tersedia.';
   __aniSaveShutdownTimer(state); window.alert(state.message);
  }
 } catch (e) {
  state.state='shutdown_failed'; state.message='Permintaan shutdown gagal: ' + String(e?.message || e).slice(0,160);
  __aniSaveShutdownTimer(state); try { window.alert(state.message); } catch (_) {}
 }
}
function __aniStartShutdownTicker() {
 if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle);
 __aniShutdownTickHandle = setInterval(__aniShutdownTick, 1000); __aniShutdownTick();
}
async function __aniScheduleLocalShutdownTimer(payload) {
 const p = payload && typeof payload === 'object' ? payload : {}, ident = __aniShutdownIdentity();
 if (!ident.deviceId || String(p.targetDeviceId || '') !== String(ident.deviceId))
  return {ok:false,error:'SHUTDOWN_TARGET_ID_MISMATCH',message:'Perintah shutdown ditujukan ke PC lain; ditolak.'};
 const scheduleId = String(p.scheduleId || '').trim(), deadline = Date.parse(p.deadlineAt || '');
 if (p.scheduled !== true || !scheduleId || !Number.isFinite(deadline) || deadline <= Date.now() || deadline > Date.now() + 24*60*60*1000 + 30000)
  return {ok:false,error:'INVALID_SHUTDOWN_TIMER_PAYLOAD',message:'Data timer shutdown tidak valid atau di luar batas 24 jam.'};
 const blocker = __aniShutdownRentalBlocker();
 if (blocker) return {ok:false,error:'ACTIVE_RENTAL_BLOCKS_SHUTDOWN',message:'Shutdown diblokir demi keamanan. ' + blocker};
 const old = __aniReadShutdownTimer();
 if (old && old.state === 'scheduled' && String(old.scheduleId) !== scheduleId)
  return {ok:false,error:'SHUTDOWN_TIMER_ALREADY_ACTIVE',message:'Masih ada timer shutdown aktif. Batalkan timer lama terlebih dahulu.'};
 const next={state:'scheduled',scheduleId,deadlineAt:new Date(deadline).toISOString(),targetDeviceId:String(ident.deviceId),targetClientId:String(ident.clientId||''),updatedAt:new Date().toISOString(),source:'admin-command'};
 if (!__aniSaveShutdownTimer(next)) return {ok:false,error:'SHUTDOWN_TIMER_STORAGE_FAILED',message:'PC tidak dapat menyimpan timer shutdown secara lokal.'};
 __aniStartShutdownTicker();
 try { if (typeof writeSystemLog === 'function') writeSystemLog('Timer shutdown diterima dari Admin; deadline ' + next.deadlineAt + '.'); } catch (_) {}
 return {ok:true,state:'scheduled',scheduleId,deadlineAt:next.deadlineAt,targetDeviceId:next.targetDeviceId,message:'Timer disimpan pada PC target dan countdown berjalan secara lokal.'};
}
async function __aniCancelLocalShutdownTimer(payload) {
 const p=payload&&typeof payload==='object'?payload:{}, ident=__aniShutdownIdentity();
 if (!ident.deviceId || String(p.targetDeviceId||'')!==String(ident.deviceId))
  return {ok:false,error:'SHUTDOWN_TARGET_ID_MISMATCH',message:'Pembatalan timer ditujukan ke PC lain; ditolak.'};
 if (p.cancelScheduled !== true) return {ok:false,error:'INVALID_SHUTDOWN_TIMER_CANCEL_PAYLOAD',message:'Permintaan pembatalan timer tidak valid.'};
 const old=__aniReadShutdownTimer();
 if (!old || old.state!=='scheduled') return {ok:true,state:old?.state||'none',message:'Tidak ada timer shutdown aktif pada PC.'};
 if (p.scheduleId && String(p.scheduleId)!==String(old.scheduleId))
  return {ok:false,error:'SHUTDOWN_SCHEDULE_ID_MISMATCH',message:'ID timer berbeda; timer aktif tidak diubah.'};
 if (__aniShutdownTickHandle) clearInterval(__aniShutdownTickHandle); __aniShutdownTickHandle=null;
 old.state='canceled'; old.updatedAt=new Date().toISOString(); old.message='Timer shutdown dibatalkan oleh Admin.';
 __aniSaveShutdownTimer(old);
 try { if (typeof writeSystemLog === 'function') writeSystemLog('Timer shutdown dibatalkan oleh Admin.'); } catch (_) {}
 return {ok:true,state:'canceled',scheduleId:old.scheduleId,message:'Timer shutdown berhasil dibatalkan pada PC.'};
}
window.v11GetLocalShutdownTimerState = __aniReadShutdownTimer;
setTimeout(function(){ const s=__aniReadShutdownTimer(); if(s?.state==='scheduled') __aniStartShutdownTicker(); }, 5000);
"""
if "window.v11GetLocalShutdownTimerState" not in html:
    script_re = re.compile(r'<script\b(?![^>]*\bsrc\s*=)[^>]*>(.*?)</script\s*>', re.IGNORECASE | re.DOTALL)
    candidates = [m for m in script_re.finditer(html) if "function pauseSession" in m.group(1)]
    if len(candidates) != 1:
        raise SystemExit(f"Expected exactly one live inline script with pauseSession, found {len(candidates)}")
    m = candidates[0]
    js = m.group(1)
    if "window.v11ApplyRemoteCommand" not in js:
        raise SystemExit("Live remote command dispatcher missing; refusing to patch the wrong PC runtime")
    command_wrapper = r"""
(function __aniInstallRemoteCommandExtensions(){
 const original=window.v11ApplyRemoteCommand;
 if(typeof original!=='function')return false;
 if(original.__aniV128CommandExtensions)return true;
 const wrapped=async function(cmd,payload,...rest){
  const name=String(typeof cmd==='string'?cmd:(cmd?.command||cmd?.cmd||cmd?.type||'')).trim().toLowerCase();
  const data=payload&&typeof payload==='object'?payload:(cmd&&typeof cmd==='object'&&cmd.payload&&typeof cmd.payload==='object'?cmd.payload:{});
  if(name==='start_trial'){
   if(typeof currentActiveCode!=='undefined'&&currentActiveCode)return {ok:false,error:'SESSION_ALREADY_ACTIVE',message:'Sesi sudah aktif pada PC; test 10 menit tidak dimulai.'};
   try{
    await startTenMinuteTest();
    if(typeof currentActiveCode!=='undefined'&&String(currentActiveCode)===String(TEST_SESSION_CODE))return {ok:true,message:'Test 10 menit dimulai pada PC.',duration_seconds:600};
    return {ok:false,error:'FREE_TEST_DISABLED',message:'Silahkan hubungi admin untuk melakukan tes 082298316902'};
   }catch(e){return {ok:false,error:'FREE_TEST_START_FAILED',message:String(e?.message||e||'Test 10 menit gagal dimulai.')};}
  }
  if(name==='schedule_shutdown')return await __aniScheduleLocalShutdownTimer(data);
  if(name==='cancel_shutdown_timer')return await __aniCancelLocalShutdownTimer(data);
  return await original.apply(this,arguments);
 };
 wrapped.__aniV128CommandExtensions=true; window.v11ApplyRemoteCommand=wrapped; return true;
})();
"""
    html = html[:m.start(1)] + js + "\n" + shutdown_runtime + "\n" + command_wrapper + "\n" + html[m.end(1):]
    HTML.write_text(html, encoding="utf-8")

# Root Edge Function source is copied into the PC package; enforce the endpoint marker.
edge = EDGE.read_text(encoding="utf-8")
if 'p==="device/test-policy"' not in edge or 'rpc("device_free_test_policy"' not in edge:
    raise SystemExit("PC Edge Function source is missing the device/test-policy route")

# Match package, app footer, heartbeat identity and source version.
package=json.loads(PACKAGE.read_text(encoding="utf-8"))
lock=json.loads(LOCK.read_text(encoding="utf-8"))
if package.get("version") not in {"12.1.7","12.1.8"}:
    raise SystemExit(f"Unexpected package version for V12.1.8 patch: {package.get('version')}")
package["version"]="12.1.8"; lock["version"]="12.1.8"
if isinstance(lock.get("packages"),dict) and isinstance(lock["packages"].get(""),dict):
    lock["packages"][""]["version"]="12.1.8"
if isinstance(package.get("build"),dict): package["build"]["productName"]="AniGames Billing V12.1.8"
PACKAGE.write_text(json.dumps(package,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
LOCK.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
VERSION.write_text(BUILD+"\n",encoding="utf-8")

renderer_text=RENDERER.read_text(encoding="utf-8") if RENDERER.is_file() else ""
combined=HTML.read_text(encoding="utf-8")+"\n"+cloud+"\n"+edge+"\n"+renderer_text
for token in ["device/test-policy","device_free_test_policy","window.v11CheckFreeTestPermission",TEST_MARK,
              "window.v11GetLocalShutdownTimerState","schedule_shutdown","cancel_shutdown_timer",
              "SHUTDOWN_TARGET_ID_MISMATCH","FREE_TEST_DISABLED","082298316902"]:
    if token not in combined: raise SystemExit("V12.1.8 feature marker missing: "+token)
if "window.v11ApplyRemoteCommand=wrapped" not in combined:
    raise SystemExit("Remote-command wrapper was not installed into the Electron runtime")
if "renderer.js is not loaded by Electron." not in HTML.read_text(encoding="utf-8"):
    raise SystemExit("Electron live-runtime marker missing; test gate must remain in index.html")
print("PASS: V12.1.8 trial permission preflight + target-bound local shutdown timer + cancel command.")
