from pathlib import Path
import json

ROOT = Path('.')
FILES = {k: ROOT / v for k, v in {
    'main': 'main.js', 'preload': 'preload.js', 'cloud': 'v11-cloud.js',
    'index': 'index.html', 'renderer': 'renderer.js', 'package': 'package.json',
    'lock': 'package-lock.json', 'version': 'VERSION.txt'
}.items()}
for key in ('main', 'preload', 'cloud', 'index', 'renderer', 'package'):
    if not FILES[key].is_file():
        raise SystemExit(f'Missing required PC source: {FILES[key]}')

src = {k: FILES[k].read_text(encoding='utf-8') for k in ('main', 'preload', 'cloud', 'index', 'renderer')}
pkg = json.loads(FILES['package'].read_text(encoding='utf-8'))
lock = json.loads(FILES['lock'].read_text(encoding='utf-8')) if FILES['lock'].is_file() else None
OLD = 'V12.3.7-SINGLE-INSTANCE-GUARD'
NEW = 'V12.3.8-AUTO-WOL-LAN-MAC'

if NEW in src['index'] and NEW in src['cloud'] and pkg.get('version') == '12.3.8':
    print('PASS: PC V12.3.8 automatic LAN MAC heartbeat patch already applied')
    raise SystemExit(0)
if pkg.get('version') != '12.3.7' or OLD not in src['index'] or OLD not in src['cloud'] or OLD not in src['renderer']:
    raise SystemExit(f'Expected exact V12.3.7 source baseline; got package version {pkg.get("version")}')
if pkg.get('build', {}).get('appId') != 'com.anigames.billing.v12test':
    raise SystemExit('Persistent Electron appId mismatch; refusing source modification.')
if pkg.get('build', {}).get('productName') != 'AniGames Billing V12.3.3':
    raise SystemExit('Persistent Electron productName mismatch; refusing source modification.')
if "ipcMain.handle('wake-on-lan', async (event, payload = {}) => {" not in src['main']:
    raise SystemExit('Existing outbound WOL IPC handler is missing.')
if "wakeOnLan: (payload = {}) => ipcRenderer.invoke('wake-on-lan'" not in src['preload']:
    raise SystemExit('Existing preload WOL bridge is missing.')
if 'async function heartbeatOnce()' not in src['cloud'] or "request('/device/heartbeat'" not in src['cloud']:
    raise SystemExit('Cloud heartbeat function anchor is missing.')

# Read-only IPC: expose only the wired adapter identity; never expose arbitrary interfaces or sockets.
main_anchor = "// V12.3.6-WOL-RELAY: outbound-only WOL sender; renderer cannot open arbitrary sockets."
main_ipc = r'''// V12.3.8-AUTO-WOL-LAN-MAC: expose verified wired-NIC details for this paired PC heartbeat.
ipcMain.handle('get-wol-network-info', async (event) => {
    if (!mainWindow || mainWindow.isDestroyed() || event.sender !== mainWindow.webContents) return null;
    const os = require('os');
    const rejectedName = /wifi|wi-fi|wireless|wlan|bluetooth|tailscale|tunnel|vpn|virtual|vmware|hyper-v|loopback|hamachi|zerotier|utun|tap|teredo/i;
    const wiredName = /ethernet|\blan\b|\bgbe\b|gigabit|realtek.*pci|intel.*ethernet|killer.*ethernet/i;
    const candidates = [];
    for (const [adapterName, entries] of Object.entries(os.networkInterfaces() || {})) {
        if (!wiredName.test(adapterName) || rejectedName.test(adapterName)) continue;
        for (const entry of (Array.isArray(entries) ? entries : [])) {
            if (!entry || entry.internal || !(entry.family === 'IPv4' || entry.family === 4)) continue;
            const ipv4 = String(entry.address || '').trim();
            const netmask = String(entry.netmask || '').trim();
            const mac = String(entry.mac || '').trim().replace(/[:-]/g, '').toUpperCase();
            if (!/^[0-9A-F]{12}$/.test(mac) || mac === '000000000000' || mac === 'FFFFFFFFFFFF') continue;
            if (!ipv4 || ipv4.startsWith('169.254.') || ipv4.startsWith('127.')) continue;
            candidates.push({ adapterName, lanMac: mac.match(/.{2}/g).join(':'), ipv4, netmask });
        }
    }
    candidates.sort((a, b) => {
        const score = x => (/^ethernet/i.test(x.adapterName) ? 0 : /realtek.*pci|intel.*ethernet|gbe|gigabit/i.test(x.adapterName) ? 1 : 2);
        return score(a) - score(b) || a.adapterName.localeCompare(b.adapterName);
    });
    const chosen = candidates[0];
    return chosen ? { ...chosen, observedAt: new Date().toISOString(), source: 'wired-network-interface' } : null;
});

'''
if src['main'].count(main_anchor) != 1:
    raise SystemExit('Main IPC WOL insertion anchor mismatch.')
src['main'] = src['main'].replace(main_anchor, main_ipc + main_anchor, 1)

preload_anchor = "    wakeOnLan: (payload = {}) => ipcRenderer.invoke('wake-on-lan', { mac: String(payload.mac || '') }),"
if src['preload'].count(preload_anchor) != 1:
    raise SystemExit('Preload WOL bridge insertion anchor mismatch.')
