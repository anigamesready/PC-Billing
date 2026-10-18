from pathlib import Path
import json

ROOT = Path(".")
html_path = ROOT / "index.html"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
version_path = ROOT / "VERSION.txt"

html = html_path.read_text(encoding="utf-8")
cloud_path = ROOT / "v11-cloud.js"
cloud = cloud_path.read_text(encoding="utf-8")

# Electron's BrowserWindow loads index.html directly. renderer.js is not loaded by
# this project, so alert emitters must be applied and verified in index.html.
if "renderer.js is not loaded by Electron." not in html:
    raise SystemExit("Expected live renderer marker is missing from index.html; refusing to patch the wrong runtime.")

# Make the visible in-app footer identify this actual build, not the stale V11.21 label.
version_lines = [line for line in html.splitlines() if "const APP_VERSION =" in line]
if len(version_lines) != 1:
    raise SystemExit(f"Expected one APP_VERSION constant in live index.html, found {len(version_lines)}")
old_version_line = version_lines[0]
indent = old_version_line[:old_version_line.index("const APP_VERSION =")]
new_version_line = indent + "const APP_VERSION = 'V12.1.6-ALERT-DELIVERY-RELIABILITY-FIX';"
html = html.replace(old_version_line, new_version_line, 1)

# Timer expiry and the local end-session button both pass through pauseSession().
if "window.v11EmitAdminAlert?.(eventType, message" not in html:
    old_lines = [line for line in html.splitlines() if "if (endedCode) writeSystemLog(" in line]
    if len(old_lines) != 1:
        raise SystemExit(f"pauseSession log anchor expected once in live index.html, found {len(old_lines)}; refusing to patch")
    old_line = old_lines[0]
    replacement = """            const endedUser = endedCode ? dbUsers[endedCode] : null;
            const expiredByTimer = Boolean(endedCode && Number(endedUser?.remainingSeconds || 0) <= 0);
            if (endedCode && !expiredByTimer) writeSystemLog('Sesi ' + endedCode + ' dihentikan/ditutup. Sisa waktu tersimpan.');
            if (endedCode && endedCode !== TEST_SESSION_CODE && !window.v11SyncApplying) {
                const eventType = expiredByTimer ? 'session_expired' : 'session_stopped';
                const message = expiredByTimer
                    ? ('Rental ' + endedCode + ' selesai karena waktu habis.')
                    : ('Rental ' + endedCode + ' dihentikan manual.');
                window.v11EmitAdminAlert?.(eventType, message, {
                    code: endedCode,
                    remainingSeconds: Math.max(0, Number(endedUser?.remainingSeconds) || 0)
                });
            }"""
    html = html.replace(old_line, replacement, 1)

# A remote stop/logout is intentionally marked as a cloud-applied command while
# stopping the local timer. Emit one explicit event after leaving that suppression
# window, otherwise the generic pauseSession guard hides the Admin-initiated stop.
remote_stop_anchor = """            if (cmd === 'stop' || cmd === 'logout') {
                localStorage.removeItem('billing_remote_paused_code');
                window.v11SyncApplying = true;
                try { if (currentActiveCode) pauseSession(false); else saveDB(); } finally { window.v11SyncApplying = false; }
                return {ok:true, message:'Sesi dihentikan/dikeluarkan.'};
            }"""
remote_stop_replacement = """            if (cmd === 'stop' || cmd === 'logout') {
                localStorage.removeItem('billing_remote_paused_code');
                if (currentActiveCode) {
                    const stoppedCode = currentActiveCode;
                    window.v11SyncApplying = true;
                    try { pauseSession(false); } finally { window.v11SyncApplying = false; }
                    if (stoppedCode !== TEST_SESSION_CODE) {
                        const stoppedUser = dbUsers[stoppedCode];
                        window.v11EmitAdminAlert?.('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {
                            code: stoppedCode,
                            remainingSeconds: Math.max(0, Number(stoppedUser?.remainingSeconds) || 0)
                        });
                    }
                } else {
                    saveDB();
                }
                return {ok:true, message:'Sesi dihentikan/dikeluarkan.'};
            }"""
if "dihentikan manual dari Admin Android." not in html:
    if html.count(remote_stop_anchor) != 1:
        raise SystemExit("Live stop/logout command anchor expected once in index.html; refusing to patch")
    html = html.replace(remote_stop_anchor, remote_stop_replacement, 1)


