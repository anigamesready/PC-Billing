from pathlib import Path
import json
import re

ROOT = Path(".")
html_path = ROOT / "index.html"
cloud_path = ROOT / "v11-cloud.js"
package_path = ROOT / "package.json"
lock_path = ROOT / "package-lock.json"
version_path = ROOT / "VERSION.txt"

html = html_path.read_text(encoding="utf-8")
cloud = cloud_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))
lock = json.loads(lock_path.read_text(encoding="utf-8"))

if "function v12ShutdownScheduleFromAdmin(" in html or "shutdownTimer:window.v11GetShutdownTimerStatus?.()||null" in cloud:
    raise SystemExit("Scheduled shutdown timer patch already exists; refusing to apply it twice.")
if package.get("version") != "12.2.3" or lock.get("version") != "12.2.3":
    raise SystemExit("Unexpected PC source baseline; expected package.json and package-lock.json version 12.2.3.")

identity_anchor = "  const fp=u=>JSON.stringify(";
identity_helper = "  window.v11GetDeviceIdentity=function(){const c=read()||{};return {deviceId:String(c.deviceId||''),clientId:String(c.clientId||''),orgId:String(c.orgId||'')}};\n";
if cloud.count(identity_anchor) != 1:
    raise SystemExit("Device identity helper anchor mismatch; refusing to patch the wrong cloud file.")
if "window.v11GetDeviceIdentity=function()" not in cloud:
    cloud = cloud.replace(identity_anchor, identity_helper + identity_anchor, 1)

bridge_anchor = "        window.v11ApplyRemoteCommand = async (command, payload = {}) => {"
if html.count(bridge_anchor) != 1:
    raise SystemExit("Live Electron command bridge anchor mismatch; refusing to patch a non-live renderer.")

