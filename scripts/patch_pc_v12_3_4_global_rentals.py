from pathlib import Path
import json
import re

root = Path(".")
index_path = root / "index.html"
cloud_path = root / "v11-cloud.js"
package_path = root / "package.json"
version_path = root / "VERSION.txt"
main_path = root / "main.js"

index = index_path.read_text(encoding="utf-8")
cloud = cloud_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))

BASE = "V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG"
NEW = "V12.3.4-GLOBAL-RENTAL-DB-FIRST"
if BASE not in index or BASE not in cloud:
    raise SystemExit("Unexpected PC Billing base; V12.3.3 source marker missing.")
if package.get("version") != "12.3.3":
    raise SystemExit("Unexpected package version; expected 12.3.3.")

# Online code checks are on-demand; the first pull must never populate a full rental table.
old_full = re.compile(r"async function fullRentalSnapshot\(options=\{\}\)\{.*?\}\s*\n\s*window\.v11FullRentalSnapshot=fullRentalSnapshot;", re.S)
new_full = r"""async function fullRentalSnapshot(options={}){
 const c=read();if(!c.token)return {ok:false,message:'Belum terhubung Cloud.'};
 try{
  let cursor=localStorage.getItem(SYNC_CURSOR_KEY);
  if(!cursor){const d=await request('/device/sync-cursor',{token:c.token},{retries:2,timeoutMs:7000});if(!d?.cursor)throw new Error('Cursor DB tidak valid.');cursor=d.cursor;localStorage.setItem(SYNC_CURSOR_KEY,cursor);}
  status('ONLINE • rental dimuat per kode dari DB; tidak memuat tabel penuh.');
  return {ok:true,count:0,cursor:cursor,fullSnapshot:false};
 }catch(e){status('DB belum bisa dicek • '+(e?.message||'gagal'));return {ok:false,message:e?.message||'gagal'};}
}
window.v11FullRentalSnapshot=fullRentalSnapshot;"""
cloud, n = old_full.subn(new_full, cloud, count=1)
if n != 1:
    raise SystemExit("fullRentalSnapshot anchor mismatch; refusing to patch")

pull_anchor = "const cursor=localStorage.getItem(SYNC_CURSOR_KEY);const d=await request('/device/pull'"
pull_replacement = "let cursor=localStorage.getItem(SYNC_CURSOR_KEY);if(!cursor){const seed=await request('/device/sync-cursor',{token:c.token},{retries:2,timeoutMs:7000});cursor=seed?.cursor||null;if(cursor)localStorage.setItem(SYNC_CURSOR_KEY,cursor);status('ONLINE • sinkronisasi delta siap; tabel rental tidak diunduh.');return;}const d=await request('/device/pull'"
if cloud.count(pull_anchor) != 1:
    raise SystemExit("Incremental pull anchor mismatch; refusing to patch")
cloud = cloud.replace(pull_anchor, pull_replacement, 1)

