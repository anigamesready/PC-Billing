from pathlib import Path
import json

ROOT = Path(".")
CLOUD = ROOT / "v11-cloud.js"
INDEX = ROOT / "index.html"
PACKAGE = ROOT / "package.json"
LOCK = ROOT / "package-lock.json"
VERSION = ROOT / "VERSION.txt"
cloud = CLOUD.read_text(encoding="utf-8")
index = INDEX.read_text(encoding="utf-8")
package = json.loads(PACKAGE.read_text(encoding="utf-8"))
lock = json.loads(LOCK.read_text(encoding="utf-8"))

route_helpers = r"""
  const DB1_ROUTE_URL='https://wzkjpycjizexxcxrfdvr.supabase.co',DB2_ROUTE_URL='https://xcdbipgsvohesxhxydep.supabase.co';
  const DB1_ROUTE_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI';
  const DB2_ROUTE_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhjZGJpcGdzdm9oZXN4aHh5ZGVwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwNjI5ODUsImV4cCI6MjEwNzYzODk4NX0.kHymS-T8a_PcKk-oQWGMGHy3SSW1kAKStOBJVzMoSI';
  const DB1_API_KEY='sb_publishable_DobdCrOd43-vluON5gV7hg_6Js2Ea5V',DB2_API_KEY='sb_publishable_FjhnRZeXPnomlGRw75YLxw_d46R2Lag';
  const DB1_API_BASE=DB1_ROUTE_URL+'/functions/v1/ani-games-api',DB2_API_BASE=DB2_ROUTE_URL+'/functions/v1/ani-games-api';
  let dbRouteSnapshot=null,dbRouteCheckedAt=0,dbRoutePromise=null,dbRoutePrimed=false,dbRouteReloadScheduled=false;
  async function readGlobalDbRoute(url,key,ref){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
    try{
      const response=await fetch(url+'/functions/v1/db-route-status',{method:'GET',headers:{apikey:key},cache:'no-store',signal:controller.signal});
      const data=await response.json().catch(()=>({}));
      if(!response.ok||data?.ok!==true||data?.projectRef!==ref||!data?.route)throw new Error('DB_ROUTE_STATUS_UNAVAILABLE:'+ref);
      return data.route;
    }finally{clearTimeout(timer)}
  }
  function globalRouteFresh(r){
    const at=Date.parse(r?.last_parity_check_at||'');
    return Number.isFinite(at)&&at<=Date.now()+60000&&Date.now()-at<=30*60*1000;
  }
  function globalRouteSchemaMatches(r){
    return !!r?.schema_version&&r.schema_version===r.primary_schema_version&&r.schema_version===r.backup_schema_version;
  }
  async function resolveGlobalDbRoute(force=false){
    if(!force&&dbRouteSnapshot&&Date.now()-dbRouteCheckedAt<5000)return dbRouteSnapshot;
    if(dbRoutePromise)return dbRoutePromise;
    dbRoutePromise=(async()=>{
      const [a,b]=await Promise.all([
        readGlobalDbRoute(DB1_ROUTE_URL,DB1_ROUTE_KEY,'wzkjpycjizexxcxrfdvr'),
        readGlobalDbRoute(DB2_ROUTE_URL,DB2_ROUTE_KEY,'xcdbipgsvohesxhxydep')
      ]);
      const switchA=String(a.switch_id||''),switchB=String(b.switch_id||'');
      if(a.active_target!==b.active_target||Number(a.epoch)!==Number(b.epoch)||switchA!==switchB)
        throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB1 and DB2 target/epoch/switch ID do not match');
      if(!['primary','backup'].includes(String(a.active_target)))throw new Error('DB_ROUTE_INVALID_TARGET');
      if(a.sync_in_progress===true||b.sync_in_progress===true)throw new Error('DB_ROUTE_SYNC_IN_PROGRESS');
      if(a.active_target==='primary'){
        if(a.primary_ready!==true||b.primary_ready!==true)throw new Error('DB_ROUTE_PRIMARY_NOT_READY');
      }else{
        if(a.data_parity_ready!==true||b.data_parity_ready!==true||
           a.can_switch_to_backup!==true||b.can_switch_to_backup!==true||
           !globalRouteFresh(a)||!globalRouteFresh(b)||
           !globalRouteSchemaMatches(a)||!globalRouteSchemaMatches(b)||
           a.schema_version!==b.schema_version)
          throw new Error('DB_ROUTE_CUTOVER_BLOCKED: parity/schema freshness is not verified on both databases');
      }
      const next={target:String(a.active_target),epoch:Number(a.epoch)||0,switchId:switchA,apiBase:a.active_target==='backup'?DB2_API_BASE:DB1_API_BASE,apiKey:a.active_target==='backup'?DB2_API_KEY:DB1_API_KEY};
      const previous=dbRouteSnapshot;
      if(dbRoutePrimed&&previous&&(previous.target!==next.target||previous.epoch!==next.epoch||previous.switchId!==next.switchId)&&!dbRouteReloadScheduled){
        dbRouteReloadScheduled=true;
        try{localStorage.setItem('billing_v11_db_route_notice','Route global berubah ke '+(next.target==='backup'?'DB2':'DB1')+' • epoch '+next.epoch+'. Data lokal dan pairing dipertahankan.')}catch(_){}
        setTimeout(()=>{try{window.location.reload()}catch(_){}},2500);
      }
      dbRouteSnapshot=next;dbRouteCheckedAt=Date.now();dbRoutePrimed=true;
      try{localStorage.setItem('billing_v11_db_route_state',JSON.stringify({target:next.target,epoch:next.epoch,switchId:next.switchId,checkedAt:new Date().toISOString()}))}catch(_){}
      window.v11DbRouteStatus={target:next.target,epoch:next.epoch,switchId:next.switchId};
      return next;
    })();
    try{return await dbRoutePromise}finally{dbRoutePromise=null}
  }
"""
if "async function resolveGlobalDbRoute(" not in cloud:
    anchor = "  const save=v=>localStorage.setItem(CLOUD_KEY,JSON.stringify(v||{}));"
    if cloud.count(anchor) != 1: raise SystemExit("v11-cloud.js config anchor mismatch; refusing to patch")
    cloud = cloud.replace(anchor, anchor + "\n" + route_helpers, 1)