helpers = r"""
        // V12.1.8 scheduled shutdown. Scheduling is separate from executing the Windows action.
        const V12_SHUTDOWN_TIMER_KEY = 'billing_shutdown_timer_v12';
        let v12ShutdownTickBusy = false;
        function v12ReadShutdownTimer() {
            try {
                const value = JSON.parse(localStorage.getItem(V12_SHUTDOWN_TIMER_KEY) || 'null');
                return value && typeof value === 'object' && !Array.isArray(value) ? value : null;
            } catch (_) { return null; }
        }
        function v12SaveShutdownTimer(value) {
            try {
                if (value) localStorage.setItem(V12_SHUTDOWN_TIMER_KEY, JSON.stringify(value));
                else localStorage.removeItem(V12_SHUTDOWN_TIMER_KEY);
                return true;
            } catch (e) {
                try { writeSystemLog('Timer shutdown gagal disimpan: ' + (e?.message || e), 'ERROR'); } catch (_) {}
                return false;
            }
        }
        function v12ShutdownRentalBlocker() {
            const active = String(typeof currentActiveCode !== 'undefined' ? currentActiveCode || '' : '').trim();
            if (active) return 'Shutdown ditolak: sesi rental ' + active + ' masih aktif.';
            const paused = String(localStorage.getItem('billing_remote_paused_code') || '').trim();
            if (paused) return 'Shutdown ditolak: sesi rental ' + paused + ' masih paused/terbuka.';
            try {
                const persisted = JSON.parse(localStorage.getItem('billing_active_session_v10') || 'null');
                if (persisted && String(persisted.code || '').trim() && Number(persisted.deadlineMs || 0) > Date.now()) {
                    return 'Shutdown ditolak: sesi rental tersimpan masih berlangsung.';
                }
            } catch (_) {}
            return '';
        }
        function v12ShutdownStateForHeartbeat() {
            const current = v12ReadShutdownTimer();
            if (!current) return null;
            return {
                state: String(current.state || 'unknown'),
                scheduleId: current.scheduleId || null,
                deadlineAt: current.deadlineAt || null,
                updatedAt: current.updatedAt || current.createdAt || null,
                message: String(current.message || '').slice(0, 180),
                shutdownInitiator: String(current.shutdownInitiator || '').slice(0, 64) || null,
                shutdownReason: String(current.shutdownReason || '').slice(0, 96) || null,
                plannedShutdown: current.plannedShutdown === true,
                expectedDisconnect: current.expectedDisconnect === true,
                timerStopped: current.timerStopped === true,
                lastShutdownInitiator: String(current.lastShutdownInitiator || '').slice(0, 64) || null,
                lastShutdownAt: current.lastShutdownAt || null
            };
        }
        window.v11GetShutdownTimerStatus = v12ShutdownStateForHeartbeat;
        // Consume a prior planned-shutdown marker when the PC starts again so a later
        // unrelated power loss is not misclassified as an Admin-initiated shutdown.
        (function v12ReconcilePreviousAdminShutdownOnBoot() {
            const previous = v12ReadShutdownTimer();
            if (!previous || previous.expectedDisconnect !== true ||
                !['admin_shutdown_requested','shutdown_requested'].includes(previous.state)) return;
            const now = new Date().toISOString();
            v12SaveShutdownTimer({...previous, state:'previous_admin_shutdown',
                lastShutdownInitiator: previous.shutdownInitiator || null,
                lastShutdownAt: previous.updatedAt || previous.requestedAt || now,
                plannedShutdown:false, expectedDisconnect:false, timerStopped:true,
                updatedAt:now,
                message:'PC kembali menyala setelah shutdown terencana; penanda putus koneksi sebelumnya ditutup.'});
        })();
        async function v12ShutdownScheduleFromAdmin(payload = {}) {
            const identity = window.v11GetDeviceIdentity?.() || {};
            if (!identity.deviceId || String(payload.targetDeviceId || '') !== String(identity.deviceId)) {
                return { ok:false, message:'SHUTDOWN_TARGET_ID_MISMATCH: perintah timer ditujukan ke PC lain.' };
            }
            const scheduleId = String(payload.scheduleId || '').trim();
            const deadlineMs = Date.parse(String(payload.deadlineAt || ''));
            const now = Date.now();
            if (!scheduleId || scheduleId.length > 120) return { ok:false, message:'ID timer shutdown tidak valid.' };
            if (!Number.isFinite(deadlineMs) || deadlineMs < now + 5000 || deadlineMs > now + 24 * 60 * 60000 + 60000) {
                return { ok:false, message:'Waktu timer shutdown tidak valid atau sudah kedaluwarsa.' };
            }
            const current = v12ReadShutdownTimer();
            if (current?.state === 'scheduled' && current.scheduleId === scheduleId) {
                return { ok:true, message:'Timer shutdown ini sudah terjadwal.', scheduleId:scheduleId, deadlineAt:current.deadlineAt };
            }
            const blocker = v12ShutdownRentalBlocker();
            if (blocker) {
                const rejected = { state:'blocked_active_session', scheduleId:scheduleId,
                    deadlineAt:new Date(deadlineMs).toISOString(), updatedAt:new Date().toISOString(), message:blocker };
                v12SaveShutdownTimer(rejected);
                try { writeSystemLog(blocker, 'ERROR'); } catch (_) {}
                return { ok:false, message:blocker, state:rejected.state };
            }
            const state = { state:'scheduled', scheduleId:scheduleId,
                deadlineAt:new Date(deadlineMs).toISOString(), createdAt:new Date().toISOString(),
                updatedAt:new Date().toISOString(), targetDeviceId:String(payload.targetDeviceId || ''),
                targetDeviceName:String(payload.targetDeviceName || '').slice(0, 100),
                message:'Timer shutdown aktif; pemeriksaan sesi rental tetap berjalan.' };
            if (!v12SaveShutdownTimer(state)) return { ok:false, message:'Timer shutdown gagal disimpan secara lokal.' };
            try { writeSystemLog('Timer shutdown dijadwalkan untuk ' + (state.targetDeviceName || 'PC') + ' pada ' + state.deadlineAt + '.'); } catch (_) {}
            return { ok:true, message:'Timer shutdown diterima PC dan countdown dimulai.', scheduleId:scheduleId, deadlineAt:state.deadlineAt };
        }
        async function v12CancelScheduledShutdown(payload = {}) {
            const identity = window.v11GetDeviceIdentity?.() || {};
            if (!identity.deviceId || String(payload.targetDeviceId || '') !== String(identity.deviceId)) {
                return { ok:false, message:'SHUTDOWN_TARGET_ID_MISMATCH: pembatalan ditujukan ke PC lain.' };
            }
            const current = v12ReadShutdownTimer();
            const requestedId = String(payload.scheduleId || '').trim();
            if (current?.state === 'scheduled' && requestedId && current.scheduleId !== requestedId) {
                return { ok:false, message:'ID timer berbeda. Refresh status dan coba batalkan timer yang terbaru.' };
            }
            const canceled = { state:'canceled', scheduleId:current?.scheduleId || requestedId || null,
                deadlineAt:current?.deadlineAt || null, updatedAt:new Date().toISOString(),
                targetDeviceId:String(payload.targetDeviceId || current?.targetDeviceId || ''),
                targetDeviceName:String(payload.targetDeviceName || current?.targetDeviceName || '').slice(0, 100),
                message:'Timer shutdown dibatalkan oleh Admin.' };
            v12SaveShutdownTimer(canceled);
            try { writeSystemLog('Timer shutdown dibatalkan oleh Admin.'); } catch (_) {}
            return { ok:true, message:'Timer shutdown berhasil dibatalkan.', state:'canceled' };
        }
        async function v12CheckScheduledShutdown() {
            if (v12ShutdownTickBusy) return;
            const current = v12ReadShutdownTimer();
            if (!current || current.state !== 'scheduled') return;
            const deadlineMs = Date.parse(String(current.deadlineAt || ''));
            if (!Number.isFinite(deadlineMs)) {
                v12SaveShutdownTimer({...current, state:'shutdown_failed', updatedAt:new Date().toISOString(), message:'Deadline timer rusak; shutdown tidak dijalankan.'});
                try { writeSystemLog('Deadline timer shutdown rusak; tindakan diblokir.', 'ERROR'); } catch (_) {}
                return;
            }
            if (Date.now() < deadlineMs) return;
            v12ShutdownTickBusy = true;
            try {
                const blocker = v12ShutdownRentalBlocker();
                if (blocker) {
                    const blocked = {...current, state:'blocked_active_session', updatedAt:new Date().toISOString(), message:blocker};
                    v12SaveShutdownTimer(blocked);
                    try { writeSystemLog(blocker + ' Timer shutdown dibatalkan.', 'ERROR'); } catch (_) {}
                    return;
                }
                const requested = {...current, state:'shutdown_requested', updatedAt:new Date().toISOString(),
                    shutdownInitiator:'admin_apk_scheduled_timer',
                    shutdownReason:'scheduled_timer_elapsed',
                    plannedShutdown:true, expectedDisconnect:true, timerStopped:true,
                    message:'Countdown timer Admin selesai; shutdown terencana diteruskan ke Windows.'};
                v12SaveShutdownTimer(requested);
                try { writeSystemLog('Countdown timer shutdown selesai; memanggil aksi Windows.'); } catch (_) {}
                if (typeof window.electronAPI?.powerAction !== 'function') {
                    const failed = {...requested, state:'shutdown_failed', updatedAt:new Date().toISOString(), message:'Bridge aksi Windows tidak tersedia.'};
                    v12SaveShutdownTimer(failed);
                    try { writeSystemLog(failed.message, 'ERROR'); } catch (_) {}
                    return;
                }
                const result = await window.electronAPI.powerAction('shutdown');
                if (result?.ok === false) {
                    const failed = {...requested, state:'shutdown_failed', updatedAt:new Date().toISOString(),
                        message:String(result.message || 'Windows menolak shutdown.').slice(0, 180)};
                    v12SaveShutdownTimer(failed);
                    try { writeSystemLog(failed.message, 'ERROR'); } catch (_) {}
                }
            } catch (e) {
                const failed = {...current, state:'shutdown_failed', updatedAt:new Date().toISOString(),
                    message:String(e?.message || e || 'Shutdown gagal.').slice(0, 180)};
                v12SaveShutdownTimer(failed);
                try { writeSystemLog(failed.message, 'ERROR'); } catch (_) {}
            } finally {
                v12ShutdownTickBusy = false;
            }
        }
        if (!window.__v12ShutdownTimerInterval) {
            window.__v12ShutdownTimerInterval = window.setInterval(function () {
                void v12CheckScheduledShutdown();
            }, 1000);
        }
"""

