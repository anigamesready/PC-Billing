from pathlib import Path
import json
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
cloud_candidates = list(root.rglob('v11-cloud.js'))
if len(cloud_candidates) != 1:
    raise SystemExit(f'Expected exactly one v11-cloud.js under {root}, found {len(cloud_candidates)}')
cloud_path = cloud_candidates[0]
src = cloud_path.read_text(encoding='utf-8')
if 'const DB_ENDPOINTS=' in src or 'function resolveDbRoute(' in src:
    raise SystemExit('Dual-DB routing already applied; refusing to patch twice')

old_decl = "SYNC_SCHEMA='v11.29.3',API_BASE='https://wzkjpycjizexxcxrfdvr.supabase.co/functions/v1/ani-games-api',API_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI',CLIENT_KEY='billing_v11_client_id',APP='V11.29.3-SUPABASE-PAIR-RESUME';"
new_decl = "SYNC_SCHEMA='v11.29.3',CLIENT_KEY='billing_v11_client_id',APP='V12.2.0-DUAL-DB-ROUTE';"
if src.count(old_decl) != 1:
    raise SystemExit(f'Cloud config declaration anchor mismatch: {src.count(old_decl)}')
src = src.replace(old_decl, new_decl, 1)

insert_anchor = "  let heartbeatTimer=null,syncBusy=false,pullBusy=false,suppressQueue=false,lastFingerprints={},resumeCloudAuthoritative=false;"
route_code = r'''  // Both keys are public anon JWTs. Runtime chooses a target only from read-only, project-verified route status.
  // DB2 remains blocked until server-side readiness, recent row parity, schema parity and gateway checks pass.
  const DB_ENDPOINTS={
    primary:{target:'primary',ref:'wzkjpycjizexxcxrfdvr',baseUrl:'https://wzkjpycjizexxcxrfdvr.supabase.co',apiKey:'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI'},
    backup:{target:'backup',ref:'xcdbipgsvohesxhxydep',baseUrl:'https://xcdbipgsvohesxhxydep.supabase.co',apiKey:'eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhjZGJpcGdzdm9oZXN4aHh5ZGVwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwNjI5ODUsImV4cCI6MjEwNzYzODk4NX0.kHymS-T8a_PcKk-oQBYMGhHy3SSW1kAKStOBJVzMoSI'}
  };
  const DB_ROUTE_CACHE_MS=5000;
  let activeDbRoute=null,dbRouteCheckedAt=0,dbRoutePromise=null;
  function dbRouteBackupReady(r){
    const parityAt=Date.parse(r?.last_parity_check_at||'');
    const schemasMatch=!!r?.schema_version&&!!r?.primary_schema_version&&!!r?.backup_schema_version&&r.primary_schema_version===r.backup_schema_version&&r.schema_version===r.primary_schema_version;
    return !!r&&r.active_target==='backup'&&r.backup_ready===true&&r.data_parity_ready===true&&r.routing_gateway_ready===true&&r.can_switch_to_backup===true&&Number.isFinite(Number(r.epoch))&&Number(r.epoch)>0&&typeof r.switch_id==='string'&&r.switch_id.length>0&&schemasMatch&&Number.isFinite(parityAt)&&Date.now()-parityAt<=30*60*1000&&parityAt<=Date.now()+60000;
  }
  async function readDbRoute(target){
    const cfg=DB_ENDPOINTS[target],ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),4500);
    try{const response=await fetch(cfg.baseUrl+'/functions/v1/db-route-status',{method:'GET',headers:{apikey:cfg.apiKey},cache:'no-store',signal:ctl.signal});const data=await response.json().catch(()=>({}));if(!response.ok||data?.ok!==true||data?.readOnly!==true||data?.projectRef!==cfg.ref||!data?.route)throw new Error('DB_ROUTE_STATUS_UNAVAILABLE:'+target);return {target,route:data.route,servedAt:data.servedAt||null}}
    finally{clearTimeout(timer)}
  }
  function saveDbRoute(target,route){activeDbRoute={target,epoch:Number(route.epoch)||0,switchId:route.switch_id||null,schemaVersion:route.schema_version||null};dbRouteCheckedAt=Date.now();return activeDbRoute}
  async function resolveDbRoute(force=false){
    if(!force&&activeDbRoute&&Date.now()-dbRouteCheckedAt<DB_ROUTE_CACHE_MS)return activeDbRoute;
    if(dbRoutePromise)return dbRoutePromise;
    dbRoutePromise=(async()=>{
      let primary=null;try{primary=await readDbRoute('primary')}catch(_){}
      if(primary){
        const route=primary.route;
        if(route.active_target==='primary'&&route.primary_ready===true)return saveDbRoute('primary',route);
        if(route.active_target!=='backup')throw new Error('DB_ROUTE_INVALID_TARGET');
        if(!dbRouteBackupReady(route))throw new Error('DB_ROUTE_CUTOVER_BLOCKED: DB2 readiness/parity/schema/gateway guard is not current');
        let backup;try{backup=await readDbRoute('backup')}catch(_){throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB2 route status unavailable')}
        const b=backup.route;
        // Each project currently generates its own switch_id. Target+epoch plus readiness are the cross-project fence.
        if(!dbRouteBackupReady(b)||b.active_target!=='backup'||Number(b.epoch)!==Number(route.epoch)||!route.switch_id||!b.switch_id)throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB1 and DB2 target/epoch controls do not agree');
        return saveDbRoute('backup',b);
      }
      let backup=null;try{backup=await readDbRoute('backup')}catch(_){}
      if(backup&&dbRouteBackupReady(backup.route))return saveDbRoute('backup',backup.route);
      throw new Error('DB_ROUTE_STATUS_UNAVAILABLE: active database cannot be verified safely');
    })();
    try{return await dbRoutePromise}finally{dbRoutePromise=null}
  }
'''
if src.count(insert_anchor) != 1:
    raise SystemExit(f'Route insertion anchor mismatch: {src.count(insert_anchor)}')