tick = chr(96)
dollar = chr(36)
old_request = "  async function request(path,body){const r=await fetch(API_BASE+path,{method:'POST',headers:{'content-type':'application/json','apikey':API_KEY},body:JSON.stringify(body)});const d=await r.json().catch(()=>({}));if(!r.ok)throw new Error(d.error||d.message||" + tick + "HTTP " + dollar + "{r.status}" + tick + ");return d}"
new_request = """  async function request(path,body){
    const route=await resolveGlobalDbRoute();
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),15000);
    try{
      const r=await fetch(route.apiBase+path,{method:'POST',headers:{'content-type':'application/json','apikey':route.apiKey},body:JSON.stringify(body),cache:'no-store',signal:controller.signal});
      const d=await r.json().catch(()=>({}));
      if(!r.ok)throw new Error(d.error||d.message||('HTTP '+r.status));
      return d;
    }catch(e){
      if(e?.name==='AbortError')throw new Error('DB_ROUTE_REQUEST_TIMEOUT: local queue retained');
      throw e;
    }finally{clearTimeout(timer)}
  }"""
if old_request in cloud:
    cloud = cloud.replace(old_request, new_request, 1)
elif new_request not in cloud:
    raise SystemExit("v11-cloud.js request() anchor mismatch; refusing to patch")

load_anchor = "window.addEventListener('load',()=>{const c=read();if(c.token)"
if load_anchor in cloud and "setInterval(()=>{resolveGlobalDbRoute(true).catch(()=>{})},10000)" not in cloud:
    cloud = cloud.replace(load_anchor, "window.addEventListener('load',()=>{void resolveGlobalDbRoute(true).catch(()=>{});setInterval(()=>{resolveGlobalDbRoute(true).catch(()=>{})},10000);const c=read();if(c.token)", 1)
elif "setInterval(()=>{resolveGlobalDbRoute(true).catch(()=>{})},10000)" not in cloud:
    raise SystemExit("v11-cloud.js load-start anchor mismatch; refusing to patch")

if "'V11.29.5-LOW-NOISE-LOG-FIX'" in cloud:
    cloud = cloud.replace("'V11.29.5-LOW-NOISE-LOG-FIX'", "'V11.29.6-GLOBAL-DB-ROUTE-REFRESH'", 1)
elif "'V11.29.6-GLOBAL-DB-ROUTE-REFRESH'" not in cloud:
    raise SystemExit("Unexpected PC cloud APP marker; refusing to bump blindly")

old_ver = "const APP_VERSION = 'V12.1.7-LOW-NOISE-LOG-FIX';"
new_ver = "const APP_VERSION = 'V12.1.8-GLOBAL-DB-ROUTE-REFRESH';"
if old_ver in index: index = index.replace(old_ver, new_ver, 1)
elif new_ver not in index: raise SystemExit("Unexpected PC HTML APP_VERSION; refusing to bump blindly")

if package.get("version") == "12.1.7": package["version"] = "12.1.8"
elif package.get("version") != "12.1.8": raise SystemExit("Unexpected package.json version; expected post-patch 12.1.7 runtime")
if lock.get("version") == "12.1.7": lock["version"] = "12.1.8"
elif lock.get("version") != "12.1.8": raise SystemExit("Unexpected package-lock version; expected post-patch 12.1.7 runtime")
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict): lock["packages"][""]["version"] = "12.1.8"

for token in ("resolveGlobalDbRoute", "DB_ROUTE_CUTOVER_INCOMPLETE", "billing_v11_db_route_state", "DB2_API_BASE"):
    if token not in cloud: raise SystemExit("Required dual-DB runtime token missing: " + token)

CLOUD.write_text(cloud, encoding="utf-8")
INDEX.write_text(index, encoding="utf-8")
PACKAGE.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
LOCK.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
VERSION.write_text("V12.1.8-GLOBAL-DB-ROUTE-REFRESH\n", encoding="utf-8")
print("PASS: PC v12.1.8 resolves DB1/DB2 route before cloud requests and preserves pairing/outbox state.")
