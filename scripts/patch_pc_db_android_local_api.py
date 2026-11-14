#!/usr/bin/env python3
"""Remove PC Billing DB1/DB2 routing and point its device protocol at the local DB Android API."""
from pathlib import Path
import re
import sys

ROOT=Path(sys.argv[1] if len(sys.argv)>1 else ".").resolve()
cloud=ROOT/"v11-cloud.js"
main=ROOT/"main.js"
index=ROOT/"index.html"
if not all(p.is_file() for p in (cloud,main,index)):
    raise SystemExit("PC_DB_ANDROID_SOURCE_FILES_NOT_FOUND")

v=cloud.read_text(encoding="utf-8")
v=v.replace("APP='V12.3.8-AUTO-WOL-LAN-MAC'","APP='V12.4.8-DB-ANDROID'")
start=v.find("  // V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG baseline safeguards remain in place.")
end=v.find("  let heartbeatTimer=null",start)
if start<0 or end<0:
    raise SystemExit("PC_DUAL_DB_ROUTE_CONFIG_BLOCK_NOT_FOUND")
local_config=r"""
  // DB Android branch: one Redmi local API, no Supabase DB1/DB2 route selection.
  const API_URL_KEY='ani_games_ready_db_android_api_url_v1';
  function normalizeApiBaseUrl(value){
    const u=new URL(String(value||'').trim());
    if(u.username||u.password||u.search||u.hash)throw new Error('URL server tidak boleh berisi kredensial/query.');
    const loopback=['127.0.0.1','localhost','::1'].includes(u.hostname);
    if(u.protocol!=='https:'&&!(u.protocol==='http:'&&loopback))
      throw new Error('Server Redmi dari PC harus memakai HTTPS. HTTP hanya diizinkan untuk localhost.');
    return u.href.replace(/\/+$/,'');
  }
  function getApiBaseUrl(){
    const saved=localStorage.getItem(API_URL_KEY)||'http://127.0.0.1:8787';
    try{return normalizeApiBaseUrl(saved)}catch(_){return 'http://127.0.0.1:8787'}
  }
  function setApiBaseUrl(value){
    const base=normalizeApiBaseUrl(value);
    localStorage.setItem(API_URL_KEY,base);
    try{save({...read(),apiBaseUrl:base})}catch(_){}
    try{syncWatchdogCredentials()}catch(_){}
    status('Server rental DB Android: '+base);
    return base;
  }
  window.v11GetApiBaseUrl=getApiBaseUrl;
  window.v11SetApiBaseUrl=setApiBaseUrl;
"""
v=v[:start]+local_config+v[end:]

# Keep the existing local rental/outbox/timer behavior, but pass the selected API URL to the OS watchdog.
old_sync="if(typeof api==='function')void api({token:String(c.token||''),deviceId:String(c.deviceId||''),orgId:String(c.orgId||''),clientId:String(c.clientId||''),appVersion:APP}).catch(()=>{});"
new_sync="if(typeof api==='function')void api({token:String(c.token||''),deviceId:String(c.deviceId||''),orgId:String(c.orgId||''),clientId:String(c.clientId||''),appVersion:APP,apiBaseUrl:getApiBaseUrl()}).catch(()=>{});"
if old_sync not in v:
    raise SystemExit("PC_WATCHDOG_SYNC_CREDENTIALS_ANCHOR_NOT_FOUND")
v=v.replace(old_sync,new_sync,1)

# Replace the DB1/DB2/gateway request router with the local device API protocol.
req_start=v.find("  async function request(path,body,opts={})")
req_end=v.find("\n",req_start)
if req_start<0 or req_end<0:
    raise SystemExit("PC_CLOUD_REQUEST_FUNCTION_NOT_FOUND")
