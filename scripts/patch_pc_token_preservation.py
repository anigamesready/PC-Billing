from pathlib import Path
import json

ROOT = Path(".")
cloud_path = ROOT / "v11-cloud.js"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
cloud = cloud_path.read_text(encoding="utf-8")

# A database route mismatch or temporary token desynchronization must not destroy
# local pairing state, the sync cursor, dirty rental records, or the durable alert outbox.
invalid_old = "if(String(e?.message||'').includes('INVALID_DEVICE_TOKEN')){localStorage.removeItem(CLOUD_KEY);localStorage.removeItem(SYNC_CURSOR_KEY);localStorage.removeItem(SYNC_DIRTY_KEY);if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeatTimer=null;status('☁️ PAIRING TERPUTUS • Harus pairing ulang');setPcState('pending','STATUS PC: BELUM TERHUBUNG');return}"
invalid_new = "if(String(e?.message||'').includes('INVALID_DEVICE_TOKEN')){localStorage.setItem('billing_v11_token_rejected_hold','1');if(heartbeatTimer)clearInterval(heartbeatTimer);heartbeatTimer=null;status('☁️ TOKEN DITOLAK • pairing, cursor, data lokal, dan antrean dipertahankan. Tekan Sinkron Manual untuk mencoba ulang atau putuskan pairing secara manual.');setPcState('offline','STATUS PC: TOKEN CLOUD DITOLAK • DATA LOKAL DIPERTAHANKAN');return}"
if invalid_old in cloud:
    cloud = cloud.replace(invalid_old, invalid_new, 1)
elif invalid_new not in cloud:
    raise SystemExit("INVALID_DEVICE_TOKEN handling anchor mismatch; refusing to patch")

# Do not auto-retry indefinitely after token rejection. Manual sync/enrollment can recover it.
start_old = "function start(){if(heartbeatTimer)clearInterval(heartbeatTimer);prepareSyncSchema();"
start_guard = "if(localStorage.getItem('billing_v11_token_rejected_hold')==='1'){status('☁️ TOKEN DITOLAK • Tidak mengulang request otomatis; pairing dan antrean tetap tersimpan.');setPcState('offline','STATUS PC: TOKEN CLOUD DITOLAK • DATA LOKAL DIPERTAHANKAN');return;}"
if start_guard not in cloud:
    if cloud.count(start_old) != 1:
        raise SystemExit("cloud start anchor mismatch; refusing to patch")
    cloud = cloud.replace(start_old, start_old + start_guard, 1)

# Clear the hold only after a successful heartbeat or successful new enrollment.
success_anchor = "const syncReady=typeof window.v11ApplyRemoteCommand==='function'&&typeof window.v11PersistPulledUsers==='function';"
if "localStorage.removeItem('billing_v11_token_rejected_hold');" + success_anchor not in cloud:
    if cloud.count(success_anchor) != 1:
        raise SystemExit("heartbeat success anchor mismatch; refusing to patch")
    cloud = cloud.replace(success_anchor, "localStorage.removeItem('billing_v11_token_rejected_hold');" + success_anchor, 1)

enroll_anchor = "save({token:d.token,deviceId:d.device_id,orgId:d.org_id,clientId:d.client_id});resumeCloudAuthoritative="
if "localStorage.removeItem('billing_v11_token_rejected_hold');" + enroll_anchor not in cloud:
    if cloud.count(enroll_anchor) != 1:
        raise SystemExit("device enrollment success anchor mismatch; refusing to patch")
    cloud = cloud.replace(enroll_anchor, "localStorage.removeItem('billing_v11_token_rejected_hold');" + enroll_anchor, 1)

# Prevent the manual-sync handler continuing into a full sync when the retry heartbeat
# was rejected. The state remains intact and only one explicit user-triggered retry occurs.
manual_guard_anchor = "const wasResume=resumeCloudAuthoritative;if(!wasResume)await heartbeat();const full=await fullRentalSnapshot({preferCloud:wasResume});"
manual_guard_new = "const wasResume=resumeCloudAuthoritative;if(!wasResume)await heartbeat();if(localStorage.getItem('billing_v11_token_rejected_hold')==='1')throw new Error('Token cloud masih ditolak; pairing dan antrean dipertahankan.');const full=await fullRentalSnapshot({preferCloud:wasResume});"
if manual_guard_new not in cloud:
    if cloud.count(manual_guard_anchor) != 1:
        raise SystemExit("manual sync guard anchor mismatch; refusing to patch")
    cloud = cloud.replace(manual_guard_anchor, manual_guard_new, 1)

# Restart heartbeat only after an explicit manual sync completes successfully.
tick = chr(96)
dollar = chr(36)
manual_anchor = "status(" + tick + "☁️ ONLINE • DB ↔ PC sinkronisasi selesai • " + dollar + "{full.count} data" + tick + ");return {ok:true,count:full.count}"
manual_new = "status(" + tick + "☁️ ONLINE • DB ↔ PC sinkronisasi selesai • " + dollar + "{full.count} data" + tick + ");if(!heartbeatTimer)start();return {ok:true,count:full.count}"
if manual_new not in cloud:
    if cloud.count(manual_anchor) != 1:
        raise SystemExit("manual sync recovery anchor mismatch; refusing to patch")
    cloud = cloud.replace(manual_anchor, manual_new, 1)

cloud_path.write_text(cloud, encoding="utf-8")
for token in (
    "billing_v11_token_rejected_hold",
    "DATA LOKAL DIPERTAHANKAN",
    "localStorage.removeItem(CLOUD_KEY)",
    "localStorage.removeItem(SYNC_DIRTY_KEY)",
):
    if token == "localStorage.removeItem(CLOUD_KEY)" or token == "localStorage.removeItem(SYNC_DIRTY_KEY)":
        if token in cloud:
            raise SystemExit("Unsafe token rejection data wipe remains in source.")
    elif token not in cloud:
        raise SystemExit("Safety regression token missing: " + token)

# Version is applied after the existing log/alert patch runs in the build workflow.
package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))
if package.get("version") not in {"12.1.1", "12.1.2", "12.1.3"}:
    raise SystemExit("Unexpected package.json version; refusing to bump blindly")
package["version"] = "12.1.3"
lock["version"] = "12.1.3"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.1.3"
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
(ROOT / "VERSION.txt").write_text("V12.1.3-PAIRING-PRESERVE-DUAL-DB-SAFETY\n", encoding="utf-8")
print("Applied token-rejection safety hold; pairing, cursor, dirty set and alert outbox remain intact. PC version 12.1.3.")
