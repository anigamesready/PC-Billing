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
(function installAniGamesGlobalDbRouteRefresh(){
  if(window.__aniGamesGlobalDbRouteRefresh)return;
  window.__aniGamesGlobalDbRouteRefresh=true;
  const nativeFetch=window.fetch.bind(window);
  const DB1_ROUTE_URL='https://wzkjpycjizexxcxrfdvr.supabase.co';
  const DB2_ROUTE_URL='https://xcdbipgsvohesxhxydep.supabase.co';
  const DB1_ROUTE_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI';
  const DB2_ROUTE_KEY='eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6InhjZGJpcGdzdm9oZXN4aHh5ZGVwIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTIwNjI5ODUsImV4cCI6MjEwNzYzODk4NX0.kHymS-T8a_PcKk-oQBYMGhHy3SSW1kAKStOBJVzMoSI';
  const DB1_API_KEY='sb_publishable_DobdCrOd43-vluON5gV7hg_6Js2Ea5V';
  const DB2_API_KEY='sb_publishable_FjhnRZeXPnomlGRw75YLxw_d46R2Lag';
  const DB1_API_BASE=DB1_ROUTE_URL+'/functions/v1/ani-games-api';
  const DB2_API_BASE=DB2_ROUTE_URL+'/functions/v1/ani-games-api';
  const ROUTE_STATE_KEY='billing_v11_db_route_state';
  const ROUTE_NOTICE_KEY='billing_v11_db_route_notice';
  const ROUTE_CACHE_MS=15000;
  let routeState=null,routeCheckedAt=0,routePromise=null,monitorStarted=false,reloadScheduled=false;
  function readStoredRoute(){try{return JSON.parse(localStorage.getItem(ROUTE_STATE_KEY)||'null')}catch(_){return null}}
  function sameRoute(a,b){return !!a&&!!b&&String(a.target)===String(b.target)&&Number(a.epoch)===Number(b.epoch)&&String(a.switchId||'')===String(b.switchId||'')}
  async function readRoute(url,key,ref){
    const controller=new AbortController(),timer=setTimeout(()=>controller.abort(),5000);
    try{
      const response=await nativeFetch(url+'/functions/v1/db-route-status',{method:'GET',headers:{apikey:key},cache:'no-store',signal:controller.signal});
      const data=await response.json().catch(()=>({}));
      if(!response.ok||data?.ok!==true||data?.projectRef!==ref||!data?.route)throw new Error('DB_ROUTE_STATUS_UNAVAILABLE:'+ref);
      return data.route;
    }finally{clearTimeout(timer)}
  }
  function freshParity(r){
    const t=Date.parse(r?.last_parity_check_at||'');
    return Number.isFinite(t)&&t<=Date.now()+60000&&Date.now()-t<=30*60*1000;
  }
  function schemaMatches(r){
    return !!r?.schema_version&&r.schema_version===r.primary_schema_version&&r.schema_version===r.backup_schema_version;
  }
  function finalizedBackup(r){
    if(!r||r.active_target!=='backup'||!r.switch_id)return false;
    const note='Coordinated global route finalized: backup epoch '+Number(r.epoch)+' switch '+String(r.switch_id);
    return !!r.last_cutover_test_at&&String(r.cutover_test_note||'')===note;
  }
  function scheduleRouteReload(next){
    if(reloadScheduled)return;
    reloadScheduled=true;
    try{localStorage.setItem(ROUTE_NOTICE_KEY,'Target DB global berubah ke '+(next.target==='backup'?'DB2':'DB1')+' • epoch '+next.epoch+'. Refresh otomatis berjalan; pairing dan data lokal PC tetap dipertahankan.')}catch(_){}
    setTimeout(()=>{try{window.location.reload()}catch(_){}},700);
  }
  async function resolveGlobalDbRoute(force){
    force=!!force;
    if(!force&&routeState&&Date.now()-routeCheckedAt<ROUTE_CACHE_MS)return routeState;
    if(routePromise)return routePromise;
    routePromise=(async()=>{
      const pair=await Promise.all([
        readRoute(DB1_ROUTE_URL,DB1_ROUTE_KEY,'wzkjpycjizexxcxrfdvr'),
        readRoute(DB2_ROUTE_URL,DB2_ROUTE_KEY,'xcdbipgsvohesxhxydep')
      ]);
      const a=pair[0],b=pair[1],sidA=String(a.switch_id||''),sidB=String(b.switch_id||'');
      if(a.active_target!==b.active_target||Number(a.epoch)!==Number(b.epoch)||sidA!==sidB)
        throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB1 and DB2 target/epoch/switch ID do not match');
      if(a.sync_in_progress===true||b.sync_in_progress===true)throw new Error('DB_ROUTE_SYNC_IN_PROGRESS');
      if(a.active_target==='primary'){
        if(a.primary_ready!==true||b.primary_ready!==true)throw new Error('DB_ROUTE_PRIMARY_NOT_READY');
      }else if(a.active_target==='backup'){
        const alreadyFinalized=finalizedBackup(a)&&finalizedBackup(b);
        if(!alreadyFinalized&&(
          a.data_parity_ready!==true||b.data_parity_ready!==true||
          a.can_switch_to_backup!==true||b.can_switch_to_backup!==true||
          !freshParity(a)||!freshParity(b)||!schemaMatches(a)||!schemaMatches(b)||
          a.schema_version!==b.schema_version
        ))throw new Error('DB_ROUTE_CUTOVER_BLOCKED: parity/schema freshness is not verified');
      }else throw new Error('DB_ROUTE_INVALID_TARGET');
      const next={
        target:String(a.active_target),epoch:Number(a.epoch)||0,switchId:sidA,
        apiBase:a.active_target==='backup'?DB2_API_BASE:DB1_API_BASE,
        apiKey:a.active_target==='backup'?DB2_API_KEY:DB1_API_KEY
      };
      const stored=readStoredRoute();
      if(stored&&!sameRoute(stored,next)){
        try{localStorage.setItem(ROUTE_STATE_KEY,JSON.stringify({target:next.target,epoch:next.epoch,switchId:next.switchId,checkedAt:new Date().toISOString()}))}catch(_){}
        scheduleRouteReload(next);
        throw new Error('DB_ROUTE_CHANGED_RELOAD: refresh is restarting on the confirmed global DB target');
      }
      routeState=next;routeCheckedAt=Date.now();
      try{localStorage.setItem(ROUTE_STATE_KEY,JSON.stringify({target:next.target,epoch:next.epoch,switchId:next.switchId,checkedAt:new Date().toISOString()}))}catch(_){}
      window.v11DbRouteStatus={target:next.target,epoch:next.epoch,switchId:next.switchId};
      return next;
    })();
    try{return await routePromise}finally{routePromise=null}
  }
  function routeUrl(url,targetUrl){
    return String(url).replace(/^https:\/\/(?:wzkjpycjizexxcxrfdvr|xcdbipgsvohesxhxydep)\.supabase\.co/i,targetUrl.replace(/\/$/,''));
  }
  window.resolveGlobalDbRoute=resolveGlobalDbRoute;
  window.fetch=async function(input,init){
    const raw=input instanceof Request?input.url:(input instanceof URL?input.href:String(input||''));
    const isDbUrl=/^https:\/\/(?:wzkjpycjizexxcxrfdvr|xcdbipgsvohesxhxydep)\.supabase\.co(?:\/|$)/i.test(raw);
    if(!isDbUrl||raw.includes('/functions/v1/db-route-status'))return nativeFetch(input,init);
    const route=await resolveGlobalDbRoute(false);
    const url=routeUrl(raw,route.apiBase.replace('/functions/v1/ani-games-api',''));
    if(input instanceof Request){
      const request=new Request(url,input);
      const headers=new Headers(request.headers);
      if(init?.headers)new Headers(init.headers).forEach((v,k)=>headers.set(k,v));
      headers.set('apikey',route.apiKey);
      return nativeFetch(new Request(request,{...(init||{}),headers,cache:'no-store'}));
    }
    const headers=new Headers(init?.headers||{});
    headers.set('apikey',route.apiKey);
    return nativeFetch(url,{...(init||{}),headers,cache:'no-store'});
  };
  window.addEventListener('load',()=>{
    void resolveGlobalDbRoute(true).catch(e=>console.warn('[AniGames DB route]',String(e?.message||e)));
    if(!monitorStarted){monitorStarted=true;setInterval(()=>{void resolveGlobalDbRoute(true).catch(e=>console.warn('[AniGames DB route]',String(e?.message||e)))},15000)}
  });
})(); 
"""
if "async function resolveGlobalDbRoute(" not in cloud:
    cloud = route_helpers + "\n" + cloud
elif "window.__aniGamesGlobalDbRouteRefresh" not in cloud:
    raise SystemExit("Global DB route patch partially exists in cloud; refusing to duplicate it")


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