html = html.replace(bridge_anchor, helpers + "\n" + bridge_anchor, 1)
command_anchor = "            const cmd = String(command || '').trim();"
if html.count(command_anchor) != 1:
    raise SystemExit("Live command normalization anchor mismatch; refusing to patch.")
command_interceptor = r"""            if (cmd === 'cancel_shutdown_timer') {
                return await v12CancelScheduledShutdown(payload);
            }
            if (cmd === 'schedule_shutdown') {
                return await v12ShutdownScheduleFromAdmin(payload);
            }
            if (cmd === 'shutdown') {
                const shutdownBlocker = v12ShutdownRentalBlocker();
                if (shutdownBlocker) {
                    const rejected = {
                        state:'shutdown_failed',
                        updatedAt:new Date().toISOString(),
                        shutdownInitiator:'admin_apk_direct',
                        shutdownReason:'direct_shutdown_from_admin_apk',
                        plannedShutdown:false,
                        expectedDisconnect:false,
                        timerStopped:true,
                        message:String(shutdownBlocker).slice(0,180)
                    };
                    v12SaveShutdownTimer(rejected);
                    return {ok:false, message:shutdownBlocker, shutdownInitiator:'admin_apk_direct',
                        plannedShutdown:false, expectedDisconnect:false, timerStopped:true};
                }

                // Stop the scheduled countdown first. Continue only when its state is persisted.
                const priorTimer = v12ReadShutdownTimer();
                const stopped = await v12CancelScheduledShutdown({
                    scheduleId: priorTimer?.scheduleId || null,
                    source: 'admin-apk-direct-shutdown'
                });
                if (stopped?.ok !== true) {
                    return {ok:false, message:'Shutdown dibatalkan karena timer shutdown gagal dihentikan.'};
                }
                const requestedAt = new Date().toISOString();
                const expectedShutdown = {
                    state:'admin_shutdown_requested',
                    scheduleId:null,
                    previousScheduleId:priorTimer?.scheduleId || null,
                    deadlineAt:null,
                    targetDeviceName:priorTimer?.targetDeviceName || null,
                    updatedAt:requestedAt,
                    shutdownInitiator:'admin_apk_direct',
                    shutdownReason:'direct_shutdown_from_admin_apk',
                    plannedShutdown:true,
                    expectedDisconnect:true,
                    timerStopped:true,
                    message:'Shutdown langsung diminta melalui Admin APK; putus koneksi setelah perintah ini adalah shutdown terencana.'
                };
                if (!v12SaveShutdownTimer(expectedShutdown)) {
                    return {ok:false, message:'Shutdown dibatalkan karena status shutdown terencana gagal disimpan.'};
                }
                try {
                    writeSystemLog('Shutdown langsung diminta Admin APK; timer dihentikan sebelum shutdown.');
                } catch (_) {}
                if (typeof window.electronAPI?.powerAction !== 'function') {
                    const failed = {...expectedShutdown, state:'shutdown_failed', updatedAt:new Date().toISOString(),
                        plannedShutdown:false, expectedDisconnect:false, message:'Bridge aksi Windows tidak tersedia.'};
                    v12SaveShutdownTimer(failed);
                    return {ok:false, message:failed.message, shutdownInitiator:'admin_apk_direct', plannedShutdown:false};
                }
                try {
                    const actionResult = await window.electronAPI.powerAction('shutdown');
                    if (actionResult?.ok === false) {
                        const failed = {...expectedShutdown, state:'shutdown_failed', updatedAt:new Date().toISOString(),
                            plannedShutdown:false, expectedDisconnect:false,
                            message:String(actionResult.message || 'Windows menolak shutdown.').slice(0, 180)};
                        v12SaveShutdownTimer(failed);
                        return {ok:false, message:failed.message, shutdownInitiator:'admin_apk_direct', plannedShutdown:false};
                    }
                    // Returned fields are included in the existing device command acknowledgement.
                    return {ok:true, message:'Timer dihentikan, lalu shutdown langsung diminta oleh Admin APK.',
                        shutdownInitiator:'admin_apk_direct', shutdownReason:'direct_shutdown_from_admin_apk',
                        plannedShutdown:true, expectedDisconnect:true, timerStopped:true, requestedAt:requestedAt};
                } catch (e) {
                    const failed = {...expectedShutdown, state:'shutdown_failed', updatedAt:new Date().toISOString(),
                        plannedShutdown:false, expectedDisconnect:false,
                        message:String(e?.message || e || 'Shutdown gagal.').slice(0, 180)};
                    v12SaveShutdownTimer(failed);
                    return {ok:false, message:failed.message, shutdownInitiator:'admin_apk_direct', plannedShutdown:false};
                }
            }
"""
html = html.replace(command_anchor, command_anchor + "\n" + command_interceptor, 1)

