#!/usr/bin/env python3
"""Finalize V12.4.8 PC Billing for the single Redmi DB Android API."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
worker = "https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev"
marker = "ANI_GAMES_DB_ANDROID_RUNTIME_CLEAN_V1"

def read(name):
    p = root / name
    if not p.is_file():
        raise SystemExit("REQUIRED_RUNTIME_FILE_MISSING:" + name)
    return p.read_text(encoding="utf-8-sig")

cloud = read("v11-cloud.js")
main = read("main.js")
index = read("index.html")

# Keep old internal storage keys to preserve existing PC pairing and outboxes.
pattern = re.compile(
    r"  const API_URL_KEY='ani_games_ready_db_android_api_url_v1';.*?"
    r"  window\.v11SetApiBaseUrl=setApiBaseUrl;",
    re.S,
)
replacement = f"""  const {marker}=true;
  const API_URL_KEY='ani_games_ready_db_android_api_url_v1';
  const DEFAULT_API_BASE_URL='{worker}';
  function normalizeApiBaseUrl(value){{
    const u=new URL(String(value||'').trim());
    if(u.username||u.password||u.search||u.hash)throw new Error('URL server tidak boleh berisi kredensial/query.');
    const loopback=['127.0.0.1','localhost','::1'].includes(u.hostname);
    if(u.protocol!=='https:'&&!(u.protocol==='http:'&&loopback))
      throw new Error('Server Redmi dari PC harus memakai HTTPS. HTTP hanya diizinkan untuk localhost.');
    return u.href.replace(/\\/+$/,'');
  }}
  function getApiBaseUrl(){{
    const saved=localStorage.getItem(API_URL_KEY);
    if(saved===null||!String(saved).trim())return DEFAULT_API_BASE_URL;
    try{{return normalizeApiBaseUrl(saved)}}catch(_){{return ''}}
  }}
  function setApiBaseUrl(value){{
    const base=normalizeApiBaseUrl(value);
    localStorage.setItem(API_URL_KEY,base);
    try{{save({{...read(),apiBaseUrl:base}})}}catch(_){{}}
    try{{syncWatchdogCredentials()}}catch(_){{}}
    status('Server rental DB Android: '+base);
    return base;
  }}
  window.v11GetApiBaseUrl=getApiBaseUrl;
  window.v11SetApiBaseUrl=setApiBaseUrl;"""
cloud, count = pattern.subn(replacement, cloud, count=1)
if count != 1:
    raise SystemExit(f"DB_ANDROID_API_URL_BLOCK_COUNT:{count}")

old_guard = "if(!base)throw new Error('SET_REDMi_API_URL_FIRST');"
new_guard = "if(!base)throw new Error('DB_ANDROID_API_URL_NOT_CONFIGURED');"
cloud = cloud.replace(old_guard, new_guard)
if new_guard not in cloud:
    raise SystemExit("DB_ANDROID_API_URL_GUARD_MISSING")

old_disconnect = "  function v11DisconnectDevice(){localStorage.removeItem(CLOUD_KEY);syncWatchdogCredentials();localStorage.removeItem(SYNC_CURSOR_KEY);if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeatTimer=null;status('☁️ Pairing cloud diputus. Billing tetap lokal.');setPcState('pending','STATUS PC: BELUM TERHUBUNG')}"
new_disconnect = """  async function v11DisconnectDevice(){
    const current=read()||{};
    let remoteDisconnected=false;
    if(current.token){
      try{
        const reply=await request('/device/disconnect',{token:current.token},{retries:1,timeoutMs:5000});
        remoteDisconnected=reply?.ok===true;
      }catch(e){
        console.warn('[AniGames DB Android] Disconnect server belum terkonfirmasi:',String(e?.message||e||'network_error'));
      }
    }
    localStorage.removeItem(CLOUD_KEY);
    syncWatchdogCredentials();
    localStorage.removeItem(SYNC_CURSOR_KEY);
    if(heartbeatTimer)clearInterval(heartbeatTimer);
    heartbeatTimer=null;
    status(remoteDisconnected?'Pairing DB Android diputus dan token server dicabut. Data rental lokal tetap aman.':'Pairing lokal diputus. Server belum mengonfirmasi pencabutan; status PC akan kedaluwarsa otomatis. Data lokal tetap aman.');
    setPcState('pending','STATUS PC: BELUM TERHUBUNG');
    return {ok:true,remoteDisconnected};
  }"""
if old_disconnect not in cloud:
    raise SystemExit("PC_DISCONNECT_FUNCTION_ANCHOR_MISSING")
cloud = cloud.replace(old_disconnect, new_disconnect, 1)

for old, new in {
  "Gagal mengirim alert ke Supabase; antrean tetap disimpan.": "Gagal mengirim alert ke DB Android; antrean tetap disimpan.",
  "PC belum terhubung ke Cloud dan kode rental belum memiliki izin offline.": "PC belum terhubung ke Server DB Android dan kode rental belum memiliki izin offline.",
  "Data tersimpan di PC. Cloud belum terhubung; akan sinkron otomatis saat online.": "Data tersimpan di PC. Server DB Android belum terhubung; sinkron otomatis saat online.",
  "Cloud menerima perubahan rental.": "Server DB Android menerima perubahan rental.",
  "Data tersimpan di PC. Sinkronisasi Cloud tertunda dan akan dicoba otomatis.": "Data tersimpan di PC. Sinkronisasi DB Android tertunda dan akan dicoba otomatis.",
  "Belum terhubung Cloud.": "Belum terhubung ke Server DB Android.",
  "ONLINE • Pairing Cloud belum tersedia.": "ONLINE • Pairing DB Android belum tersedia.",
  "Pairing Cloud belum tersedia.": "Pairing DB Android belum tersedia.",
  "Token cloud masih ditolak; pairing dan antrean dipertahankan.": "Token DB Android ditolak; pairing dan antrean dipertahankan.",
  "Cloud V11": "Server DB Android",
  "PC berhasil dipairing ke Cloud V11.": "PC berhasil dipairing ke Server DB Android.",
  "CLOUD TERHUBUNG": "DB ANDROID TERHUBUNG",
  "PAIRING CLOUD": "PAIRING DB ANDROID",
  "CLOUD SYNC": "DB ANDROID SYNC",
}.items():
    cloud = cloud.replace(old, new)
cloud = cloud.replace("☁️", "🗄️")

index = index.replace(
  "<title>Ani Games Ready - Billing Rental PC V11.18 Cloud Sync</title>",
  "<title>Ani Games Ready - Billing Rental PC V12.4.8 DB Android</title>",
)
index = index.replace(
  "Billing tetap berjalan offline. Saat online, data dan perintah admin disinkronkan otomatis ke cloud.",
  "Billing tetap berjalan offline. Saat online, data dan perintah Admin disinkronkan melalui Server DB Android.",
)
index = index.replace(
  '<input type="url" id="v11-api-base-url" value="" placeholder="https://alamat-server-Redmi-anda" autocomplete="url">',
  f'<input type="url" id="v11-api-base-url" value="{worker}" placeholder="https://alamat-server-Redmi-anda" autocomplete="url">',
)
index = index.replace("Server lokal belum dikonfigurasi.", "Server DB Android Redmi siap dipakai; alamat dapat diubah bila diperlukan.")
index = index.replace("☁️ SYNC DATA SEKARANG", "🔄 SYNC DATA SEKARANG")
index = index.replace("Periksa koneksi dan pairing Cloud.", "Periksa koneksi dan pairing Server DB Android.")
index = index.replace("layanan Cloud tidak tersedia", "Server DB Android tidak tersedia")
index = index.replace("CLOUD BELUM SIAP", "DB ANDROID BELUM SIAP")
index = index.replace("Cloud-owned accounts", "Server-owned accounts")
index = index.replace("Cloud sender threw; using local outbox fallback.", "DB Android sender failed; using local outbox fallback.")
index = index.replace("cloud sender unavailable at emit time", "DB Android sender unavailable at emit time")
index = index.replace("berhasil dan tersinkron ke Cloud.", "berhasil dan tersinkron ke DB Android.")
index = index.replace("SUKSES • CLOUD SYNC", "SUKSES • DB ANDROID SYNC")
index = index.replace("Cloud akan menyinkronkannya otomatis", "DB Android akan menyinkronkannya otomatis")
index = index.replace("Sinkronisasi Cloud akan dicoba otomatis lagi", "Sinkronisasi DB Android akan dicoba otomatis lagi")
index = index.replace("Cloud commands/pulls", "DB Android commands/pulls")
index = index.replace(
  '<script src="v11-Server DB Android.js"></script>',
  '<script src="v11-cloud.js"></script>',
)
if '<script src="v11-cloud.js"></script>' not in index or 'v11-Server DB Android.js' in index:
    raise SystemExit("PC_DB_ANDROID_SYNC_MODULE_NOT_LINKED")

for old in (
 "SUPABASE_API_NOT_CONFIGURED|", "DB_ROUTE_STATUS_UNAVAILABLE|",
 "DB_ROUTE_CUTOVER_INCOMPLETE|", "DB_ROUTE_CUTOVER_BLOCKED|",
 "ACTIVE_DB_GATEWAY_UNAVAILABLE|", "GLOBAL_ROUTE_MISMATCH|",
):
    index = index.replace(old, "")
index = index.replace("GLOBAL_ROUTE_NOT_FINALIZED", "")
index = index.replace("TOKEN_CLOUD_DITOLAK", "TOKEN_DB_ANDROID_DITOLAK")
index = index.replace("Cloud-owned", "Server-owned")
index = index.replace("cloud sender", "DB Android sender")
index = index.replace("cloud connection", "DB Android connection")
index = index.replace("pairing Cloud", "pairing DB Android")
index = index.replace("☁️", "🗄️")
if marker not in index:
    index = index.replace("</head>", f"<!-- {marker} -->\n</head>", 1)

for name, value in (("main.js", main), ("v11-cloud.js", cloud), ("index.html", index)):
    for forbidden in (
      "supabase.co/functions", "DB1_API_URL", "DB1_ANON_KEY",
      "DB2_API_URL", "DB_ENDPOINTS", "resolveDbRoute",
      "shared-db-gateway", "x-db-target-key",
    ):
        if forbidden.lower() in value.lower():
            raise SystemExit(f"LEGACY_DATABASE_ROUTE_REMAINS:{name}:{forbidden}")
if f"const {marker}=true;" not in cloud or f"const DEFAULT_API_BASE_URL='{worker}'" not in cloud:
    raise SystemExit("DB_ANDROID_WORKER_DEFAULT_MISSING")
if "request('/device/disconnect'" not in cloud:
    raise SystemExit("SERVER_SIDE_DISCONNECT_MISSING")
if "billing_v11_cloud_config" not in cloud or "billing_v11_outbox" not in cloud:
    raise SystemExit("EXISTING_LOCAL_STORAGE_COMPATIBILITY_KEYS_MISSING")
if worker not in index or 'id="v11-api-base-url"' not in index:
    raise SystemExit("DEFAULT_DB_ANDROID_API_URL_INPUT_MISSING")

(root / "v11-cloud.js").write_text(cloud, encoding="utf-8", newline="")
(root / "index.html").write_text(index, encoding="utf-8", newline="")
print("PASS: single Redmi API, actual sync module linked, remote disconnect and local data/outbox compatibility retained.")
