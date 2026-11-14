from pathlib import Path
import json

root = Path('.')
html_path = root / 'index.html'
cloud_path = root / 'v11-cloud.js'
package_path = root / 'package.json'
lock_path = root / 'package-lock.json'
version_path = root / 'VERSION.txt'
html = html_path.read_text(encoding='utf-8')
cloud = cloud_path.read_text(encoding='utf-8')

if 'shutdown_timer_set' not in html:
    version_lines = [line for line in html.splitlines() if 'const APP_VERSION =' in line]
    if len(version_lines) != 1:
        raise SystemExit('Expected one APP_VERSION marker; refusing to patch.')
    old = version_lines[0]
    html = html.replace(old, old[:old.index('const APP_VERSION =')] + "const APP_VERSION = 'V12.1.8-SHUTDOWN-TIMER';", 1)

    footer = '<div id="app-version-footer" aria-label="Versi Billing">'
    indicator = '<div id="pc-shutdown-timer-indicator" class="hidden" role="status" aria-live="polite" style="position:fixed;left:12px;bottom:30px;z-index:100000;max-width:min(460px,calc(100vw - 24px));padding:10px 14px;border:1px solid #f59e0b;border-radius:10px;background:rgba(15,23,42,.96);color:#f8fafc;font-size:12px;font-weight:800;box-shadow:0 8px 28px rgba(0,0,0,.35)"></div>' + footer
    if html.count(footer) != 1:
        raise SystemExit('Version footer anchor mismatch; refusing to patch.')
    html = html.replace(footer, indicator, 1)

    anchor = '        window.v11ApplyRemoteCommand = async (command, payload = {}) => {'
    if html.count(anchor) != 1:
        raise SystemExit('Remote command handler anchor mismatch; refusing to patch.')
    helpers = r'''        const PC_SHUTDOWN_TIMER_KEY = 'ani_games_pc_shutdown_timer_v1';
        let pcShutdownTimerBusy = false, pcShutdownTimerLastPersist = 0;
        function readPcShutdownTimer() {
          try { const v=JSON.parse(localStorage.getItem(PC_SHUTDOWN_TIMER_KEY)||'null'); return v&&typeof v==='object'?v:null; } catch (_) { return null; }
        }
        function writePcShutdownTimer(v) {
          const n=v&&typeof v==='object'?{...v,updatedAt:new Date().toISOString()}:null;
          try { if(n)localStorage.setItem(PC_SHUTDOWN_TIMER_KEY,JSON.stringify(n));else localStorage.removeItem(PC_SHUTDOWN_TIMER_KEY); } catch(e) { console.error('[shutdown timer] persist failed',e); }
          renderPcShutdownTimerIndicator(); return n;
        }
        function pcShutdownHasRental() { return Boolean(currentActiveCode || String(localStorage.getItem('billing_remote_paused_code')||'').trim()); }
        function pcShutdownTimerStatusForAdmin() {
          const t=readPcShutdownTimer(); if(!t)return null;
          return {status:String(t.status||'unknown'),dueAt:Number(t.dueAt)||null,durationSeconds:Number(t.durationSeconds)||null,updatedAt:t.updatedAt||t.createdAt||null,reason:t.reason?String(t.reason).slice(0,220):null};
        }
        window.v11GetShutdownTimerStatus=pcShutdownTimerStatusForAdmin;
        function renderPcShutdownTimerIndicator() {
          const el=document.getElementById('pc-shutdown-timer-indicator'); if(!el)return;
          const t=readPcShutdownTimer(),s=String(t?.status||'');
          if(!t||s==='cancelled'||s==='none'){el.classList.add('hidden');return;}
          if(s==='scheduled'){
            const n=Math.max(0,Math.ceil((Number(t.dueAt)-Date.now())/1000)),h=Math.floor(n/3600),m=Math.floor(n%3600/60),sec=n%60;
            el.textContent='⏱ SHUTDOWN TERJADWAL • '+String(h).padStart(2,'0')+':'+String(m).padStart(2,'0')+':'+String(sec).padStart(2,'0')+' • Rental aktif akan membatalkan timer.';el.style.borderColor='#f59e0b';
          } else if(s==='blocked_active_session'){el.textContent='🛡 SHUTDOWN DIBLOKIR • Sesi rental aktif/paused. Tidak ada shutdown yang dijalankan.';el.style.borderColor='#ef4444';}
          else if(s==='failed'){el.textContent='⚠ TIMER SHUTDOWN GAGAL • '+String(t.reason||'Periksa Admin Android.');el.style.borderColor='#ef4444';}
          else if(s==='executing'){el.textContent='⏻ TIMER SELESAI • Permintaan shutdown dikirim setelah pemeriksaan sesi.';el.style.borderColor='#ef4444';}
          else {el.textContent='⏱ STATUS TIMER SHUTDOWN • '+s;el.style.borderColor='#64748b';}
          el.classList.remove('hidden');
        }
        function cancelPcShutdownTimerForRental(){
          const t=readPcShutdownTimer();if(t&&t.status==='scheduled')writePcShutdownTimer({...t,status:'blocked_active_session',dueAt:null,reason:'Sesi rental aktif/paused terdeteksi; timer dibatalkan demi keamanan.'});
        }
        async function tickPcShutdownTimer(){
          if(pcShutdownTimerBusy)return;const t=readPcShutdownTimer();if(!t||t.status!=='scheduled'){renderPcShutdownTimerIndicator();return;}
          const now=Date.now(),last=Number(t.lastTickAt||t.createdAtMs||0);
          if(last&&now-last>15000){writePcShutdownTimer({...t,status:'failed',dueAt:null,reason:'Billing berhenti/tidak merespons. Timer lama dibatalkan; jadwalkan ulang.'});return;}
          if(pcShutdownHasRental()){cancelPcShutdownTimerForRental();return;}
          if(now<Number(t.dueAt)){if(now-pcShutdownTimerLastPersist>=5000){pcShutdownTimerLastPersist=now;writePcShutdownTimer({...t,lastTickAt:now});}renderPcShutdownTimerIndicator();return;}
          if(pcShutdownHasRental()){cancelPcShutdownTimerForRental();return;}
          pcShutdownTimerBusy=true;writePcShutdownTimer({...t,status:'executing',dueAt:null,lastTickAt:now});
          try{if(!window.electronAPI?.powerAction)throw new Error('API power Windows tidak tersedia.');const r=await window.electronAPI.powerAction('shutdown');if(r?.ok===false)throw new Error(r.message||'Windows menolak shutdown.');writePcShutdownTimer({...t,status:'executing',dueAt:null,lastTickAt:Date.now(),reason:'Windows menerima permintaan shutdown timer.'});}
          catch(e){writePcShutdownTimer({...t,status:'failed',dueAt:null,reason:String(e?.message||e||'Shutdown gagal.')});}
          finally{pcShutdownTimerBusy=false;}
        }
        function startPcShutdownTimerWatcher(){
          if(window.__aniPcShutdownTimerWatcher)return;window.__aniPcShutdownTimerWatcher=true;
          const t=readPcShutdownTimer();if(t&&t.status==='scheduled'){const last=Number(t.lastTickAt||t.createdAtMs||0);if(last&&Date.now()-last>15000)writePcShutdownTimer({...t,status:'failed',dueAt:null,reason:'Billing ditutup/berhenti melebihi batas aman; timer lama tidak dieksekusi.'});}
          renderPcShutdownTimerIndicator();window.setInterval(()=>{void tickPcShutdownTimer();},1000);
        }
        startPcShutdownTimerWatcher();
'''
    html = html.replace(anchor, helpers + anchor, 1)

    cmd_anchor = "            const cmd = String(command || '').trim();\n            // V12.1.1: use a dedicated Electron BrowserWindow, independent of the timer UI."
    cmd_code = r'''            const cmd = String(command || '').trim();
            if(cmd==='shutdown_timer_set'){
              const seconds=Number(payload.seconds||0);
              if(!Number.isInteger(seconds)||seconds<60||seconds>86400)return {ok:false,message:'Durasi timer harus 1 menit sampai 24 jam.'};
              if(pcShutdownHasRental())return {ok:false,code:'ACTIVE_RENTAL_SHUTDOWN_BLOCKED',message:'Shutdown timer ditolak: sesi rental aktif/paused.'};
              const old=readPcShutdownTimer();if(old?.status==='scheduled')return {ok:false,message:'Timer shutdown aktif. Batalkan timer lama terlebih dahulu.'};
              const now=Date.now(),t=writePcShutdownTimer({id:'shutdown-'+now.toString(36)+'-'+Math.random().toString(36).slice(2,10),status:'scheduled',durationSeconds:seconds,createdAt:new Date(now).toISOString(),createdAtMs:now,lastTickAt:now,dueAt:now+seconds*1000,requestedBy:String(payload.requestedBy||'admin').slice(0,120),reason:null});
              pcShutdownTimerLastPersist=now;return {ok:true,message:'Timer disimpan di PC; shutdown tidak dijalankan sekarang.',timer:pcShutdownTimerStatusForAdmin()};
            }
            if(cmd==='shutdown_timer_cancel'){
              const t=readPcShutdownTimer();if(!t||t.status!=='scheduled')return {ok:true,message:'Tidak ada timer shutdown aktif.',timer:t?pcShutdownTimerStatusForAdmin():{status:'none'}};
              writePcShutdownTimer({...t,status:'cancelled',dueAt:null,reason:'Dibatalkan Admin.'});return {ok:true,message:'Timer shutdown dibatalkan.',timer:pcShutdownTimerStatusForAdmin()};
            }
            if(cmd==='shutdown_timer_status')return {ok:true,message:'Status timer dibaca dari PC.',timer:pcShutdownTimerStatusForAdmin()||{status:'none'}};
            // V12.1.1: use a dedicated Electron BrowserWindow, independent of the timer UI.'''
    if html.count(cmd_anchor)!=1:
        raise SystemExit('Timer command insertion anchor mismatch; refusing to patch.')
    html=html.replace(cmd_anchor,cmd_code,1)

    direct_old = "            if (cmd === 'shutdown') { const r=await window.electronAPI?.powerAction?.('shutdown'); return r?.ok===false?{ok:false,message:r.message||'Shutdown Windows gagal.'}:{ok:true,message:'Shutdown Windows dijalankan.'}; }"
    direct_new = "            if (cmd === 'shutdown') { if(pcShutdownHasRental())return {ok:false,code:'ACTIVE_RENTAL_SHUTDOWN_BLOCKED',message:'Shutdown diblokir karena sesi rental aktif/paused.'}; const r=await window.electronAPI?.powerAction?.('shutdown'); return r?.ok===false?{ok:false,message:r.message||'Shutdown Windows gagal.'}:{ok:true,message:'Shutdown Windows dijalankan.'}; }"
    if html.count(direct_old)!=1:
        raise SystemExit('Direct shutdown branch anchor mismatch; refusing to patch.')
    html=html.replace(direct_old,direct_new,1)

    power_anchor = "            const message = messages[action];\n            if (!message) return;\n\n            if (!confirm(message)) return;"
    power_new = "            const message = messages[action];\n            if (!message) return;\n            if(action==='shutdown'&&pcShutdownHasRental())return showCustomModal('Shutdown diblokir selama sesi rental aktif/paused. Akhiri sesi secara normal terlebih dahulu.','SHUTDOWN DIBLOKIR',true,'🛡️');\n            if (!confirm(message)) return;"
    if html.count(power_anchor)!=1:
        raise SystemExit('Local power action guard anchor mismatch; refusing to patch.')
    html=html.replace(power_anchor,power_new,1)
    html_path.write_text(html,encoding='utf-8')