# Extend the existing heartbeat metadata without adding an extra RPC or polling loop.
hb_start = cloud.find("async function heartbeat(){")
hb_end = cloud.find("async function reconcileLocalRentals()", hb_start)
if hb_start < 0 or hb_end < 0 or hb_end <= hb_start:
    raise SystemExit("Heartbeat function boundary not found in v11-cloud.js.")
heartbeat = cloud[hb_start:hb_end]
metadata_match = re.search(r"\bmetadata\s*:\s*\{", heartbeat)
if not metadata_match:
    raise SystemExit("Heartbeat metadata object not found; refusing to add a second network request.")
open_brace = heartbeat.find("{", metadata_match.start())
depth = 0
quote = None
escaped = False
line_comment = False
block_comment = False
close_brace = -1
i = open_brace
while i < len(heartbeat):
    ch = heartbeat[i]
    nxt = heartbeat[i + 1] if i + 1 < len(heartbeat) else ""
    if line_comment:
        if ch == "\n":
            line_comment = False
        i += 1
        continue
    if block_comment:
        if ch == "*" and nxt == "/":
            block_comment = False
            i += 2
        else:
            i += 1
        continue
    if quote:
        if escaped:
            escaped = False
        elif ch == "\\":
            escaped = True
        elif ch == quote:
            quote = None
        i += 1
        continue
    if ch == "/" and nxt == "/":
        line_comment = True
        i += 2
        continue
    if ch == "/" and nxt == "*":
        block_comment = True
        i += 2
        continue
    if ch in ("'", '"', chr(96)):
        quote = ch
        i += 1
        continue
    if ch == "{":
        depth += 1
    elif ch == "}":
        depth -= 1
        if depth == 0:
            close_brace = i
            break
    i += 1