# Add durable conflict/session outboxes and global account lookup/session calls.
identity_anchor = "  window.v11GetDeviceIdentity=function(){const c=read()||{};return {deviceId:String(c.deviceId||''),clientId:String(c.clientId||''),orgId:String(c.orgId||'')}};\n"
helpers = identity_anchor + r"""
  const RENTAL_CONFLICT_KEY='billing_v11_rental_sync_conflicts';
  const SESSION_OUTBOX_KEY='billing_v11_session_outbox';
  const PREAUTH_KEY='billing_v12_rental_preauth_code';
  const OFFLINE_PREAUTH_GRACE_MS=30*60*1000;
  function readRentalConflicts(){try{const v=JSON.parse(localStorage.getItem(RENTAL_CONFLICT_KEY)||'[]');return Array.isArray(v)?v:[]}catch(_){return []}}
  function saveRentalConflicts(v){try{localStorage.setItem(RENTAL_CONFLICT_KEY,JSON.stringify((Array.isArray(v)?v:[]).slice(-250)));return true}catch(_){return false}}
  function readSessionOutbox(){try{const v=JSON.parse(localStorage.getItem(SESSION_OUTBOX_KEY)||'[]');return Array.isArray(v)?v:[]}catch(_){return []}}
  function saveSessionOutbox(v){try{localStorage.setItem(SESSION_OUTBOX_KEY,JSON.stringify((Array.isArray(v)?v:[]).slice(-100)));return true}catch(_){return false}}
  function rentalEventId(){try{if(window.crypto&&typeof window.crypto.randomUUID==='function')return window.crypto.randomUUID()}catch(_){}return 'rental-'+Date.now().toString(36)+'-'+Math.random().toString(36).slice(2,12)}
  function persistRentalUsers(users){suppressQueue=true;window.v11SyncApplying=true;try{window.v11PersistPulledUsers?.(users);localStorage.setItem('billing_db_users',JSON.stringify(users))}catch(_){}finally{suppressQueue=false;window.v11SyncApplying=false}}
  function apiBusinessError(d){const e=new Error(String(d?.error||d?.message||'DB_RENTAL_REQUEST_FAILED'));e.status=/RENTAL_NOT_FOUND/.test(e.message)?404:/RENTAL_ACTIVE_ON_OTHER_PC|RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC|RENTAL_HAS_OFFLINE_LEASE|ACTIVE_SESSION_EXISTS/.test(e.message)?409:/INVALID_DEVICE_TOKEN/.test(e.message)?401:/RENTAL_NOT_ACTIVE|RENTAL_EXPIRED|RENTAL_TIME_EXHAUSTED|RENTAL_CODE_INVALID/.test(e.message)?403:400;e.retryable=false;return e}
  function onlineRetryable(e){return !e?.status||e?.retryable===true||e?.status===408||e?.status===425||e?.status===429||e?.status>=500}
  function offlineLeaseValid(u){
    const cfg=read(),identity=window.v11GetDeviceIdentity?.()||{};
    const until=Date.parse(u?.offlineLeaseUntil||u?.offline_lease_until||'');
    const leaseDevice=String(u?.offlineLeaseDeviceId||u?.offline_lease_device_id||'');
    const left=Math.floor((until-Date.now())/1000);
    const needed=Math.max(0,Number(u?.remainingSeconds)||0);
    return Boolean(cfg?.token&&identity.deviceId&&leaseDevice===String(identity.deviceId)&&Number.isFinite(until)&&left>0&&left>=needed);
  }
  async function v11LookupRentalCode(code){
    const c=String(code||'').trim().toUpperCase();if(!c)throw new Error('KODE_KOSONG');
    const cfg=read();if(!cfg?.token)throw new Error('PAIRING_REQUIRED');
    const reply=await request('/device/rental/lookup',{token:cfg.token,code:c},{retries:1,timeoutMs:7000});
    if(reply?.ok!==true)throw apiBusinessError(reply);
    const users=window.v11GetUsers?.()||{},old=users[c]||{};
    if(old.localCreation&&!old.cloudUpdatedAt&&String(old.cloudAccountId||'')!==String(reply.id||'')){
      old.offlineSyncConflict=true;old.offlinePending=true;users[c]=old;persistRentalUsers(users);
      throw new Error('CODE_ALREADY_EXISTS_IN_SHARED_DB');
    }
    const active=window.v11GetActiveCode?.()===c;
    users[c]={
      ...old,cloudAccountId:String(reply.id||''),category:reply.category||old.category||'reguler',
      expiryDate:reply.expiry_at||'',clientLabel:reply.client_label||'',
      remainingSeconds:active?Math.max(0,Number(old.remainingSeconds)||0):Math.max(0,Number(reply.remaining_seconds)||0),
      cloudUpdatedAt:reply.updated_at||new Date().toISOString(),
      offlineLeaseUntil:reply.offline_lease_until||'',offlineLeaseDeviceId:String(reply.device_id||''),
      offlinePending:false,offlineSyncConflict:false,offlineUnverified:false
    };
    persistRentalUsers(users);localStorage.setItem(PREAUTH_KEY,c);
    return {ok:true,user:users[c],leaseUntil:users[c].offlineLeaseUntil,deviceId:users[c].offlineLeaseDeviceId};
  }
  async function v11StartRentalSession(code){
    const c=String(code||'').trim().toUpperCase();if(!c)return {ok:false,message:'Kode rental kosong.'};
    let users=window.v11GetUsers?.()||{},u=users[c]||{},cfg=read();
    if(u.offlineSyncConflict)return {ok:false,message:'Kode rental lokal bentrok dengan data DB. Data lokal dipertahankan; admin perlu memeriksa konflik kode.'};
    if(u.localCreation&&!u.cloudUpdatedAt&&cfg?.token){
      try{await syncNow()}catch(_){}
      users=window.v11GetUsers?.()||{};u=users[c]||u;
      if(u.offlineSyncConflict)return {ok:false,message:'Kode rental offline bentrok dengan data DB. Data lokal tidak ditimpa.'};
    }
    if(cfg?.token){
      try{
        const lookup=await v11LookupRentalCode(c);u=lookup.user;
        const d=await request('/device/session/start',{token:cfg.token,code:c,sourceEventId:rentalEventId()},{retries:1,timeoutMs:7000});
        if(d?.ok!==true)throw apiBusinessError(d);
        users=window.v11GetUsers?.()||{};u=users[c]||u;
        u.remainingSeconds=Math.max(0,Number(d.remaining_seconds)||0);
        u.serverSessionId=String(d.session_id||'');u.offlineUnverified=false;
        persistRentalUsers(users);
        return {ok:true,remainingSeconds:u.remainingSeconds,deadlineAt:d.deadline_at||null,offline:false,user:u,sessionId:d.session_id||null};
      }catch(e){
        users=window.v11GetUsers?.()||{};u=users[c]||u;
        if(!onlineRetryable(e))return {ok:false,message:/RENTAL_NOT_FOUND/.test(String(e.message))?'Kode rental tidak ditemukan di DB.':(/RENTAL_ACTIVE_ON_OTHER_PC|RENTAL_OFFLINE_LEASE_HELD_BY_OTHER_PC/.test(String(e.message))?'Akun sedang digunakan/direservasi PC lain.':String(e.message||'Akses rental ditolak.'))};
        if(offlineLeaseValid(u)){
          const until=Date.parse(u.offlineLeaseUntil||u.offline_lease_until),left=Math.floor((until-Date.now())/1000),remain=Math.min(Math.max(0,Number(u.remainingSeconds)||0),left);
          if(remain>0){u.remainingSeconds=remain;u.offlineUnverified=false;persistRentalUsers(users);return {ok:true,remainingSeconds:remain,offline:true,offlineUnverified:false,user:u,message:'Sesi dimulai memakai izin offline dari DB.'}}
        }
        if(!u.cloudUpdatedAt&&!u.offlineSyncConflict){
          const remain=Math.max(0,Number(u.remainingSeconds)||0);
          if(remain>0){u.offlinePending=true;u.offlineUnverified=true;persistRentalUsers(users);return {ok:true,remainingSeconds:remain,offline:true,offlineUnverified:true,user:u,message:'Akun dibuat lokal saat offline; belum terverifikasi di DB.'}}
        }
        return {ok:false,message:'Internet/DB tidak tersedia dan kode ini tidak punya izin offline yang masih berlaku. Hubungkan internet, cek kode, lalu coba lagi.'};
      }
    }
    if(!u.cloudUpdatedAt&&!u.offlineSyncConflict&&Math.max(0,Number(u.remainingSeconds)||0)>0){
      u.offlinePending=true;u.offlineUnverified=true;persistRentalUsers(users);
      return {ok:true,remainingSeconds:Math.max(0,Number(u.remainingSeconds)||0),offline:true,offlineUnverified:true,user:u,message:'Akun lokal belum terverifikasi di DB.'};
    }
    return {ok:false,message:'PC belum terhubung ke Cloud dan kode rental belum memiliki izin offline.'};
  }
  async function v11EndRentalSession(code,remainingSeconds){
    const c=String(code||'').trim().toUpperCase();if(!c||c==='__TEST10__')return {ok:true,skipped:true};
    const cfg=read(),event={token:cfg?.token||'',code:c,remainingSeconds:Math.max(0,Number(remainingSeconds)||0),sourceEventId:rentalEventId()};
    if(!cfg?.token){const q=readSessionOutbox();q.push({...event,queuedAt:new Date().toISOString()});saveSessionOutbox(q);return {ok:false,pending:true}}
    try{const d=await request('/device/session/end',event,{retries:1,timeoutMs:7000});if(d?.ok!==true)throw apiBusinessError(d);return d}
    catch(_){const q=readSessionOutbox();q.push({...event,queuedAt:new Date().toISOString()});saveSessionOutbox(q);return {ok:false,pending:true}}
  }
  async function flushSessionOutbox(){
    const cfg=read();if(!cfg?.token)return;
    const q=readSessionOutbox();if(!q.length)return;
    const keep=[];
    for(const item of q.slice(0,10)){
      try{const d=await request('/device/session/end',{token:cfg.token,code:item.code,remainingSeconds:item.remainingSeconds,sourceEventId:item.sourceEventId},{retries:0,timeoutMs:5000});if(d?.ok!==true)throw apiBusinessError(d)}
      catch(_){keep.push(item)}
    }
    saveSessionOutbox(keep.concat(q.slice(10)));
  }
  async function releaseRentalLease(code){
    const c=String(code||'').trim().toUpperCase(),cfg=read();if(!c||!cfg?.token)return {ok:false};
    try{return await request('/device/rental/release',{token:cfg.token,code:c},{retries:0,timeoutMs:4000})}catch(_){return {ok:false,pending:true}}
  }
  window.v11LookupRentalCode=v11LookupRentalCode;
  window.v11StartRentalSession=v11StartRentalSession;
  window.v11EndRentalSession=v11EndRentalSession;
  window.v11GetRentalSyncConflicts=readRentalConflicts;
  window.v11ReleaseRentalLease=releaseRentalLease;
  function attachRentalPreauth(){
    const input=document.getElementById('user-code-input');if(!input||input.dataset.globalRentalPreauth==='1')return;
    input.dataset.globalRentalPreauth='1';
    input.addEventListener('blur',()=>{
      const c=String(input.value||'').trim().toUpperCase();if(!c)return;
      v11LookupRentalCode(c).then(()=>status('Kode rental terverifikasi DB • cache izin offline aktif.'))
        .catch(e=>{if(e?.status===404)status('Kode belum ditemukan di DB.');});
    });
    input.addEventListener('input',()=>{
      const next=String(input.value||'').trim().toUpperCase(),prev=localStorage.getItem(PREAUTH_KEY)||'';
      if(prev&&prev!==next&&prev!==String(window.v11GetActiveCode?.()||''))void releaseRentalLease(prev);
      if(prev!==next)localStorage.removeItem(PREAUTH_KEY);
    });
  }
"""
if cloud.count(identity_anchor) != 1:
    raise SystemExit("Device identity helper anchor mismatch")
