import test from 'node:test';
import assert from 'node:assert/strict';
import fs from 'node:fs';
import path from 'node:path';
import vm from 'node:vm';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const source = fs.readFileSync(path.join(root, 'v11-cloud.js'), 'utf8');
const WORKER = 'https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev';

function harness() {
  const values = new Map(), calls = [], users = {}, elements = new Map();
  let command = false;
  const noop = () => {}, timer = () => 1;
  const document = {getElementById(id) {
    if (!elements.has(id)) elements.set(id, {
      id, value:id==='v11-enrollment-code'?'PAIR-TEST-2026':'', textContent:'', title:'', dataset:{},
      classList:{add:noop,remove:noop},setAttribute:noop,addEventListener:noop
    });
    return elements.get(id);
  }};
  const localStorage = {
    getItem:k=>values.has(k)?values.get(k):null, setItem:(k,v)=>values.set(k,String(v)),
    removeItem:k=>values.delete(k), key:i=>[...values.keys()][i]??null,
    get length(){return values.size;}
  };
  const fetch = async (url, init={}) => {
    const route=new URL(url).pathname, body=init.body?JSON.parse(init.body):{};
    calls.push({route,body,headers:init.headers||{}});
    let data={ok:true};
    switch(route) {
      case '/device/enroll': data={ok:true,token:'device-token-smoke',device_id:'device-smoke',org_id:'org-smoke',client_id:body.clientId}; break;
      case '/device/heartbeat': data={ok:true,commands:command?[{id:'11111111-1111-4111-8111-111111111111',command:'set_theme',payload:{}}]:[],rental_accounts:[],free_test_disabled:false}; command=false; break;
      case '/device/watchdog': data={ok:true,commands:[]}; break;
      case '/device/ack': data={ok:true,status:body.status||'acknowledged'}; break;
      case '/device/test-policy': data={ok:true,enabled:true}; break;
      case '/device/session-control-policy': data={ok:true,enabled:true,allow_stop_pause:true,message:'BILLING_STOP_PAUSE_ALLOWED'}; break;
      case '/device/rental/lookup': data={ok:true,id:'rental-smoke',org_id:'org-smoke',device_id:'device-smoke',code:body.code,category:'reguler',remaining_seconds:3600,expiry_at:null,client_label:'Smoke',updated_at:new Date().toISOString(),offline_lease_until:new Date(Date.now()+7200000).toISOString()}; break;
      case '/device/session/start': data={ok:true,session_id:'session-smoke',status:'active',remaining_seconds:3600,deadline_at:new Date(Date.now()+3600000).toISOString()}; break;
      case '/device/session/end': data={ok:true,session_id:'session-smoke',status:'ended',remaining_seconds:body.remainingSeconds}; break;
      case '/device/rental/release': data={ok:true,released:true}; break;
      case '/device/sync-cursor': data={ok:true,cursor:new Date(Date.now()-1000).toISOString(),serverTime:new Date().toISOString()}; break;
      case '/device/pull': data={ok:true,rentalAccounts:[],cursor:new Date().toISOString(),fullSnapshot:false}; break;
      case '/device/sync': data={ok:true,acceptedSourceEventIds:(body.events||[]).map(x=>x.sourceEventId),conflictSourceEventIds:[],inserted:(body.events||[]).length,serverTime:new Date().toISOString()}; break;
      case '/device/alert': data={ok:true,accepted:true,duplicate:false}; break;
      case '/device/disconnect': data={ok:true,revoked_tokens:1,already_disconnected:false}; break;
      default: data={ok:false,error:'UNEXPECTED_ROUTE:'+route};
    }
    return {ok:true,status:200,json:async()=>data};
  };
  const window={
    crypto:{randomUUID:()=> '00000000-0000-4000-8000-000000000001'},addEventListener:noop,
    electronAPI:{syncWatchdogCredentials:async()=>({ok:true}),getWolNetworkInfo:async()=>({})},
    v11GetUsers:()=>users,v11GetActiveCode:()=>null,v11GetUser:code=>users[code],
    v11PersistPulledUsers:next=>{const copy={...next};for(const k of Object.keys(users))delete users[k];Object.assign(users,copy);},
    v11ApplyRemoteCommand:async()=>({ok:true}),showCustomModal:noop
  };
  const sandbox={
    window,document,localStorage,fetch,URL,AbortController,
    crypto:{randomUUID:()=> '00000000-0000-4000-8000-000000000002'},
    setTimeout:timer,clearTimeout:noop,setInterval:timer,clearInterval:noop,
    Date,Math,Number,String,Object,Array,Set,Map,JSON,Promise,Error,
    console:{log:noop,info:noop,warn:noop,error:noop}
  };
  vm.runInNewContext(source,sandbox,{filename:'v11-cloud.js'});
  return {window,values,localStorage,calls,setCommand(){command=true;}};
}
async function flush(){await Promise.resolve();await new Promise(r=>setImmediate(r));await Promise.resolve();}