src = src.replace(insert_anchor, route_code + insert_anchor, 1)

lines = src.splitlines()
request_start = [i for i, line in enumerate(lines) if line.lstrip().startswith('async function request(path,body,opts={}){')]
if len(request_start) != 1:
    raise SystemExit(f'Request function anchor mismatch: {len(request_start)}')
new_request = "  async function request(path,body,opts={}){const retries=Math.max(0,Number(opts.retries??0));let last;for(let attempt=0;attempt<=retries;attempt++){const ctl=new AbortController();const timer=setTimeout(()=>ctl.abort(),Number(opts.timeoutMs||8000));try{const route=await resolveDbRoute(attempt>0),cfg=DB_ENDPOINTS[route.target];const r=await fetch(cfg.baseUrl+'/functions/v1/ani-games-api'+path,{method:'POST',headers:{'content-type':'application/json','apikey':cfg.apiKey},body:JSON.stringify(body),signal:ctl.signal});const d=await r.json().catch(()=>({}));if(!r.ok){const detail=d.error||d.message||('HTTP '+r.status);if(r.status===401&&/invalid api key|UNAUTHORIZED_INVALID_API_KEY/i.test(String(detail)))throw new Error('API key Supabase ditolak oleh gateway. Periksa versi key aplikasi.');throw new Error(detail)}return d}catch(e){last=e;if(attempt<retries){dbRouteCheckedAt=0;await new Promise(res=>setTimeout(res,350*(attempt+1)));}}finally{clearTimeout(timer)}}throw last||new Error('NETWORK_ERROR')}"
lines[request_start[0]] = new_request
src = '\n'.join(lines) + '\n'

old_token_handling = "if(String(e?.message||'').includes('INVALID_DEVICE_TOKEN')){localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);localStorage.removeItem(SYNC_DIRTY_KEY);if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeatTimer=null;status('☁️ PAIRING TERPUTUS • Harus pairing ulang');setPcState('pending','STATUS PC: BELUM TERHUBUNG');return}"
new_token_handling = "if(String(e?.message||'').includes('INVALID_DEVICE_TOKEN')){if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeatTimer=null;status('☁️ TOKEN TIDAK DITEMUKAN PADA DB AKTIF • Pairing lokal, antrean, dan data lokal dipertahankan; verifikasi parity/route sebelum pairing ulang');setPcState('offline','STATUS PC: PERLU VERIFIKASI DB/TOKEN');return}"
if src.count(old_token_handling) != 1:
    raise SystemExit(f'Invalid-token preservation anchor mismatch: {src.count(old_token_handling)}')
src = src.replace(old_token_handling, new_token_handling, 1)
cloud_path.write_text(src, encoding='utf-8')

package_path = cloud_path.parent / 'package.json'
package = json.loads(package_path.read_text(encoding='utf-8'))
if package.get('version') not in ('12.1.1', '12.1.0', '12.2.0'):
    raise SystemExit(f"Unexpected PC package baseline: {package.get('version')}")
package['version'] = '12.2.0'
package['description'] = 'AniGames Billing V12.2.0: guarded dual Supabase routing; failover only after current DB2 readiness, schema and data parity checks'
package['build']['productName'] = 'AniGames Billing V12.2.0'
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
renderer_path = cloud_path.parent / 'renderer.js'
renderer = renderer_path.read_text(encoding='utf-8')
old_renderer_version = "const APP_VERSION = 'V11.0.0-CLOUD-OFFLINE-FIRST';"
if renderer.count(old_renderer_version) != 1:
    raise SystemExit(f'Renderer version label anchor mismatch: {renderer.count(old_renderer_version)}')
renderer_path.write_text(renderer.replace(old_renderer_version, "const APP_VERSION = 'V12.2.0-DUAL-DB-ROUTE';", 1), encoding='utf-8')
index_path = cloud_path.parent / 'index.html'
index_html = index_path.read_text(encoding='utf-8')
old_footer_version = '<span id="app-version-code">V11.1.0-CLOUD-OFFLINE-FIRST</span>'
if index_html.count(old_footer_version) != 1:
    raise SystemExit(f'PC footer version anchor mismatch: {index_html.count(old_footer_version)}')
index_path.write_text(index_html.replace(old_footer_version, '<span id="app-version-code">V12.2.0-DUAL-DB-ROUTE</span>', 1), encoding='utf-8')
lock_path = cloud_path.parent / 'package-lock.json'
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding='utf-8'))
    lock['version'] = '12.2.0'
    if isinstance(lock.get('packages'), dict) and isinstance(lock['packages'].get(''), dict):
        lock['packages']['']['version'] = '12.2.0'
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
(cloud_path.parent / 'VERSION.txt').write_text('AniGames Billing PC V12.2.0 - guarded dual-DB runtime routing\n', encoding='utf-8')

for required in ['resolveDbRoute', 'db-route-status', 'data_parity_ready', 'routing_gateway_ready', 'last_parity_check_at', 'INVALID_DEVICE_TOKEN']:
    if required not in src:
        raise SystemExit('Required route guard missing: ' + required)
if "localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);localStorage.removeItem(SYNC_DIRTY_KEY);" in src:
    raise SystemExit('Unsafe auto-clearing of local pairing/sync state remains')
print('PASS: guarded dual-DB route patch applied; token/outbox preservation enabled; package version 12.2.0')