cloud = cloud.replace(identity_anchor, helpers, 1)

# Keep conflict events in local durable storage; never silently accept them or retry forever.
old_local_pending = "function localSyncPending(code, users){const u=users?.[code];if(dirty().has(code)||(u&&!u.cloudUpdatedAt)){markDirty(code);return true}return false}"
new_local_pending = "function localSyncPending(code, users){const u=users?.[code];if(u?.offlineSyncConflict)return true;if(dirty().has(code)||(u&&!u.cloudUpdatedAt)){markDirty(code);return true}return false}"
if cloud.count(old_local_pending) != 1:
    raise SystemExit("localSyncPending anchor mismatch")
cloud = cloud.replace(old_local_pending, new_local_pending, 1)

old_enqueue = "function enqueueUser(code,u){const c=String(code||'').toUpperCase();if(!c||!u)return;"
new_enqueue = "function enqueueUser(code,u){const c=String(code||'').toUpperCase();if(!c||!u||u.offlineSyncConflict)return;"
if cloud.count(old_enqueue) != 1:
    raise SystemExit("enqueueUser anchor mismatch")
cloud = cloud.replace(old_enqueue, new_enqueue, 1)

old_sync = re.compile(r"async function syncNow\(\)\{.*?\}\s*\n\s*async function pullNow\(\)", re.S)
new_sync = r"""async function syncNow(){
 if(syncBusy||resumeCloudAuthoritative)return;
 const c=read(),q=queue();if(!c.token||!q.length)return;
 syncBusy=true;
 try{
  const batch=q.slice(0,100),d=await request('/device/sync',{token:c.token,events:batch},{retries:1,timeoutMs:7000});
  const accepted=new Set(d.acceptedSourceEventIds||[]),conflictIds=new Set(d.conflictSourceEventIds||[]),users=window.v11GetUsers?.()||{};
  const keepConflicts=readRentalConflicts();
  for(const ev of batch){
    if(accepted.has(ev.sourceEventId)){
      if(ev.code)clearDirty(ev.code);
      if(ev.eventType==='rental_account_upsert'&&ev.code&&d.serverTime){
        const code=String(ev.code).toUpperCase();users[code]={...(users[code]||{}),cloudUpdatedAt:d.serverTime,offlinePending:false,offlineSyncConflict:false};
      }
    }else if(conflictIds.has(ev.sourceEventId)){
      const code=String(ev.code||'').toUpperCase(),reason='Kode lokal bentrok dengan data DB. Payload lokal disimpan dan tidak ditimpa.';
      keepConflicts.push({sourceEventId:ev.sourceEventId,code,reason,event:ev,createdAt:new Date().toISOString()});
      if(code){users[code]={...(users[code]||{}),offlinePending:true,offlineSyncConflict:true};clearDirty(code);}
    }
  }
  saveRentalConflicts(keepConflicts);
  try{localStorage.setItem('billing_db_users',JSON.stringify(users))}catch(_){}
  const handled=new Set([...accepted,...conflictIds]);saveQueue(q.filter(x=>!handled.has(x.sourceEventId)));
  status('ONLINE • '+accepted.size+' perubahan tersimpan'+(conflictIds.size?' • '+conflictIds.size+' konflik disimpan lokal (tidak ditimpa)':''));
 }catch(e){status('ONLINE • Sinkronisasi tertunda; antrean dipertahankan ('+(e?.message||'network')+')')}
 finally{syncBusy=false}
}
async function pullNow()"""
cloud, n = old_sync.subn(new_sync, cloud, count=1)
if n != 1:
    raise SystemExit("syncNow replacement anchor mismatch")

