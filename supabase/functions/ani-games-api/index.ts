const H={"access-control-allow-origin":"*","access-control-allow-methods":"GET,POST,OPTIONS","access-control-allow-headers":"authorization,content-type,apikey,x-client-info","content-type":"application/json; charset=utf-8"};
const out=(s:number,d:unknown)=>new Response(JSON.stringify(d),{status:s,headers:H});
const base=()=> (Deno.env.get("SUPABASE_URL")||"").replace(/\/$/,"");const key=()=>Deno.env.get("SUPABASE_ANON_KEY")||Deno.env.get("SUPABASE_PUBLISHABLE_KEY")||"";
async function rpc(n:string,b:Record<string,unknown>,token?:string){const u=base(),k=key();if(!u||!k)throw Error("SUPABASE_API_NOT_CONFIGURED");const h:Record<string,string>={apikey:k,"content-type":"application/json","Content-Profile":"api","Accept-Profile":"api"};if(token)h.authorization="Bearer "+token;else if(/^eyJ[A-Za-z0-9_-]+\./.test(k))h.authorization="Bearer "+k;const r=await fetch(u+"/rest/v1/rpc/"+n,{method:"POST",headers:h,body:JSON.stringify(b)});const t=await r.text();let d:any;try{d=JSON.parse(t)}catch{d={message:t}}if(!r.ok)throw Error(d?.message||d?.hint||"Supabase RPC "+r.status);return d}
function serviceKey(){
 const direct=Deno.env.get("SUPABASE_SERVICE_ROLE_KEY")||Deno.env.get("SUPABASE_SECRET_KEY")||"";
 if(direct)return direct;
 try{const all=JSON.parse(Deno.env.get("SUPABASE_SECRET_KEYS")||"{}");if(typeof all.default==="string"&&all.default)return all.default;}catch(_){}
 return "";
}
async function hashBucket(v:string){const d=await crypto.subtle.digest("SHA-256",new TextEncoder().encode(v));return Array.from(new Uint8Array(d),x=>x.toString(16).padStart(2,"0")).join("");}
async function serverRpc(n:string,b:Record<string,unknown>){
 const u=base(),k=serviceKey();if(!u||!k)throw Error("PAIRING_SERVICE_UNAVAILABLE");
 const h:Record<string,string>={apikey:k,"content-type":"application/json","Content-Profile":"api","Accept-Profile":"api"};if(k.startsWith("eyJ"))h.authorization="Bearer "+k;const r=await fetch(u+"/rest/v1/rpc/"+n,{method:"POST",headers:h,body:JSON.stringify(b)});
 const t=await r.text();let d:any;try{d=JSON.parse(t)}catch{d={message:t}}
 if(!r.ok){
  const m=String(d?.message||d?.hint||"");
  const known=m.match(/^(INVALID_ENROLLMENT|CLIENT_ID_REQUIRED|RECOVERY_DEVICE_NOT_FOUND|RECOVERY_DEVICE_ID_MISMATCH|INVALID_DEVICE_TOKEN)(?:$|[:\\s])/);
  if(known)throw Error(known[1]);
  throw Error("PAIRING_BACKEND_UNAVAILABLE");
 }return d;
}
async function user(t:string){if(!t)return null;const r=await fetch(base()+"/auth/v1/user",{headers:{apikey:key(),authorization:"Bearer "+t}});return r.ok?await r.json():null}
function blynkPowerPin(){const pin=(Deno.env.get("BLYNK_POWER_PIN")||"V0").trim().toUpperCase();if(!/^V[0-9]+$/.test(pin))throw Error("BLYNK_POWER_PIN_INVALID");return pin}
async function validateIoTTarget(deviceId:string,token:string,context:any){
 if(!deviceId)throw Error("device_id_required");
 const u=new URL(base()+"/rest/v1/devices");u.searchParams.set("select","id,org_id,device_name,metadata");u.searchParams.set("limit","1000");
 const r=await fetch(u,{headers:{apikey:key(),authorization:"Bearer "+token,"Accept-Profile":"public"}});
 if(!r.ok)throw Error("DEVICE_MAPPING_LOOKUP_FAILED");
 const rows:any[]=await r.json(),orgs=new Set((Array.isArray(context?.orgs)?context.orgs:[]).map((o:any)=>String(o.id)));
 const accessible=(Array.isArray(rows)?rows:[]).filter(x=>{
  if(!orgs.has(String(x.org_id)))return false;
  const m=x?.metadata;
  return !(m&&Object.prototype.hasOwnProperty.call(m,"pairingDuplicateArchivedAt"));
 });
 if(!accessible.some(x=>String(x.id)===deviceId))throw Error("DEVICE_NOT_ACCESSIBLE");
 const mapped=accessible.filter(x=>String(x?.metadata?.blynkPowerTarget).toLowerCase()==="true");
 if(mapped.length>1)throw Error("BLYNK_DEVICE_MAPPING_CONFLICT");
 if(mapped.length===1){
  if(String(mapped[0].id)!==deviceId)throw Error("BLYNK_DEVICE_MAPPING_MISMATCH");
  return;
 }
 if(accessible.length===1)return;
 throw Error("BLYNK_DEVICE_MAPPING_REQUIRED");
}
async function blynkWrite(token:string,pin:string,value:"0"|"1"){
 const u=new URL("https://blynk.cloud/external/api/update");u.searchParams.set("token",token);u.searchParams.set(pin,value);
 const r=await fetch(u),body=(await r.text()).trim();
 return {ok:r.ok&&!/error|invalid token|wrong pin|no datastream|not found/i.test(body),status:r.status,body};
}
function pathOf(r:Request){return new URL(r.url).pathname.replace(/^\/+|\/+$/g,"").replace(/^functions\/v1\/ani-games-api\/?/,"").replace(/^ani-games-api\/?/,"")}
async function handler(r:Request){if(r.method==="OPTIONS")return new Response(null,{status:204,headers:H});const p=pathOf(r);try{
if(r.method==="GET"&&p==="health")return out(200,{ok:true,service:"ani-games-billing-supabase",apiVersion:"v1"});
if(r.method==="GET"&&p==="auth/me"){const t=(r.headers.get("authorization")||"").replace(/^Bearer /,"");const u=await user(t);return u?out(200,{ok:true,user:{id:u.id,email:u.email}}):out(401,{ok:false,error:"invalid_or_expired_token"})}
if(p==="iot/status"){
 if(r.method!=="GET")return out(405,{ok:false,error:"method_not_allowed"});
 const t=(r.headers.get("authorization")||"").replace(/^Bearer /,"");
 if(!await user(t))return out(401,{ok:false,error:"invalid_or_expired_token"});
 const c=await rpc("admin_context",{},t);if(c?.role!=="owner")return out(403,{ok:false,error:"owner_only"});
 const bt=Deno.env.get("BLYNK_AUTH_TOKEN")||"";if(!bt)return out(503,{ok:false,error:"BLYNK_AUTH_TOKEN_NOT_CONFIGURED_IN_SUPABASE"});
 const u=new URL("https://blynk.cloud/external/api/isHardwareConnected");u.searchParams.set("token",bt);
 const q=await fetch(u),b=(await q.text()).trim();if(!q.ok)return out(502,{ok:false,error:"blynk_status_unavailable",detail:b});
 if(/invalid token|error/i.test(b))return out(502,{ok:false,error:"blynk_status_rejected",detail:b});
 return out(200,{ok:true,online:b.toLowerCase()==="true",pin:blynkPowerPin()});
}
if(p==="iot/power"){
 if(r.method!=="POST")return out(405,{ok:false,error:"method_not_allowed"});
 const t=(r.headers.get("authorization")||"").replace(/^Bearer /,"");
 if(!await user(t))return out(401,{ok:false,error:"invalid_or_expired_token"});
 const c=await rpc("admin_context",{},t);if(c?.role!=="owner")return out(403,{ok:false,error:"owner_only"});
 const b:any=await r.json().catch(()=>({})),deviceId=String(b.deviceId||"").trim();
 await validateIoTTarget(deviceId,t,c);
 const bt=Deno.env.get("BLYNK_AUTH_TOKEN")||"";if(!bt)return out(503,{ok:false,error:"BLYNK_AUTH_TOKEN_NOT_CONFIGURED_IN_SUPABASE"});
 const pin=blynkPowerPin(),u=new URL("https://blynk.cloud/external/api/isHardwareConnected");u.searchParams.set("token",bt);
 const q=await fetch(u),body=(await q.text()).trim();if(!q.ok)return out(502,{ok:false,error:"blynk_status_unavailable",detail:body});
 if(/invalid token|error/i.test(body))return out(502,{ok:false,error:"blynk_status_rejected",detail:body});
 if(body.toLowerCase()!=="true")return out(503,{ok:false,error:"blynk_device_offline"});
 const high=await blynkWrite(bt,pin,"1");
 if(!high.ok){await blynkWrite(bt,pin,"0").catch(()=>null);return out(502,{ok:false,error:"blynk_command_failed",detail:high.body||("HTTP "+high.status),pin})}
 await new Promise(a=>setTimeout(a,500));
 let low=await blynkWrite(bt,pin,"0"),releaseRecovered=false;
 if(!low.ok){low=await blynkWrite(bt,pin,"0").catch(()=>({ok:false,body:"release retry failed",status:0}));releaseRecovered=!!low.ok}
 if(!low.ok)return out(502,{ok:false,error:"blynk_release_failed",detail:low.body||("HTTP "+low.status),releaseRecovered:false,pin});
 return out(200,{ok:true,message:"power_pulse_sent",pin,pulse_ms:500,deviceId,releaseRecovered});
}
if(r.method!=="POST")return out(404,{ok:false,error:"not_found",path:p});const b:any=await r.json().catch(()=>({}));
if(p==="device/alert"){
 const token=String(b.token||""),eventId=String(b.eventId||""),eventType=String(b.eventType||""),message=String(b.message||"").slice(0,240);
 if(!token||!eventId||!message)return out(400,{ok:false,error:"alert_fields_required"});
 if(!["session_expired","session_stopped"].includes(eventType))return out(400,{ok:false,error:"invalid_alert_type"});
 const saved=await rpc("device_emit_admin_alert",{p_token:token,p_event_id:eventId,p_event_type:eventType,p_message:message,p_payload:b.payload&&typeof b.payload==="object"?b.payload:{},p_occurred_at:b.occurredAt||new Date().toISOString()});
 return out(200,{ok:true,...saved});
}
if(p==="device/disconnect")return out(200,{ok:true,...await rpc("device_disconnect",{p_token:String(b.token||"")})});
if(p==="device/enroll"){
 const code=String(b.code||"").trim().toUpperCase(),clientId=String(b.clientId||"").trim(),deviceName=String(b.deviceName||"").trim().slice(0,120),appVersion=String(b.appVersion||"").trim().slice(0,64);
 if(code.length<4||code.length>80||!/^[A-Z0-9-]+$/.test(code)||!clientId||clientId.length>128)return out(400,{ok:false,error:"INVALID_REQUEST"});
 const sk=serviceKey();if(!sk)return out(503,{ok:false,error:"PAIRING_SERVICE_UNAVAILABLE"});
 const keys:Array<{key:string,max:number,clear:boolean}>=[
  {key:await hashBucket(sk+"|device-enroll-client|"+clientId.toUpperCase()),max:5,clear:true},
  {key:await hashBucket(sk+"|device-enroll-code|"+code),max:5,clear:true}
 ];
 const clientIp=(r.headers.get("cf-connecting-ip")||r.headers.get("x-real-ip")||"").trim().slice(0,128);
 if(clientIp)keys.unshift({key:await hashBucket(sk+"|device-enroll-ip|"+clientIp),max:60,clear:false});
 for(const bucket of keys){
  let limit:any;
  try{limit=await serverRpc("device_pairing_rate_limit_consume",{p_key_hash:bucket.key,p_max_attempts:bucket.max});}
  catch(_){return out(503,{ok:false,error:"PAIRING_SERVICE_UNAVAILABLE"});}
  if(!limit||limit.allowed!==true){
   const retry=Math.max(1,Math.min(900,Number(limit?.retry_after_seconds)||60));
   return new Response(JSON.stringify({ok:false,error:"PAIRING_RATE_LIMITED",retry_after_seconds:retry}),{status:429,headers:{...H,"retry-after":String(retry)}});
  }
 }
 let data:any;
 try{data=await serverRpc("redeem_device",{p_code:code,p_client_id:clientId,p_device_name:deviceName,p_app_version:appVersion});}
 catch(e){const msg=e instanceof Error?e.message:"PAIRING_FAILED";if(msg==="PAIRING_BACKEND_UNAVAILABLE"||msg==="PAIRING_SERVICE_UNAVAILABLE")return out(503,{ok:false,error:msg});if(msg==="INVALID_ENROLLMENT")return out(401,{ok:false,error:msg});if(msg==="CLIENT_ID_REQUIRED")return out(400,{ok:false,error:msg});return out(400,{ok:false,error:/^[A-Z0-9_]{3,64}$/.test(msg)?msg:"PAIRING_FAILED"});}
 try{await serverRpc("device_pairing_rate_limit_clear",{p_key_hashes:keys.filter(k=>k.clear).map(k=>k.key)});}catch(_){}
 return out(200,{ok:true,...data});
}
if(p==="device/heartbeat")return out(200,{ok:true,...await rpc("device_heartbeat",{p_token:String(b.token||""),p_app_version:String(b.appVersion||""),p_metadata:b.metadata||{}})});
if(p==="device/ack"){const t=String(b.token||""),id=String(b.commandId||""),s=String(b.status||"acknowledged"),v=b.result||{};const a=await rpc("device_ack",{p_token:t,p_command_id:id,p_status:s,p_result:v});let trial:unknown=null;if(["completed","failed","expired"].includes(s))trial=await rpc("device_finalize_trial",{p_token:t,p_command_id:id,p_status:s,p_result:v});return out(200,{ok:true,...a,...(trial?{trial}:{})})}
if(p==="device/sync")return out(200,{ok:true,...await rpc("device_sync",{p_token:String(b.token||""),p_events:Array.isArray(b.events)?b.events:[]})});
if(p==="device/pull")return out(200,{ok:true,...await rpc("device_pull_sync",{p_token:String(b.token||""),p_cursor:b.cursor?String(b.cursor):null})});
if(p==="device/rentals")return out(200,await rpc("device_rentals_snapshot",{p_token:String(b.token||"")}));
return out(404,{ok:false,error:"not_found",path:p})
}catch(e){const m=e instanceof Error?e.message:"request_failed";const s=/INVALID_DEVICE_TOKEN|INVALID_ENROLLMENT|invalid_or_expired_token/.test(m)?401:/owner_only|ADMIN_ROLE_REQUIRED/.test(m)?403:/BLYNK_DEVICE_MAPPING_REQUIRED|BLYNK_DEVICE_MAPPING_MISMATCH|BLYNK_DEVICE_MAPPING_CONFLICT|DEVICE_NOT_ACCESSIBLE/.test(m)?409:/BLYNK_AUTH_TOKEN_NOT_CONFIGURED_IN_SUPABASE|BLYNK_DEVICE_OFFLINE|blynk_device_offline|DEVICE_MAPPING_LOOKUP_FAILED/.test(m)?503:400;return out(s,{ok:false,error:m})}}
Deno.serve(handler);