# Harden the alert outbox: make events durable and use bounded retry with diagnostics.
if "window.v11GetAdminAlertStatus" not in cloud:
    start = cloud.find("  const ALERT_OUTBOX_KEY='billing_v11_admin_alert_outbox';")
    end = cloud.find("  const fp=u=>", start)
    if start < 0 or end < 0:
        raise SystemExit("Admin alert outbox anchor mismatch; refusing to patch.")
    cloud_alert = r'''  const ALERT_OUTBOX_KEY='billing_v11_admin_alert_outbox';
  let alertBusy=false,alertFailureCount=0,alertNextRetryAt=0,alertLastDiagnosticAt=0,alertMemoryQueue=[];
  const alertQueue=()=>{
    let saved=[];
    try{const parsed=JSON.parse(localStorage.getItem(ALERT_OUTBOX_KEY)||'[]');if(Array.isArray(parsed))saved=parsed;}catch(_){}
    const ids=new Set(saved.map(x=>String(x?.sourceEventId||'')));
    return saved.concat(alertMemoryQueue.filter(x=>!ids.has(String(x?.sourceEventId||''))));
  };
  const saveAlertQueue=q=>{
    const normalized=Array.isArray(q)?q.filter(x=>x&&typeof x==='object').slice(-250):[];
    try{localStorage.setItem(ALERT_OUTBOX_KEY,JSON.stringify(normalized));alertMemoryQueue=[];return true;}
    catch(e){alertMemoryQueue=normalized;return false;}
  };
  function alertId(){try{if(window.crypto&&typeof window.crypto.randomUUID==='function')return window.crypto.randomUUID();}catch(_){}return 'alert-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,14)}
  function alertDiagnostic(message,detail){
    const now=Date.now();if(now-alertLastDiagnosticAt<60000)return;alertLastDiagnosticAt=now;
    const safe=String(message||'Pengiriman alert tertunda').slice(0,180);
    console.warn('[AniGames alert delivery]',safe,detail||'');
    const el=document.getElementById('v11-cloud-status');if(el){el.title=safe+(detail?' • '+String(detail).slice(0,180):'');el.dataset.alertDelivery='pending';}
    status('🔔 ALERT RENTAL TERTUNDA • '+safe);
  }
  function scheduleAlertRetry(){alertNextRetryAt=Date.now()+Math.min(120000,4000*Math.pow(2,Math.min(Math.max(0,alertFailureCount-1),5)));}
  window.v11GetAdminAlertStatus=function(){return {queued:alertQueue().length,retrying:Date.now()<alertNextRetryAt,nextRetryAt:alertNextRetryAt,lastErrorAt:alertLastDiagnosticAt}};
  window.v11EmitAdminAlert=function(eventType,message,payload={}){
    const type=String(eventType||'');if(!['session_expired','session_stopped'].includes(type))return false;
    const text=String(message||'').trim().slice(0,240);if(!text)return false;
    const safePayload=payload&&typeof payload==='object'?payload:{},q=alertQueue();
    if(q.some(x=>x.eventType===type&&x.payload?.code===safePayload.code&&x.occurredAt&&Date.now()-Date.parse(x.occurredAt)<60000))return true;
    if(q.length>=250){alertDiagnostic('Antrean alert penuh; alert baru ditahan agar event lama tidak terhapus.','queue_limit=250');return false;}
    q.push({sourceEventId:alertId(),occurredAt:new Date().toISOString(),eventType:type,message:text,payload:safePayload});
    const stored=saveAlertQueue(q);if(!stored)alertDiagnostic('Penyimpanan lokal terbatas; alert ditahan sementara di memori.','localStorage_unavailable');
    alertFailureCount=0;alertNextRetryAt=0;void flushAdminAlerts();return true;
  };
  async function flushAdminAlerts(){
    if(alertBusy||Date.now()<alertNextRetryAt)return;
    const cfg=read();if(!cfg.token)return;const initial=alertQueue();if(!initial.length)return;
    alertBusy=true;let delivered=0;
    try{
      for(const item of initial.slice(0,5)){
        let reply;
        try{reply=await request('/device/alert',{token:cfg.token,eventId:item.sourceEventId,eventType:item.eventType,message:item.message,payload:item.payload,occurredAt:item.occurredAt},{retries:1,timeoutMs:7000});}
        catch(e){alertFailureCount++;scheduleAlertRetry();alertDiagnostic('Gagal mengirim alert ke Supabase; antrean tetap disimpan.',String(e?.message||e||'network_error'));return;}
        if(!reply?.ok||reply?.accepted!==true){alertFailureCount++;scheduleAlertRetry();alertDiagnostic('Server belum mengonfirmasi alert; antrean tetap disimpan.',String(reply?.error||reply?.message||'missing accepted=true'));return;}
        saveAlertQueue(alertQueue().filter(x=>String(x.sourceEventId)!==String(item.sourceEventId)));delivered++;
      }
      if(delivered){alertFailureCount=0;alertNextRetryAt=0;const el=document.getElementById('v11-cloud-status');if(el){el.dataset.alertDelivery='sent';el.title='Alert rental terkirim: '+delivered;}}
    }catch(e){alertFailureCount++;scheduleAlertRetry();alertDiagnostic('Error internal saat mengelola antrean alert; data tetap dipertahankan.',String(e?.message||e));}
    finally{alertBusy=false;}
  }
'''
    cloud = cloud[:start] + cloud_alert + cloud[end:]