# Never continuously enqueue old full-table cache rows; only pending/new/dirty rows are synced.
old_reconcile = "async function reconcileLocalRentals(){const users=window.v11GetUsers?.()||{};for(const [code,u] of Object.entries(users)){if(!u||u.hiddenTest)continue;"
new_reconcile = "async function reconcileLocalRentals(){const users=window.v11GetUsers?.()||{};for(const [code,u] of Object.entries(users)){if(!u||u.hiddenTest||u.offlineSyncConflict)continue;"
if cloud.count(old_reconcile) != 1:
    raise SystemExit("reconcileLocalRentals anchor mismatch")
cloud = cloud.replace(old_reconcile, new_reconcile, 1)

# Heartbeat carries only current local-pending identity; server skips mirroring that code until conflict-safe sync resolves it.
old_meta = "activeClientLabel:u?.clientLabel||null,shutdownTimer:window.v11GetShutdownTimerStatus?.()||null"
new_meta = "activeClientLabel:u?.clientLabel||null,localPendingActiveCode:activeCode&&u&&!u.cloudUpdatedAt?activeCode:null,shutdownTimer:window.v11GetShutdownTimerStatus?.()||null"
if cloud.count(old_meta) != 1:
    raise SystemExit("heartbeat metadata anchor mismatch")
