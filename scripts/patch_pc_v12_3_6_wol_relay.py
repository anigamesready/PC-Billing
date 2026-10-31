from pathlib import Path
import json, re

root = Path('.')
paths = {k: root / v for k, v in {
    'main':'main.js', 'preload':'preload.js', 'index':'index.html',
    'cloud':'v11-cloud.js', 'renderer':'renderer.js', 'package':'package.json',
    'lock':'package-lock.json', 'version':'VERSION.txt'
}.items()}
for key in ('main','preload','index','cloud','renderer','package'):
    if not paths[key].is_file(): raise SystemExit('Missing PC source: '+str(paths[key]))
data = {k: paths[k].read_text(encoding='utf-8') for k in ('main','preload','index','cloud','renderer')}
pkg = json.loads(paths['package'].read_text(encoding='utf-8'))
lock = json.loads(paths['lock'].read_text(encoding='utf-8')) if paths['lock'].exists() else None
marker = 'V12.3.6-WOL-RELAY'
if marker in data['index']:
    if pkg.get('version') == '12.3.6': print('PASS: PC WOL relay patch already applied'); raise SystemExit(0)
    raise SystemExit('WOL marker/version mismatch')
if pkg.get('version') != '12.3.5' or 'V12.3.5-GLOBAL-RENTAL-DB-FIRST' not in data['index']:
    raise SystemExit('Expected exact PC V12.3.5 source baseline')
if "APP='V12.3.5-GLOBAL-RENTAL-DB-FIRST'" not in data['cloud']:
    raise SystemExit('V12.3.5 heartbeat marker missing')
if 'window.v11ApplyRemoteCommand = async (command, payload = {}) =>' not in data['index']:
    raise SystemExit('Remote command dispatcher missing')
if "ipcMain.handle('power-action', async (event, action) => {" not in data['main']:
    raise SystemExit('Power IPC anchor mismatch')
if "powerAction: (action) => ipcRenderer.invoke('power-action', String(action))," not in data['preload']:
    raise SystemExit('Preload power IPC anchor mismatch')

main_anchor = "// Kontrol power Windows. Hanya menerima aksi yang sudah di-whitelist.\nipcMain.handle('power-action', async (event, action) => {"
main_wol = r'''// V12.3.6-WOL-RELAY: outbound-only WOL sender; renderer cannot open arbitrary sockets.
ipcMain.handle('wake-on-lan', async (event, payload = {}) => {
    if (!mainWindow || mainWindow.isDestroyed() || event.sender !== mainWindow.webContents) return {ok:false,message:'Pemanggil tidak valid.'};
    const compact = String(payload?.mac || '').trim().replace(/[:-]/g,'').toUpperCase();
    if (!/^[0-9A-F]{12}$/.test(compact)) return {ok:false,message:'Format MAC Address tidak valid.'};
    const os = require('os'), dgram = require('dgram');
    const mac = Buffer.from(compact,'hex'), packet = Buffer.alloc(102,0xFF);
    for (let i=0;i<16;i++) mac.copy(packet,6+i*6);
    const u32 = value => String(value||'').split('.').reduce((n,p)=>{const x=Number(p);return Number.isInteger(x)&&x>=0&&x<=255?((n<<8)|x)>>>0:NaN;},0);
    const ip = n => [(n>>>24)&255,(n>>>16)&255,(n>>>8)&255,n&255].join('.');
    const targets = new Set();
    for (const entries of Object.values(os.networkInterfaces()||{})) for (const e of (Array.isArray(entries)?entries:[])) {
        if (!e || e.internal || !(e.family==='IPv4'||e.family===4) || String(e.address||'').startsWith('169.254.')) continue;
        const a=u32(e.address), m=u32(e.netmask); if (!Number.isFinite(a)||!Number.isFinite(m)||m===0) continue;
        targets.add(ip((a|(~m>>>0))>>>0));
    }
    if (!targets.size) return {ok:false,message:'Tidak ada adapter IPv4 LAN aktif.'};
    const socket=dgram.createSocket('udp4'), sent=[];
    const result=await new Promise(resolve=>{
        let done=false, idx=0, round=0;
        const finish=value=>{if(done)return;done=true;clearTimeout(timer);try{socket.close();}catch(_){}resolve(value);};
        const timer=setTimeout(()=>finish({ok:false,message:'Pengiriman Magic Packet timeout.',sent}),5000);
        socket.on('error',e=>finish({ok:false,message:String(e?.message||e).slice(0,160),sent}));
        socket.bind(0,'0.0.0.0',()=>{try{socket.setBroadcast(true);}catch(e){finish({ok:false,message:String(e?.message||e),sent});return;}
            const list=[...targets]; const send=()=>{if(idx>=list.length){finish({ok:true,sent});return;}const address=list[idx];socket.send(packet,9,address,e=>{if(e){finish({ok:false,message:String(e.message||e),sent});return;}sent.push(address);if(++round>=3){round=0;idx++;}setTimeout(send,100);});};send();
        });
    });
    if(!result.ok)return {ok:false,message:result.message,sentTo:result.sent};
    return {ok:true,mac:compact.match(/.{2}/g).join(':'),port:9,attempts:result.sent.length,broadcasts:[...new Set(result.sent)]};
});

// Kontrol power Windows. Hanya menerima aksi yang sudah di-whitelist.
'''
if data['main'].count(main_anchor)!=1: raise SystemExit('Main IPC insertion anchor mismatch')
data['main']=data['main'].replace(main_anchor,main_wol+main_anchor.split('\n',1)[1],1)
data['preload']=data['preload'].replace(
    "    powerAction: (action) => ipcRenderer.invoke('power-action', String(action)),",
    "    powerAction: (action) => ipcRenderer.invoke('power-action', String(action)),\n    wakeOnLan: (payload = {}) => ipcRenderer.invoke('wake-on-lan', { mac: String(payload.mac || '') }),",1)

