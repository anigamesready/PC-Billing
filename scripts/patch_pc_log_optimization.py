from pathlib import Path
import json
import re

ROOT = Path(".")
renderer_path = ROOT / "renderer.js"
cloud_path = ROOT / "v11-cloud.js"
edge_path = ROOT / "supabase/functions/ani-games-api/index.ts"
renderer = renderer_path.read_text(encoding="utf-8")
cloud = cloud_path.read_text(encoding="utf-8")
edge = edge_path.read_text(encoding="utf-8")

# Deduplicate identical adjacent local log events; bound the ring buffer to 100 records.
old_log = re.compile(r"        function writeSystemLog\(message, level = 'INFO'\) \{[\s\S]*?\n        \}\n\n        function persistActiveSession")
new_log = """        function writeSystemLog(message, level = 'INFO') {
            try {
                const logs = JSON.parse(localStorage.getItem(SYSTEM_LOG_KEY) || '[]');
                const text = String(message || '').slice(0, 500);
                const now = Date.now();
                const last = logs.length ? logs[logs.length - 1] : null;
                if (last && last.level === level && last.message === text && now - Date.parse(last.time || 0) <= 60000) {
                    last.count = (Number(last.count) || 1) + 1;
                    last.time = new Date(now).toISOString();
                } else {
                    logs.push({ time: new Date(now).toISOString(), level, message: text, count: 1 });
                }
                while (logs.length > 100) logs.shift();
                localStorage.setItem(SYSTEM_LOG_KEY, JSON.stringify(logs));
            } catch (e) { console.warn('Gagal menyimpan log sistem:', e); }
        }

        function persistActiveSession"""
if "last.count = (Number(last.count) || 1) + 1" not in renderer:
    renderer, n = old_log.subn(new_log, renderer, count=1)
    if n != 1:
        raise SystemExit("writeSystemLog anchor mismatch; refusing to patch")

# Routine automatic backup success is not actionable; keep all backup errors and manual success logs.
auto_backup_line = "                    writeSystemLog((manual ? 'Backup manual' : 'Backup otomatis') + ' berhasil.');"
if auto_backup_line in renderer:
    renderer = renderer.replace(auto_backup_line, "                    if (manual) writeSystemLog('Backup manual berhasil.');", 1)
elif "if (manual) writeSystemLog('Backup manual berhasil.');" not in renderer:
    raise SystemExit("auto backup log anchor mismatch; refusing to patch")

