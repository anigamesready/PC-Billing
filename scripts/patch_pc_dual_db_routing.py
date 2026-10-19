from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
cloud_candidates = list(root.rglob('v11-cloud.js'))
if len(cloud_candidates) != 1:
    raise SystemExit(f'Expected exactly one v11-cloud.js under {root}, found {len(cloud_candidates)}')
cloud_path = cloud_candidates[0]
src = cloud_path.read_text(encoding='utf-8')
if 'const DB_ENDPOINTS=' in src or 'function resolveDbRoute(' in src:
    raise SystemExit('Dual-DB routing already applied; refusing to patch twice')

# Earlier build patches may have already advanced the APP marker. Match the declaration shape,
# not an obsolete version literal, while stripping the single-DB API target declaration.
decl_pattern = re.compile(r"SYNC_SCHEMA='[^']+',API_BASE='https://wzkjpycjizexxcxrfdvr\.supabase\.co/functions/v1/ani-games-api',API_KEY='[^']+',CLIENT_KEY='billing_v11_client_id',APP='[^']+';")
src, decl_count = decl_pattern.subn("SYNC_SCHEMA='v11.29.3',CLIENT_KEY='billing_v11_client_id',APP='V12.2.0-DUAL-DB-ROUTE';", src, count=1)
if decl_count != 1:
    raise SystemExit(f'Cloud config declaration anchor mismatch after prior build patches: {decl_count}')

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
    return !!r&&r.active_target==='backup'&&r.backup_ready===true&&r.auth_parity_ready===true&&r.data_parity_ready===true&&r.routing_gateway_ready===true&&r.can_switch_to_backup===true&&Number.isFinite(Number(r.epoch))&&Number(r.epoch)>0&&typeof r.switch_id==='string'&&r.switch_id.length>0&&schemasMatch&&Number.isFinite(parityAt)&&Date.now()-parityAt<=30*60*1000&&parityAt<=Date.now()+60000;
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
      if(!primary)throw new Error('DB_ROUTE_STATUS_UNAVAILABLE: DB1 route authority cannot be verified; automatic failover is disabled');
      const route=primary.route;
      if(!['primary','backup'].includes(route.active_target))throw new Error('DB_ROUTE_INVALID_TARGET');
      if(route.active_target==='primary'&&route.primary_ready!==true)throw new Error('DB_ROUTE_PRIMARY_NOT_READY');
      if(route.active_target==='backup'&&!dbRouteBackupReady(route))throw new Error('DB_ROUTE_CUTOVER_BLOCKED: DB2 readiness/parity/schema/gateway guard is not current');
      // Both projects must confirm the same global route before a runtime request is sent.
      let backup;try{backup=await readDbRoute('backup')}catch(_){throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB2 route status unavailable; refusing split-brain writes')}
      const b=backup.route;
      if(b.active_target!==route.active_target||Number(b.epoch)!==Number(route.epoch)||String(b.switch_id||'')!==String(route.switch_id||''))throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB1 and DB2 target, epoch, or switch ID differ');
      if(route.active_target==='primary'){
        if(b.primary_ready!==true)throw new Error('DB_ROUTE_PRIMARY_NOT_READY_ON_BOTH_PROJECTS');
        return saveDbRoute('primary',route);
      }
      if(!dbRouteBackupReady(b))throw new Error('DB_ROUTE_CUTOVER_BLOCKED: DB2 readiness/parity/schema/gateway guard is not current on both projects');
      return saveDbRoute('backup',b);
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
if src.count(old_token_handling) == 1:
    src = src.replace(old_token_handling, new_token_handling, 1)
elif "localStorage.setItem('billing_v11_token_rejected_hold','1')" in src and "pairing, cursor, data lokal, dan antrean dipertahankan" in src:
    # The earlier token-preservation patch already installed the safer hold/outbox behavior.
    pass
elif "localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);localStorage.removeItem(SYNC_DIRTY_KEY);" in src:
    raise SystemExit('Unsafe invalid-token cleanup remains; refusing dual-DB build')
cloud_path.write_text(src, encoding='utf-8')

package_path = cloud_path.parent / 'package.json'
package = json.loads(package_path.read_text(encoding='utf-8'))
if package.get('version') not in ('12.1.0', '12.1.1', '12.1.7', '12.2.0'):
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
runtime_version_lines = [line for line in index_html.splitlines() if "const APP_VERSION =" in line]
if len(runtime_version_lines) != 1:
    raise SystemExit(f'Expected one live APP_VERSION in index.html, found {len(runtime_version_lines)}')
old_runtime_version = runtime_version_lines[0]
indent = old_runtime_version[:old_runtime_version.index("const APP_VERSION =")]
index_html = index_html.replace(old_runtime_version, indent + "const APP_VERSION = 'V12.2.0-DUAL-DB-ROUTE';", 1)
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

for required in ['resolveDbRoute', 'db-route-status', 'data_parity_ready', 'routing_gateway_ready', 'last_parity_check_at', "String(b.switch_id||'')!==String(route.switch_id||'')", 'automatic failover is disabled', 'INVALID_DEVICE_TOKEN']:
    if required not in src:
        raise SystemExit('Required route guard missing: ' + required)
if "localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);localStorage.removeItem(SYNC_DIRTY_KEY);" in src:
    raise SystemExit('Unsafe auto-clearing of local pairing/sync state remains')
print('PASS: guarded dual-DB route patch applied; token/outbox preservation enabled; package version 12.2.0')


# V12.2.1 final addon: continuity for an exactly finalized active backup route.
# This does not authorize a new route switch with stale parity; switch readiness remains strict.
_pc_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path('.')
_pc_clouds = list(_pc_root.rglob('v11-cloud.js'))
if len(_pc_clouds) != 1:
    raise SystemExit(f'V12.2.1: expected one v11-cloud.js, found {len(_pc_clouds)}')
_pc_cloud_path = _pc_clouds[0]
_pc_cloud = _pc_cloud_path.read_text(encoding='utf-8')
_pc_old_route = """  function dbRouteBackupReady(r){
    const parityAt=Date.parse(r?.last_parity_check_at||'');
    const schemasMatch=!!r?.schema_version&&!!r?.primary_schema_version&&!!r?.backup_schema_version&&r.primary_schema_version===r.backup_schema_version&&r.schema_version===r.primary_schema_version;
    return !!r&&r.active_target==='backup'&&r.backup_ready===true&&r.auth_parity_ready===true&&r.data_parity_ready===true&&r.routing_gateway_ready===true&&r.can_switch_to_backup===true&&Number.isFinite(Number(r.epoch))&&Number(r.epoch)>0&&typeof r.switch_id==='string'&&r.switch_id.length>0&&schemasMatch&&Number.isFinite(parityAt)&&Date.now()-parityAt<=30*60*1000&&parityAt<=Date.now()+60000;
  }"""
_pc_new_route = """  function dbRouteFinalizedActive(r){
    if(!r||r.active_target!=='backup'||!Number.isFinite(Number(r.epoch))||Number(r.epoch)<1||!r.switch_id)return false;
    const expected='Coordinated global route finalized: backup epoch '+Number(r.epoch)+' switch '+String(r.switch_id);
    return !!r.last_cutover_test_at&&String(r.cutover_test_note||'')===expected;
  }
  function dbRouteBackupReady(r){
    // Continuity for an already-finalized active backup; never grants a new cutover with stale parity.
    if(dbRouteFinalizedActive(r))return true;
    const parityAt=Date.parse(r?.last_parity_check_at||'');
    const schemasMatch=!!r?.schema_version&&!!r?.primary_schema_version&&!!r?.backup_schema_version&&r.primary_schema_version===r.backup_schema_version&&r.schema_version===r.primary_schema_version;
    return !!r&&r.active_target==='backup'&&r.backup_ready===true&&r.auth_parity_ready===true&&r.data_parity_ready===true&&r.routing_gateway_ready===true&&r.can_switch_to_backup===true&&Number.isFinite(Number(r.epoch))&&Number(r.epoch)>0&&typeof r.switch_id==='string'&&r.switch_id.length>0&&schemasMatch&&Number.isFinite(parityAt)&&Date.now()-parityAt<=30*60*1000&&parityAt<=Date.now()+60000;
  }"""
if 'function dbRouteFinalizedActive(r)' not in _pc_cloud:
    if _pc_cloud.count(_pc_old_route) != 1:
        raise SystemExit(f'V12.2.1 route anchor mismatch: {_pc_cloud.count(_pc_old_route)}')
    _pc_cloud = _pc_cloud.replace(_pc_old_route, _pc_new_route, 1)
elif 'Coordinated global route finalized: backup epoch' not in _pc_cloud:
    raise SystemExit('V12.2.1 existing route helper is incomplete')
_pc_maintenance_anchor = "status('☁️ OFFLINE • Menunggu koneksi cloud');setPcState('offline','STATUS PC: OFF / TIDAK TERHUBUNG')"
_pc_maintenance_new = "if(String(e?.message||'').includes('SYNC_WRITE_QUIESCE_ACTIVE')){status('☁️ DB SYNC • Penulisan cloud dijeda; antrean lokal dipertahankan');setPcState('pending','STATUS PC: MAINTENANCE DB SYNC');return}status('☁️ OFFLINE • Menunggu koneksi cloud');setPcState('offline','STATUS PC: OFF / TIDAK TERHUBUNG')"
if _pc_maintenance_anchor in _pc_cloud:
    _pc_cloud = _pc_cloud.replace(_pc_maintenance_anchor, _pc_maintenance_new, 1)
elif 'SYNC_WRITE_QUIESCE_ACTIVE' not in _pc_cloud:
    raise SystemExit('V12.2.1 maintenance anchor unavailable; unknown heartbeat catch left unmodified')
_pc_cloud_path.write_text(_pc_cloud, encoding='utf-8')
_pc_package_path = _pc_cloud_path.parent / 'package.json'
_pc_package = json.loads(_pc_package_path.read_text(encoding='utf-8'))
if _pc_package.get('version') == '12.2.0':
    _pc_package['version'] = '12.2.1'
elif _pc_package.get('version') != '12.2.1':
    raise SystemExit(f'V12.2.1 unexpected package version: {_pc_package.get("version")}')
_pc_package['description'] = 'AniGames Billing V12.2.1: guarded dual Supabase routing, finalized-route continuity, and safe maintenance handling'
_pc_package.setdefault('build', {})['productName'] = 'AniGames Billing V12.2.1'
_pc_package_path.write_text(json.dumps(_pc_package, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
_pc_lock_path = _pc_cloud_path.parent / 'package-lock.json'
if _pc_lock_path.exists():
    _pc_lock = json.loads(_pc_lock_path.read_text(encoding='utf-8'))
    if _pc_lock.get('version') not in ('12.2.0', '12.2.1'):
        raise SystemExit(f'V12.2.1 unexpected lock version: {_pc_lock.get("version")}')
    _pc_lock['version'] = '12.2.1'
    if isinstance(_pc_lock.get('packages'), dict) and isinstance(_pc_lock['packages'].get(''), dict):
        _pc_lock['packages']['']['version'] = '12.2.1'
    _pc_lock_path.write_text(json.dumps(_pc_lock, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
_pc_renderer_path = _pc_cloud_path.parent / 'renderer.js'
_pc_renderer = _pc_renderer_path.read_text(encoding='utf-8').replace("const APP_VERSION = 'V12.2.0-DUAL-DB-ROUTE';", "const APP_VERSION = 'V12.2.1-DUAL-DB-ROUTE';")
if "const APP_VERSION = 'V12.2.1-DUAL-DB-ROUTE';" not in _pc_renderer:
    raise SystemExit('V12.2.1 renderer version marker missing')
_pc_renderer_path.write_text(_pc_renderer, encoding='utf-8')
_pc_index_path = _pc_cloud_path.parent / 'index.html'
_pc_index = _pc_index_path.read_text(encoding='utf-8')
if "const APP_VERSION = 'V12.2.0-DUAL-DB-ROUTE';" in _pc_index:
    _pc_index = _pc_index.replace("const APP_VERSION = 'V12.2.0-DUAL-DB-ROUTE';", "const APP_VERSION = 'V12.2.1-DUAL-DB-ROUTE';", 1)
if "const APP_VERSION = 'V12.2.1-DUAL-DB-ROUTE';" not in _pc_index:
    raise SystemExit('V12.2.1 live index version marker missing')
_pc_index = _pc_index.replace('V12.2.0-DUAL-DB-ROUTE', 'V12.2.1-DUAL-DB-ROUTE')
_pc_index_path.write_text(_pc_index, encoding='utf-8')
(_pc_cloud_path.parent / 'VERSION.txt').write_text('AniGames Billing PC V12.2.1 — dual DB route continuity + safe sync maintenance\n', encoding='utf-8')
for _pc_token in ['dbRouteFinalizedActive(r)', 'cutover_test_note', 'data_parity_ready', 'routing_gateway_ready', "String(b.switch_id||'')!==String(route.switch_id||'')", 'automatic failover is disabled']:
    if _pc_token not in _pc_cloud:
        raise SystemExit('V12.2.1 required route guard missing: ' + _pc_token)
if "localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);localStorage.removeItem(SYNC_DIRTY_KEY);" in _pc_cloud:
    raise SystemExit('V12.2.1 unsafe PC local-state clearing detected')
print('PASS: PC V12.2.1 exact finalized-route continuity + maintenance state + preserved local pairing state')