test('uses the verified Redmi Worker by default and blocks insecure remote URLs',()=>{
  const h=harness();
  assert.equal(h.window.v11GetApiBaseUrl(),WORKER);
  assert.throws(()=>h.window.v11SetApiBaseUrl('http://192.168.1.10:8788'),/HTTPS/);
  assert.throws(()=>h.window.v11SetApiBaseUrl('https://user:pass@example.com'),/kredensial/);
  assert.equal(h.window.v11SetApiBaseUrl('http://127.0.0.1:8788'),'http://127.0.0.1:8788');
});

test('pairing, rental lifecycle, sync, alerts, heartbeat, ACK and disconnect call DB Android API',async()=>{
  const h=harness();
  await h.window.v11EnrollDevice();await flush();
  const paired=JSON.parse(h.values.get('billing_v11_cloud_config'));
  assert.equal(paired.deviceId,'device-smoke');
  const enroll=h.calls.find(x=>x.route==='/device/enroll');
  assert.ok(enroll);assert.equal(enroll.body.token,undefined);
  assert.equal((await h.window.v11CheckFreeTestPermission()).enabled,true);
  const pausePolicy=await h.window.v11CheckStopPausePermission();
  assert.equal(pausePolicy.allow_stop_pause,true);
  assert.equal((await h.window.v11LookupRentalCode('TEST01')).ok,true);
  assert.equal((await h.window.v11StartRentalSession('TEST01')).sessionId,'session-smoke');
  assert.equal((await h.window.v11EndRentalSession('TEST01',3500)).ok,true);
  assert.equal((await h.window.v11ReleaseRentalLease('TEST01')).released,true);
  h.localStorage.setItem('billing_v11_sync_cursor',new Date(Date.now()-1000).toISOString());
  h.window.v11QueueLocalRentalDelete('TEST01');await flush();
  assert.equal((await h.window.v11ManualSync()).ok,true);
  await h.window.v11EmitAdminAlert('session_stopped','Smoke ended',{code:'TEST01'});
  h.setCommand();h.window.v11HeartbeatNow('smoke');await flush();
  assert.ok(h.calls.some(x=>x.route==='/device/ack'));
  for(const route of ['/device/test-policy','/device/session-control-policy','/device/rental/lookup','/device/session/start','/device/session/end','/device/rental/release','/device/sync-cursor','/device/pull','/device/sync','/device/alert','/device/heartbeat','/device/ack'])
    assert.ok(h.calls.some(x=>x.route===route),'missing '+route);
  for(const call of h.calls.filter(x=>x.route.startsWith('/device/')&&x.route!='/device/enroll'))
    assert.equal(call.headers.authorization,'Bearer device-token-smoke');
  h.localStorage.setItem('billing_v11_outbox',JSON.stringify([{sourceEventId:'keep'}]));
  h.localStorage.setItem('billing_v11_session_outbox',JSON.stringify([{sourceEventId:'keep-session'}]));
  const result=await h.window.v11DisconnectDevice();
  assert.equal(result.remoteDisconnected,true);
  assert.ok(h.calls.some(x=>x.route==='/device/disconnect'));
  assert.equal(h.values.has('billing_v11_cloud_config'),false);
  assert.equal(h.values.has('billing_v11_outbox'),true);
  assert.equal(h.values.has('billing_v11_session_outbox'),true);
});

test('offline session-end remains queued locally without a paired device',async()=>{
  const h=harness(), result=await h.window.v11EndRentalSession('TEST01',1234);
  assert.equal(result.pending,true);
  const q=JSON.parse(h.values.get('billing_v11_session_outbox'));
  assert.equal(q.length,1);assert.equal(q[0].code,'TEST01');assert.equal(q[0].remainingSeconds,1234);
});