# Timer expiry currently logs here and then pauseSession logs a second generic stop line.
stop_log = "            if (endedCode) writeSystemLog(" + chr(96) + "Sesi " + chr(36) + "{endedCode} dihentikan/ditutup. Sisa waktu tersimpan." + chr(96) + ");"
stop_replacement = """            const endedUser = endedCode ? dbUsers[endedCode] : null;
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
if "window.v11EmitAdminAlert?.(eventType, message" not in renderer:
    if renderer.count(stop_log) != 1:
        raise SystemExit("pauseSession log anchor mismatch; refusing to patch")
    renderer = renderer.replace(stop_log, stop_replacement, 1)

# Commands issued from Admin Android intentionally suppress cloud echo while applying the
# command locally. Stop/logout are user-visible rental end events, so emit exactly one
# explicit alert after the local timer has been stopped.
remote_stop_anchor = """                if (cmd === 'stop' || cmd === 'logout') {
                    localStorage.removeItem('billing_remote_paused_code');
                    if(currentActiveCode) { window.v11SyncApplying=true; try{pauseSession(false);}finally{window.v11SyncApplying=false;} }
                    else saveDB();
                    return { ok: true, message: 'Sesi dihentikan/dikeluarkan.' };
                }"""
remote_stop_replacement = """                if (cmd === 'stop' || cmd === 'logout') {
                    localStorage.removeItem('billing_remote_paused_code');
                    if(currentActiveCode) {
                        const stoppedCode = currentActiveCode;
                        window.v11SyncApplying=true; try{pauseSession(false);}finally{window.v11SyncApplying=false;}
                        if (stoppedCode !== TEST_SESSION_CODE) {
                            const stoppedUser = dbUsers[stoppedCode];
                            window.v11EmitAdminAlert?.('session_stopped', 'Rental ' + stoppedCode + ' dihentikan manual dari Admin Android.', {
                                code: stoppedCode,
                                remainingSeconds: Math.max(0, Number(stoppedUser?.remainingSeconds) || 0)
                            });
                        }
                    } else saveDB();
                    return { ok: true, message: 'Sesi dihentikan/dikeluarkan.' };
                }"""
if "dihentikan manual dari Admin Android" not in renderer:
    if renderer.count(remote_stop_anchor) != 1:
        raise SystemExit("Admin remote stop/logout anchor mismatch; refusing to patch")
    renderer = renderer.replace(remote_stop_anchor, remote_stop_replacement, 1)

renderer_path.write_text(renderer, encoding="utf-8")

# IMPORTANT: Electron actually executes index.html; renderer.js is not loaded.
# Apply the same bounded/coalesced log policy to the live runtime too.
live_html_path = ROOT / "index.html"
live_html = live_html_path.read_text(encoding="utf-8")
if "last.count = (Number(last.count) || 1) + 1" not in live_html:
    live_html, n = old_log.subn(new_log, live_html, count=1)
    if n != 1:
        raise SystemExit("Live index.html writeSystemLog anchor mismatch; refusing to build without runtime log optimization")

if auto_backup_line in live_html:
    live_html = live_html.replace(auto_backup_line, "                    if (manual) writeSystemLog('Backup manual berhasil.');", 1)
elif "if (manual) writeSystemLog('Backup manual berhasil.');" not in live_html:
    raise SystemExit("Live index.html auto-backup log anchor mismatch; refusing to patch")

if "last.count = (Number(last.count) || 1) + 1" not in live_html or "if (manual) writeSystemLog('Backup manual berhasil.');" not in live_html:
    raise SystemExit("Live runtime log optimization check failed")
live_html_path.write_text(live_html, encoding="utf-8")

# Durable, bounded, idempotent outbox for only rental-expiry and manual-stop alerts.
if "function flushAdminAlerts()" not in cloud:
    cloud_anchor = "  const fp=u=>JSON.stringify("
    if cloud.count(cloud_anchor) != 1:
        raise SystemExit("cloud function insertion anchor mismatch; refusing to patch")
    alert_code = """  const ALERT_OUTBOX_KEY='billing_v11_admin_alert_outbox';
  let alertBusy=false;
  const alertQueue=()=>{try{return JSON.parse(localStorage.getItem(ALERT_OUTBOX_KEY)||'[]')}catch(_){return[]}};
  const saveAlertQueue=q=>localStorage.setItem(ALERT_OUTBOX_KEY,JSON.stringify(q.slice(-100)));
  window.v11EmitAdminAlert=function(eventType,message,payload={}){
    const type=String(eventType||'');
    if(!['session_expired','session_stopped'].includes(type))return;
    const text=String(message||'').trim().slice(0,240);
    if(!text)return;
    const q=alertQueue();
    if(q.some(x=>x.eventType===type&&x.payload?.code===payload?.code&&x.occurredAt&&Date.now()-Date.parse(x.occurredAt)<60000))return;
    q.push({sourceEventId:crypto.randomUUID(),occurredAt:new Date().toISOString(),eventType:type,message:text,payload:payload&&typeof payload==='object'?payload:{}});
    saveAlertQueue(q);
    flushAdminAlerts();
  };
  async function flushAdminAlerts(){
    if(alertBusy)return;
    const cfg=read();if(!cfg.token)return;
    alertBusy=true;
    try{
      let pending=alertQueue();
      for(const item of pending.slice(0,5)){
        const reply=await request('/device/alert',{token:cfg.token,eventId:item.sourceEventId,eventType:item.eventType,message:item.message,payload:item.payload,occurredAt:item.occurredAt},{retries:1,timeoutMs:7000});
        if(!reply?.ok||!reply?.accepted)break;
        pending=pending.filter(x=>x.sourceEventId!==item.sourceEventId);
        saveAlertQueue(pending);
      }
    }catch(_){
      // Retry from the durable outbox on a later heartbeat; do not write a log per retry.
    }finally{alertBusy=false}
  }