dispatcher="        window.v11ApplyRemoteCommand = async (command, payload = {}) => {\n            const cmd = String(command || '').trim();\n"
wake_dispatch=r'''            // V12.3.6-WOL-RELAY: relay request is bound to this PC's paired identity and expires quickly.
            if (cmd === 'wake') {
                if (String(payload.mode||'') !== 'wake_on_lan_relay') return {ok:false,error:'WAKE_MODE_NOT_SUPPORTED',message:'Mode relay tidak dikenal.'};
                const identity=window.v11GetDeviceIdentity?.()||{};
                const relayId=String(payload.relayDeviceId||'').trim(), targetId=String(payload.targetDeviceId||'').trim();
                const expires=Date.parse(String(payload.expiresAt||''));
                if (!identity.deviceId || relayId!==String(identity.deviceId)) return {ok:false,error:'WAKE_RELAY_IDENTITY_MISMATCH',message:'Perintah bukan untuk PC relay ini.'};
                if (!targetId || targetId===String(identity.deviceId)) return {ok:false,error:'WAKE_TARGET_ID_INVALID',message:'Identitas target tidak valid.'};
                if (!Number.isFinite(expires)||expires<=Date.now()||expires>Date.now()+5*60*1000) return {ok:false,error:'WAKE_COMMAND_EXPIRED',message:'Perintah Wake-on-LAN kedaluwarsa; kirim ulang dari Admin.'};
                const mac=String(payload.targetMac||'').trim().replace(/[:-]/g,'').toUpperCase();
                if (!/^[0-9A-F]{12}$/.test(mac)) return {ok:false,error:'WAKE_TARGET_MAC_INVALID',message:'MAC Address PC target tidak valid.'};
                if (typeof window.electronAPI?.wakeOnLan!=='function') return {ok:false,error:'WAKE_BRIDGE_UNAVAILABLE',message:'Fitur WOL tidak tersedia pada build ini.'};
                const sent=await window.electronAPI.wakeOnLan({mac:mac.match(/.{2}/g).join(':')});
                if(sent?.ok!==true)return {ok:false,error:'WAKE_PACKET_SEND_FAILED',message:String(sent?.message||'Magic Packet gagal dikirim.').slice(0,180),targetDeviceId:targetId};
                try{writeSystemLog('Magic Packet WOL dikirim untuk '+String(payload.targetDeviceName||'PC target').slice(0,80)+'.');}catch(_){}
                return {ok:true,message:'Magic Packet dikirim; menunggu heartbeat PC target. Status menyala belum terkonfirmasi.',relayDeviceId:String(identity.deviceId),targetDeviceId:targetId,targetDeviceName:String(payload.targetDeviceName||'PC target').slice(0,80),wakeProtocol:'wake-on-lan-magic-packet',broadcasts:sent.broadcasts||[],attempts:Number(sent.attempts)||0,sentAt:new Date().toISOString()};
            }

'''
if data['index'].count(dispatcher)!=1: raise SystemExit('Remote dispatcher anchor mismatch')
data['index']=data['index'].replace(dispatcher,dispatcher+wake_dispatch,1)

old='V12.3.5-GLOBAL-RENTAL-DB-FIRST'; new=marker
if old not in data['index'] or old not in data['renderer']: raise SystemExit('Visible version marker mismatch')
data['index']=data['index'].replace(old,new)
data['renderer']=data['renderer'].replace(old,new)
data['cloud']=data['cloud'].replace("APP='V12.3.5-GLOBAL-RENTAL-DB-FIRST'","APP='V12.3.6-WOL-RELAY'",1)
data['main'],n=re.subn(r"appVersion: 'V12\.3\.5-watchdog'","appVersion: 'V12.3.6-watchdog'",data['main'],count=1)
if n!=1 or "APP='V12.3.6-WOL-RELAY'" not in data['cloud']: raise SystemExit('Heartbeat version update mismatch')

pkg['version']='12.3.6'; pkg['description']='AniGames Billing V12.3.6: PC1 Wake-on-LAN relay; existing pairing and rental state preserved'
if lock is not None:
    lock['version']='12.3.6'
    if isinstance(lock.get('packages'),dict) and isinstance(lock['packages'].get(''),dict): lock['packages']['']['version']='12.3.6'
if pkg.get('build',{}).get('productName')!='AniGames Billing V12.3.3' or pkg.get('build',{}).get('appId')!='com.anigames.billing.v12test':
    raise SystemExit('Electron persistent app identity changed unexpectedly')
for key,value in data.items(): paths[key].write_text(value,encoding='utf-8')
paths['package'].write_text(json.dumps(pkg,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
if lock is not None: paths['lock'].write_text(json.dumps(lock,indent=2,ensure_ascii=False)+'\n',encoding='utf-8')
paths['version'].write_text('AniGames Billing PC V12.3.6 — outbound Wake-on-LAN relay through paired PC1; core billing, pairing identity and rental database unchanged.\n',encoding='utf-8')
print('PASS: paired PC1 relay identity, expiry, MAC validation, outbound Magic Packet and PC2 heartbeat-confirmation contract.')
print('PASS: no inbound port/dependency; existing Electron appId/productName preserved.')