request=r"""  async function request(path,body={},opts={}){
    const retries=Math.max(0,Number(opts.retries??0));
    const clean=String(path||'').replace(/^\/+/,'');
    const cfg=read()||{};
    const token=String(body?.token||cfg.token||'');
    const payload={...(body&&typeof body==='object'?body:{})};
    delete payload.token;
    let last;
    for(let attempt=0;attempt<=retries;attempt++){
      const ctl=new AbortController();
      const timer=setTimeout(()=>ctl.abort(),Number(opts.timeoutMs||8000));
      try{
        const headers={'content-type':'application/json'};
        if(token)headers.authorization='Bearer '+token;
        const response=await fetch(getApiBaseUrl()+'/'+clean,{
          method:'POST',headers,body:JSON.stringify(payload),signal:ctl.signal,cache:'no-store'
        });
        const data=await response.json().catch(()=>({}));
        if(!response.ok){
          const error=new Error(String(data.error||data.message||('HTTP '+response.status)));
          error.status=response.status;
          error.retryable=response.status===408||response.status===425||response.status===429||response.status>=500;
          throw error;
        }
        return data;
      }catch(error){
        last=error;
        if(error?.retryable===false)break;
        if(attempt<retries)await new Promise(resolve=>setTimeout(resolve,350*(attempt+1)));
      }finally{clearTimeout(timer)}
    }
    throw last||new Error('LOCAL_API_NETWORK_ERROR');
  }"""
v=v[:req_start]+request+v[req_end:]
if "DB_ENDPOINTS" in v or "resolveDbRoute" in v or "dbRouteCheckedAt" in v:
    raise SystemExit("PC_DUAL_DB_ROUTER_REFERENCE_REMAINS_IN_V11_CLOUD")
cloud.write_text(v,encoding="utf-8")

# Main-process watchdog uses the same validated local API URL and the paired device Bearer token.
m=main.read_text(encoding="utf-8")
old_consts="const DB1_API_URL = 'https://wzkjpycjizexxcxrfdvr.supabase.co/functions/v1/ani-games-api';\nconst DB1_ANON_KEY = 'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI';"
if old_consts not in m:
    raise SystemExit("PC_MAIN_DB1_API_CONSTANTS_NOT_FOUND")
normalizer=r"""
function normalizeDbAndroidApiBaseUrl(value) {
    try {
        const url = new URL(String(value || '').trim());
        if (url.username || url.password || url.search || url.hash) return '';
        const loopback = ['127.0.0.1', 'localhost', '::1'].includes(url.hostname);
        if (url.protocol !== 'https:' && !(url.protocol === 'http:' && loopback)) return '';
        return url.href.replace(/\/+$/, '');
    } catch (_) { return ''; }
}
"""
m=m.replace(old_consts,normalizer,1)

read_start=m.find("function readWatchdogCredentials() {")
read_end=m.find("async function watchdogRequest",read_start)
if read_start<0 or read_end<0:
    raise SystemExit("PC_WATCHDOG_CREDENTIAL_READ_BLOCK_NOT_FOUND")
read_new=r"""function readWatchdogCredentials() {
    try {
        const files = watchdogFiles();
        if (!safeStorage.isEncryptionAvailable()) return null;
        const raw = safeStorage.decryptString(fs.readFileSync(files.credentials));
        const value = JSON.parse(raw);
        const apiBaseUrl = normalizeDbAndroidApiBaseUrl(value?.apiBaseUrl);
        if (!value || typeof value !== 'object' || !value.token || !value.deviceId || !value.clientId || !apiBaseUrl) return null;
        return { ...value, apiBaseUrl };
    } catch (_) { return null; }
}
"""
m=m[:read_start]+read_new+m[read_end:]

req_start=m.find("async function watchdogRequest(pathname, credentials, extra = {}) {")
req_end=m.find("async function waitForBillingReady",req_start)
if req_start<0 or req_end<0:
    raise SystemExit("PC_WATCHDOG_REQUEST_BLOCK_NOT_FOUND")