cloud = cloud.replace(old_meta, new_meta, 1)

old_call = "if(alertQueue().length)flushAdminAlerts();try{const activeCode="
new_call = "if(alertQueue().length)flushAdminAlerts();if(readSessionOutbox().length)void flushSessionOutbox();try{const activeCode="
if cloud.count(old_call) != 1:
    raise SystemExit("heartbeat outbox flush anchor mismatch")
cloud = cloud.replace(old_call, new_call, 1)

# The existing 30-second timer is an outbox retry, not a rental-table snapshot.
old_interval = "setInterval(()=>{syncNow();flushAdminAlerts()},30000)"
new_interval = "setInterval(()=>{syncNow();flushAdminAlerts();flushSessionOutbox()},30000)"
if cloud.count(old_interval) != 1:
    raise SystemExit("background retry timer anchor mismatch")
cloud = cloud.replace(old_interval, new_interval, 1)

cloud = cloud.replace("const CLOUD_KEY='billing_v11_cloud_config',OUTBOX_KEY='billing_v11_outbox',SYNC_CURSOR_KEY='billing_v11_sync_cursor',SYNC_DIRTY_KEY='billing_v11_sync_dirty',SYNC_SCHEMA_KEY='billing_v11_sync_schema',SYNC_SCHEMA='v11.29.3',CLIENT_KEY='billing_v11_client_id',APP='V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG';",
"const CLOUD_KEY='billing_v11_cloud_config',OUTBOX_KEY='billing_v11_outbox',SYNC_CURSOR_KEY='billing_v11_sync_cursor',SYNC_DIRTY_KEY='billing_v11_sync_dirty',SYNC_SCHEMA_KEY='billing_v11_sync_schema',SYNC_SCHEMA='v12.3.4-global-rental-db-first',CLIENT_KEY='billing_v11_client_id',APP='V12.3.4-GLOBAL-RENTAL-DB-FIRST';\n  // V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG baseline safeguards remain in place.")
if "APP='V12.3.4-GLOBAL-RENTAL-DB-FIRST'" not in cloud:
    raise SystemExit("Unable to bump cloud app marker")