"""
    cloud = cloud.replace(cloud_anchor, alert_code + cloud_anchor, 1)

heartbeat_anchor = "async function heartbeat(){if(resumeCloudAuthoritative)return;const c=read();if(!c.token)return;try{"
if "if(alertQueue().length)flushAdminAlerts();" not in cloud:
    if cloud.count(heartbeat_anchor) != 1:
        raise SystemExit("heartbeat alert retry anchor mismatch; refusing to patch")
    cloud = cloud.replace(heartbeat_anchor, "async function heartbeat(){if(resumeCloudAuthoritative)return;const c=read();if(!c.token)return;if(alertQueue().length)flushAdminAlerts();try{", 1)

# heartbeat() already calls pullNow() on every successful 15-second heartbeat.
# Avoid a second overlapping pull on the separate 30-second maintenance timer.
interval_old = "setInterval(()=>{syncNow();pullNow()},30000)"
interval_with_alerts = "setInterval(()=>{syncNow();pullNow();flushAdminAlerts()},30000)"
interval_optimized = "setInterval(()=>{syncNow();flushAdminAlerts()},30000)"
if interval_optimized not in cloud:
    if interval_with_alerts in cloud:
        cloud = cloud.replace(interval_with_alerts, interval_optimized, 1)
    elif interval_old in cloud:
        cloud = cloud.replace(interval_old, interval_optimized, 1)
    else:
        raise SystemExit("cloud retry timer anchor mismatch; refusing to patch")
if "setInterval(()=>{syncNow();pullNow();flushAdminAlerts()},30000)" in cloud:
    raise SystemExit("Redundant 30-second pull timer remains")
cloud_path.write_text(cloud, encoding="utf-8")

# Edge Function route passes events through to the SQL RPC, which checks device token and deduplicates IDs.
if 'device/alert' not in edge:
    edge_anchor = '    if (path === "device/ack") {'
    if edge.count(edge_anchor) != 1:
        raise SystemExit("Edge Function route anchor mismatch; refusing to patch")
    alert_route = """    if (path === "device/alert") {
      const token = String(body.token || "");
      const eventId = String(body.eventId || "");
      const eventType = String(body.eventType || "");
      const message = String(body.message || "").slice(0, 240);
      if (!token || !eventId || !message) return json(400, { ok: false, error: "alert_fields_required" });
      if (!["session_expired", "session_stopped"].includes(eventType)) return json(400, { ok: false, error: "invalid_alert_type" });
      const saved = await rpc("device_emit_admin_alert", {
        p_token: token,
        p_event_id: eventId,
        p_event_type: eventType,
        p_message: message,
        p_payload: body.payload && typeof body.payload === "object" ? body.payload : {},
        p_occurred_at: body.occurredAt || new Date().toISOString()
      });
      return json(200, { ok: true, ...saved });
    }
"""
    edge = edge.replace(edge_anchor, alert_route + edge_anchor, 1)
edge_path.write_text(edge, encoding="utf-8")

# Keep package and lockfile versions synchronized.
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if package.get("version") == "12.1.1":
    package["version"] = "12.1.2"
elif package.get("version") != "12.1.2":
    raise SystemExit("Unexpected package.json version; refusing to bump blindly")
lock["version"] = "12.1.2"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.1.2"
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
(ROOT / "VERSION.txt").write_text("V12.1.2-LOG-OPTIMIZATION-ANDROID-ALERTS\n", encoding="utf-8")
print("Patched log deduplication, low-noise backup logging, event-driven rental alerts, durable outbox, and device/alert Edge Function route.")