req_new=r"""async function watchdogRequest(pathname, credentials, extra = {}) {
    const base = normalizeDbAndroidApiBaseUrl(credentials?.apiBaseUrl);
    if (!base) throw new Error('LOCAL_DB_ANDROID_API_URL_INVALID');
    const token = String(credentials?.token || '');
    if (!token) throw new Error('DEVICE_TOKEN_MISSING');
    const response = await fetch(base + '/' + String(pathname || '').replace(/^\/+/, ''), {
        method: 'POST',
        headers: { authorization: 'Bearer ' + token, 'content-type': 'application/json' },
        body: JSON.stringify(extra || {}),
        signal: AbortSignal.timeout(7000)
    });
    const data = await response.json().catch(() => ({}));
    if (!response.ok || data?.ok === false) throw new Error(String(data?.error || ('HTTP ' + response.status)));
    return data;
}
"""
m=m[:req_start]+req_new+m[req_end:]

# Persist the URL alongside the encrypted device token so the independent watchdog uses the same server.
handler_start=m.find("ipcMain.handle('watchdog-credentials', (event, raw) => {")
handler_end=m.find("ipcMain.on('timer-health-pulse'",handler_start)
if handler_start<0 or handler_end<0:
    raise SystemExit("PC_WATCHDOG_CREDENTIAL_HANDLER_NOT_FOUND")
handler=r"""ipcMain.handle('watchdog-credentials', (event, raw) => {
    if (WATCHDOG_AGENT_MODE || event.sender !== mainWindow?.webContents) return { ok: false, message: 'Pemanggil tidak valid.' };
    try {
        const files = watchdogFiles();
        const value = raw && typeof raw === 'object' ? raw : {};
        const token = String(value.token || '').trim();
        if (!token) {
            try { fs.unlinkSync(files.credentials); } catch (_) {}
            return { ok: true, cleared: true };
        }
        const apiBaseUrl = normalizeDbAndroidApiBaseUrl(value.apiBaseUrl);
        if (token.length > 512 || !String(value.deviceId || '').trim() || !String(value.clientId || '').trim() || !apiBaseUrl) {
            return { ok: false, message: 'Identitas perangkat atau URL server watchdog tidak valid. Gunakan URL HTTPS.' };
        }
        if (!safeStorage.isEncryptionAvailable()) return { ok: false, message: 'Enkripsi penyimpanan OS tidak tersedia; watchdog tidak diaktifkan.' };
        fs.mkdirSync(files.dir, { recursive: true });
        const encrypted = safeStorage.encryptString(JSON.stringify({
            token, deviceId: String(value.deviceId), clientId: String(value.clientId),
            orgId: String(value.orgId || ''), appVersion: String(value.appVersion || ''), apiBaseUrl
        }));
        fs.writeFileSync(files.credentials, encrypted);
        return { ok: true };
    } catch (e) {
        return { ok: false, message: String(e?.message || 'Penyimpanan kredensial watchdog gagal.') };
    }
});
"""
m=m[:handler_start]+handler+m[handler_end:]
main.write_text(m,encoding="utf-8")

# Give the operator a clear server URL field in the existing pairing panel.
h=index.read_text(encoding="utf-8")
anchor='''                        <div class="form-group" style="grid-column: 1 / -1;">
                            <label>Kode Pairing / Enrollment PC</label>
                            <input type="text" id="v11-enrollment-code" maxlength="8" placeholder="Contoh: A1B2C3D4" autocomplete="off">
                        </div>
'''
field=anchor+'''                        <div class="form-group" style="grid-column: 1 / -1;">
                            <label>Alamat Server Rental DB Android (Redmi)</label>
                            <input type="url" id="v11-api-base-url" value="http://127.0.0.1:8787" placeholder="https://alamat-server-anda" autocomplete="url">
                            <small class="theme-help">PC yang terpisah dari Redmi wajib memakai alamat HTTPS tunnel. HTTP hanya untuk localhost pada PC yang sama.</small>
                            <button type="button" class="btn btn-secondary" onclick="v11SaveApiBaseUrl()">Simpan Alamat Server</button>
                            <small id="v11-api-base-url-status" class="theme-help">Server lokal belum dikonfigurasi.</small>
                        </div>
'''
if anchor not in h:
    raise SystemExit("PC_CLOUD_PAIRING_FORM_ANCHOR_NOT_FOUND")