# PC login is a DB-authorized start online, or a previously DB-leased/local-pending fallback offline.
start_pattern = re.compile(r"        function startSession\(\) \{.*?\n        \}\n\n        // Countdown dihitung dari deadline", re.S)
new_start = r"""        async function startSession() {
            const inputCode = document.getElementById('user-code-input').value.trim().toUpperCase();
            if (!inputCode) return showCustomModal("Silahkan masukkan Kode Unik terlebih dahulu!", "KODE KOSONG", true, "⌨️");
            if (typeof window.v11StartRentalSession !== 'function') return showCustomModal("Pengecekan DB belum siap. Restart billing atau hubungi admin.", "CLOUD BELUM SIAP", true, "☁️");
            let auth;
            try { auth = await window.v11StartRentalSession(inputCode); }
            catch (e) { auth = {ok:false,message:e?.message||'Pengecekan DB gagal.'}; }
            if (!auth?.ok) return showCustomModal(auth?.message||"Kode rental tidak dapat digunakan.", "AKSES DITOLAK", true, "❌");
            const user = dbUsers[inputCode] || auth.user;
            if (!user) return showCustomModal("Data rental tidak tersedia di cache lokal.", "AKSES DITOLAK", true, "❌");
            if (user.expiryDate) {
                const exp = new Date(user.expiryDate);
                if (Number.isNaN(exp.getTime()) || Date.now() > exp.getTime()) return showCustomModal("Masa aktif paket ini telah habis.", "PAKET EXPIRED", true, "⏳");
            }
            user.remainingSeconds = Math.max(0, Number(auth.remainingSeconds ?? user.remainingSeconds) || 0);
            if (user.remainingSeconds <= 0) return showCustomModal("Waktu telah habis silahkan hubungi admin 082298316902", "WAKTU HABIS", true, "⏰");
            if (auth.offlineUnverified) writeSystemLog("PERINGATAN: " + inputCode + " adalah rental lokal offline yang belum terverifikasi DB. Pastikan kode unik lalu sinkronkan saat online.");
            currentActiveCode = inputCode;
            // Cloud-owned accounts are not made dirty by a local timer tick.
            if (!user.cloudUpdatedAt || user.offlineSyncConflict) {
                user.offlinePending = true;
                window.v11MarkLocalRentalDirty?.(inputCode);
            }
            timerDeadlineMs = Date.now() + (user.remainingSeconds * 1000);
            persistActiveSession();
            window.v11HeartbeatNow?.('session_started');
            writeSystemLog("Sesi " + inputCode + " dimulai" + (auth.offline ? " (mode offline)." : "."));
            timerCompact = false;
            lastSavedRemaining = null;
            document.getElementById('lock-screen').classList.add('hidden');
            enterSessionVisualMode();
            const timerWidget = document.getElementById('timer-widget');
            timerWidget.classList.remove('hidden', 'compact');
            const minimizeButton = document.getElementById('timer-minimize');
            if (minimizeButton) { minimizeButton.innerText = '−'; minimizeButton.title = 'Kecilkan timer menjadi popup'; }
            if (window.electronAPI && window.electronAPI.resizeTimerWindow) window.electronAPI.resizeTimerWindow(500, 76);
            requestAnimationFrame(() => syncTimerWindowSize());
            if (window.electronAPI) { window.electronAPI.setLockMode(false); setTimeout(syncTimerWindowSize, 120); }
            if (timerInterval) clearInterval(timerInterval);
            updateTimer();
            timerInterval = window.setInterval(updateTimer, 250);
        }

        // Countdown dihitung dari deadline"""