cloud_anchor = 'activeClientLabel:u?.clientLabel||null}}'
cloud_replacement = 'activeClientLabel:u?.clientLabel||null,shutdownTimer:window.v11GetShutdownTimerStatus?.()||null}}'
if cloud_replacement not in cloud:
    if cloud.count(cloud_anchor)!=1:
        raise SystemExit('Heartbeat metadata anchor mismatch; refusing to patch.')
    cloud=cloud.replace(cloud_anchor,cloud_replacement,1)
cloud=cloud.replace("APP='V11.29.5-LOW-NOISE-LOG-FIX'","APP='V11.29.6-SHUTDOWN-TIMER'",1)
cloud_path.write_text(cloud,encoding='utf-8')

package=json.loads(package_path.read_text(encoding='utf-8'))
package['version']='12.1.8'
package_path.write_text(json.dumps(package,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
lock=json.loads(lock_path.read_text(encoding='utf-8'))
lock['version']='12.1.8'
if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict):
    lock['packages']['']['version']='12.1.8'
lock_path.write_text(json.dumps(lock,ensure_ascii=False,indent=2)+'\n',encoding='utf-8')
version_path.write_text('v12.1.8-pc-shutdown-timer\n',encoding='utf-8')
print('Patched PC Billing V12.1.8: shutdown timer, owner-command receiver, local countdown, and rental guards.')