h=h.replace(anchor,field,1)
h=h.replace("🔗 Hubungkan PC ke Cloud","🔗 Hubungkan PC ke Server Rental")
h=h.replace("🔄 Cek Status Cloud","🔄 Cek Status Server")
h=h.replace("Cloud belum dipairing.","Server rental belum dipairing.")
h=h.replace("Cloud V11","Server Rental DB Android")
script_anchor='''    <script src="v11-cloud.js"></script>
'''
script=script_anchor+'''    <script>
      function v11SaveApiBaseUrl(){
        const input=document.getElementById('v11-api-base-url');
        const label=document.getElementById('v11-api-base-url-status');
        try{
          const base=window.v11SetApiBaseUrl(input.value);
          label.textContent='Alamat server tersimpan: '+base;
        }catch(error){label.textContent='Gagal menyimpan: '+(error?.message||'URL tidak valid.');}
      }
      (function(){
        const input=document.getElementById('v11-api-base-url');
        if(input&&window.v11GetApiBaseUrl)input.value=window.v11GetApiBaseUrl();
      })();
    </script>
'''
if script_anchor not in h:
    raise SystemExit("PC_V11_CLOUD_SCRIPT_ANCHOR_NOT_FOUND")
h=h.replace(script_anchor,script,1)
index.write_text(h,encoding="utf-8")

# The old embedded Admin dashboard is not used by the PC runtime; remove its Supabase login surface.
admin=ROOT/"admin.html"
if admin.exists():
    admin.write_text("""<!doctype html>
<html lang="id"><head><meta charset="utf-8"><meta name="viewport" content="width=device-width,initial-scale=1">
<title>Ani Games Ready Admin DB Android</title>
<style>body{font-family:Arial,sans-serif;background:#101827;color:#eef2ff;display:grid;place-items:center;min-height:100vh;margin:0;padding:24px}main{max-width:620px;background:#1d293b;padding:28px;border-radius:16px}h1{margin-top:0}p{line-height:1.6;color:#cbd5e1}</style></head>
<body><main><h1>Ani Games Ready Admin</h1><p>Dashboard Admin terpisah dari aplikasi PC Billing. Gunakan APK Admin DB Android untuk pengelolaan rental pada server lokal Redmi.</p><p>Halaman dashboard Supabase lama dinonaktifkan pada build DB Android ini.</p></main></body></html>
""",encoding="utf-8")

# Static checks: the PC device client and watchdog no longer know DB1/DB2 or Supabase gateway URLs.
v=cloud.read_text(encoding="utf-8")
m=main.read_text(encoding="utf-8")
h=index.read_text(encoding="utf-8")
if any(x in v for x in ("DB_ENDPOINTS","resolveDbRoute","shared-db-gateway","supabase.co/functions")):
    raise SystemExit("PC_V11_CLOUD_SUPABASE_ROUTE_REMAINS")
if any(x in m for x in ("DB1_API_URL","DB1_ANON_KEY","supabase.co/functions")):
    raise SystemExit("PC_MAIN_WATCHDOG_SUPABASE_ROUTE_REMAINS")
if "v11SetApiBaseUrl" not in h or "v11-api-base-url" not in h:
    raise SystemExit("PC_LOCAL_SERVER_URL_UI_MISSING")
if "apiBaseUrl:getApiBaseUrl()" not in v or "apiBaseUrl" not in m:
    raise SystemExit("PC_WATCHDOG_API_URL_SYNC_MISSING")
print("PASS: PC device API and watchdog use one HTTPS-capable DB Android server URL; DB1/DB2 routing removed")