src['preload'] = src['preload'].replace(preload_anchor, preload_anchor + "\n    getWolNetworkInfo: () => ipcRenderer.invoke('get-wol-network-info'),", 1)

# The target PC sends its own physical LAN MAC with every regular heartbeat.
# Missing adapters are omitted, never written as null, so the last good MAC stays in metadata.
heartbeat_anchor = "const targetCode=activeCode||pausedCode;const u=targetCode?window.v11GetUser?.(targetCode):null;const d=await request('/device/heartbeat'"
heartbeat_insert = "const targetCode=activeCode||pausedCode;const u=targetCode?window.v11GetUser?.(targetCode):null;let wolNetworkInfo=null;try{wolNetworkInfo=await window.electronAPI?.getWolNetworkInfo?.()}catch(_){};const d=await request('/device/heartbeat'"
if src['cloud'].count(heartbeat_anchor) != 1:
    raise SystemExit('Heartbeat metadata insertion anchor mismatch.')
src['cloud'] = src['cloud'].replace(heartbeat_anchor, heartbeat_insert, 1)
metadata_anchor = "shutdownTimer:window.v11GetShutdownTimerStatus?.()||null}},{retries:2,timeoutMs:7000});"
metadata_insert = "shutdownTimer:window.v11GetShutdownTimerStatus?.()||null,...(wolNetworkInfo?.lanMac?{wolLanMac:wolNetworkInfo.lanMac,wolLanAdapter:wolNetworkInfo.adapterName||null,wolLanIpv4:wolNetworkInfo.ipv4||null,wolLanObservedAt:wolNetworkInfo.observedAt||new Date().toISOString()}: {})}},{retries:2,timeoutMs:7000});"
if src['cloud'].count(metadata_anchor) != 1:
    raise SystemExit('Heartbeat metadata object insertion anchor mismatch.')
src['cloud'] = src['cloud'].replace(metadata_anchor, metadata_insert, 1)

# Keep the WOL relay implementation; only synchronize visible/build heartbeat version markers.
for key in ('index', 'renderer', 'cloud'):
    if OLD not in src[key]:
        raise SystemExit(f'Expected V12.3.7 marker missing from {key}.')
    src[key] = src[key].replace(OLD, NEW)
src['main'] = src['main'].replace("appVersion: 'V12.3.7-watchdog'", "appVersion: 'V12.3.8-watchdog'", 1)
if "appVersion: 'V12.3.8-watchdog'" not in src['main']:
    raise SystemExit('Watchdog appVersion update failed.')

pkg['version'] = '12.3.8'
pkg['description'] = 'AniGames Billing V12.3.8: paired PC automatically reports wired LAN MAC for Wake-on-LAN; pairing, billing, rentals and app identity preserved'
if lock is not None:
    lock['version'] = '12.3.8'
    if isinstance(lock.get('packages'), dict) and isinstance(lock['packages'].get(''), dict):
        lock['packages']['']['version'] = '12.3.8'

for key, body in src.items():
    FILES[key].write_text(body, encoding='utf-8')
FILES['package'].write_text(json.dumps(pkg, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
if lock is not None:
    FILES['lock'].write_text(json.dumps(lock, indent=2, ensure_ascii=False) + '\n', encoding='utf-8')
FILES['version'].write_text(
    'AniGames Billing PC V12.3.8 — paired PC reports the active wired LAN MAC through existing heartbeat metadata for automatic Wake-on-LAN targeting. Existing appId, productName, local userData, pairing identity, billing, rental and shutdown features retained.\n',
    encoding='utf-8'
)

checks = {
    'read-only wired NIC IPC': "ipcMain.handle('get-wol-network-info'" in src['main'],
    'IPC sender validation': "event.sender !== mainWindow.webContents" in src['main'],
    'Wi-Fi/VPN excluded': 'wifi|wi-fi|wireless|wlan' in src['main'],
    'preload exposes metadata only': "getWolNetworkInfo: () => ipcRenderer.invoke('get-wol-network-info')" in src['preload'],
    'heartbeat asks for NIC metadata': 'getWolNetworkInfo?.()' in src['cloud'],
    'heartbeat publishes automatic MAC': 'wolLanMac:wolNetworkInfo.lanMac' in src['cloud'],
    'heartbeat preserves absence': 'wolNetworkInfo?.lanMac?' in src['cloud'],
    'existing WOL handler remains': "ipcMain.handle('wake-on-lan'" in src['main'] and "if (cmd === 'wake')" in src['index'],
    'stable appId preserved': pkg['build']['appId'] == 'com.anigames.billing.v12test',
    'stable productName preserved': pkg['build']['productName'] == 'AniGames Billing V12.3.3',
    'version synchronized': pkg['version'] == '12.3.8' and NEW in src['index'] and NEW in src['renderer'] and NEW in src['cloud'],
}
for label, passed in checks.items():
    if not passed:
        raise SystemExit('Assertion failed: ' + label)
    print('PASS:', label)
print('PASS: V12.3.8 automatic wired MAC reporting patch; no DB schema, pairing ID, billing, rental, or app identity changes.')