index, n = start_pattern.subn(new_start, index, count=1)
if n != 1:
    raise SystemExit("startSession replacement anchor mismatch")

# Hide old cached cloud rows from the PC admin table. Only local pending/conflicted rows remain visible.
render_anchor = "                if (!u || u.hiddenTest) continue;\n                const seconds = Math.max(0, Number(u.remainingSeconds) || 0);"
render_replace = "                if (!u || u.hiddenTest) continue;\n                if (u.cloudUpdatedAt && currentActiveCode !== code && !u.offlinePending && !u.offlineSyncConflict) continue;\n                const seconds = Math.max(0, Number(u.remainingSeconds) || 0);"
if index.count(render_anchor) != 1:
    raise SystemExit("renderUserTable anchor mismatch")
index = index.replace(render_anchor, render_replace, 1)

# Mark accounts created locally so they remain in a conflict-safe outbox if connectivity is absent.
old_create = "dbUsers[code] = { category, remainingSeconds: enteredDurationSeconds, expiryDate: expiry };"
new_create = "dbUsers[code] = { category, remainingSeconds: enteredDurationSeconds, expiryDate: expiry, offlinePending: true, localCreation: true };"
if index.count(old_create) != 1:
    raise SystemExit("local account creation anchor mismatch")
index = index.replace(old_create, new_create, 1)
old_add = "if (expiry) dbUsers[code].expiryDate = expiry;\n            }"
new_add = "if (expiry) dbUsers[code].expiryDate = expiry;\n                if (!dbUsers[code].cloudUpdatedAt) { dbUsers[code].offlinePending = true; dbUsers[code].localCreation = true; }\n            }"
if index.count(old_add) != 1:
    raise SystemExit("local account add-time anchor mismatch")
index = index.replace(old_add, new_add, 1)

# A pending local user must retain its final timer balance as an explicit local sync event.
pause_anchor = "            const endedCode = currentActiveCode;\n            clearInterval(timerInterval);"
pause_replace = "            const endedCode = currentActiveCode;\n            if (currentActiveCode && dbUsers[currentActiveCode]?.offlinePending && !dbUsers[currentActiveCode]?.cloudUpdatedAt) window.v11MarkLocalRentalDirty?.(currentActiveCode);\n            clearInterval(timerInterval);"
if index.count(pause_anchor) != 1:
    raise SystemExit("pauseSession anchor mismatch")
index = index.replace(pause_anchor, pause_replace, 1)
end_anchor = "            currentActiveCode = null;\n            window.v11HeartbeatNow?.('session_stopped');"
end_replace = "            if (endedCode && endedCode !== TEST_SESSION_CODE) void window.v11EndRentalSession?.(endedCode, Math.max(0, Number(endedUser?.remainingSeconds) || 0));\n            currentActiveCode = null;\n            window.v11HeartbeatNow?.('session_stopped');"
if index.count(end_anchor) != 1:
    raise SystemExit("session end API anchor mismatch")
index = index.replace(end_anchor, end_replace, 1)

# Update visible/build version markers but keep the baseline v12.3.3 safeguards elsewhere.
index = index.replace(BASE, NEW)
package["version"] = "12.3.4"
package["description"] = "AniGames Billing V12.3.4: global DB-first rental lookup, exclusive sessions, offline lease cache, and conflict-safe incremental sync"
package["build"]["productName"] = "AniGames Billing V12.3.4"
if main_path.exists():
    main = main_path.read_text(encoding="utf-8").replace("appVersion: 'V12.3.3-watchdog'", "appVersion: 'V12.3.4-watchdog'")
    main_path.write_text(main, encoding="utf-8")

index_path.write_text(index, encoding="utf-8")
cloud_path.write_text(cloud, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text("AniGames Billing PC V12.3.4 — global DB-first rental lookup, exclusive sessions, offline lease cache, conflict-safe incremental sync.\n", encoding="utf-8")
print("PASS: V12.3.4 global rental lookup/session, offline lease fallback, incremental sync, and conflict-preserving local cache patched.")