# Durable fallback for session-end events if the cloud sender is unavailable at emit time.
helper_anchor = "        function pauseSession(showNotif = false) {"
helper = r'''        function emitRentalAdminAlert(eventType, message, payload = {}) {
            const type=String(eventType||''),text=String(message||'').trim().slice(0,240);
            if(!['session_expired','session_stopped'].includes(type)||!text)return false;
            try{
                if(typeof window.v11EmitAdminAlert==='function'){
                    const accepted=window.v11EmitAdminAlert(type,text,payload||{});
                    if(accepted!==false)return true;
                }
            }catch(e){console.warn('[AniGames alert delivery] Cloud sender threw; using local outbox fallback.',e);}
            try{
                const key='billing_v11_admin_alert_outbox';let queue=[];
                try{const parsed=JSON.parse(localStorage.getItem(key)||'[]');if(Array.isArray(parsed))queue=parsed;}catch(_){}
                const code=String(payload?.code||'');
                if(queue.some(x=>x?.eventType===type&&String(x?.payload?.code||'')===code&&Date.now()-Date.parse(x?.occurredAt||0)<60000))return true;
                if(queue.length>=250){console.error('[AniGames alert delivery] Outbox full; refusing to discard older alerts.');return false;}
                let id;try{id=crypto.randomUUID();}catch(_){id='alert-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,14);}
                queue.push({sourceEventId:id,occurredAt:new Date().toISOString(),eventType:type,message:text,payload:payload&&typeof payload==='object'?payload:{}});
                localStorage.setItem(key,JSON.stringify(queue.slice(-250)));
                console.warn('[AniGames alert delivery] Event saved in local outbox; cloud sender unavailable at emit time.',type);return true;
            }catch(e){console.error('[AniGames alert delivery] Could not persist session-end alert.',e);return false;}
        }

'''
if "function emitRentalAdminAlert(" not in html:
    if html.count(helper_anchor)!=1: raise SystemExit("pauseSession anchor mismatch; refusing to patch.")
    html=html.replace(helper_anchor,helper+helper_anchor,1)
html=html.replace("window.v11EmitAdminAlert?.(eventType, message, {","emitRentalAdminAlert(eventType, message, {")
html=html.replace("window.v11EmitAdminAlert?.('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {","emitRentalAdminAlert('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {")

# Guard against a green build that only patched the unused renderer.js again.
for required in (
    "function pauseSession(",
    "const APP_VERSION = 'V12.1.6-ALERT-DELIVERY-RELIABILITY-FIX';",
    "emitRentalAdminAlert(eventType, message",
    "dihentikan manual dari Admin Android.",
    "session_expired",
    "session_stopped",
    '<script src="v11-cloud.js"></script>',
):
    if required not in html:
        raise SystemExit("Live index.html regression token missing: " + required)
if html.count("emitRentalAdminAlert(eventType, message") != 1:
    raise SystemExit("Expected exactly one event-driven pauseSession alert call in live index.html")
if html.count("dihentikan manual dari Admin Android.") != 1:
    raise SystemExit("Expected exactly one explicit Admin stop/logout alert in live index.html")

package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if package.get("version") != "12.1.4":
    raise SystemExit("Expected PC baseline 12.1.4 after existing patches; refusing to bump blindly")
if lock.get("version") != "12.1.4":
    raise SystemExit("Unexpected package-lock version; refusing to bump blindly")
package["version"] = "12.1.6"
lock["version"] = "12.1.6"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.1.6"

cloud_path.write_text(cloud, encoding="utf-8")
html_path.write_text(html, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text("V12.1.6-ALERT-DELIVERY-RELIABILITY-FIX\n", encoding="utf-8")
print("PASS: patched the actual Electron index.html runtime for timer expiry, local stop, and Admin stop/logout alerts; PC version 12.1.6.")