if close_brace < 0:
    raise SystemExit("Could not safely parse heartbeat metadata object.")
metadata_body = heartbeat[open_brace + 1:close_brace]
if "shutdownTimer:" not in metadata_body:
    prefix = "" if not metadata_body.strip() else ("" if metadata_body.rstrip().endswith(",") else ",")
    heartbeat = heartbeat[:close_brace] + prefix + "shutdownTimer:window.v11GetShutdownTimerStatus?.()||null" + heartbeat[close_brace:]
    cloud = cloud[:hb_start] + heartbeat + cloud[hb_end:]

new_app = "APP='V12.3.0-FREE-TEST-GATE-SHUTDOWN-TIMER'"
if new_app not in cloud:
    if "APP='V12.2.3-GLOBAL-ROUTE-READ-WRITE'" not in cloud:
        raise SystemExit("Unexpected v11-cloud.js APP marker; refusing to bump the cloud build identity.")
    cloud = cloud.replace("APP='V12.2.3-GLOBAL-ROUTE-READ-WRITE'", new_app, 1)

html, html_version_count = re.subn(r"(const APP_VERSION = )'[^']+';", lambda m: m.group(1) + "'V12.3.0-FREE-TEST-GATE-SHUTDOWN-TIMER';", html, count=1)
if html_version_count != 1 or "const APP_VERSION = 'V12.3.0-FREE-TEST-GATE-SHUTDOWN-TIMER';" not in html:
    raise SystemExit("Could not update the active runtime build version.")

for token in (
    "function v12ShutdownScheduleFromAdmin(",
    "function v12CancelScheduledShutdown(",
    "function v12ShutdownRentalBlocker(",
    "window.v11GetShutdownTimerStatus = v12ShutdownStateForHeartbeat;",
    "if (cmd === 'schedule_shutdown')",
    "if (cmd === 'cancel_shutdown_timer')",
    "billing_remote_paused_code",
):
    if token not in html:
        raise SystemExit("Shutdown timer regression check failed: missing " + token)
if "shutdownTimer:window.v11GetShutdownTimerStatus?.()||null" not in cloud:
    raise SystemExit("PC shutdown timer status is not included in the existing heartbeat metadata.")
if "renderer.js is not loaded by Electron." not in html:
    raise SystemExit("Live Electron runtime marker missing after patch.")

package["version"] = "12.3.0"
package["description"] = "AniGames Billing V12.3.0: server-authoritative FREE TEST gate and target-bound shutdown timer with cancel/status, built on the V12.2.3 dual-DB runtime"
if isinstance(package.get("build"), dict):
    package["build"]["productName"] = "AniGames Billing V12.3.0"
lock["version"] = "12.3.0"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.3.0"

html_path.write_text(html, encoding="utf-8")
cloud_path.write_text(cloud, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text("AniGames Billing PC V12.3.0 — target-bound shutdown timer and status\n", encoding="utf-8")
print("PASS: added persisted scheduled shutdown, owner command schedule/cancel interception, heartbeat status, and active-rental guards; PC version 12.1.8.")
