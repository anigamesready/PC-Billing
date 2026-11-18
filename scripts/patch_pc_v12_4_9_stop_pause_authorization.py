from pathlib import Path
import json

ROOT=Path(".")
HTML=ROOT/"index.html"
CLOUD=ROOT/"v11-cloud.js"
RENDERER=ROOT/"renderer.js"
PACKAGE=ROOT/"package.json"
LOCK=ROOT/"package-lock.json"
VERSION=ROOT/"VERSION.txt"
OLD="V12.4.8-TIMER-SIZE-SYNC"
MARKER="V12.4.9-STOP-PAUSE-AUTHORIZATION"

html=HTML.read_text(encoding="utf-8")
cloud=CLOUD.read_text(encoding="utf-8")
renderer=RENDERER.read_text(encoding="utf-8")
package=json.loads(PACKAGE.read_text(encoding="utf-8"))
lock=json.loads(LOCK.read_text(encoding="utf-8"))
if MARKER in html and "window.v11CheckStopPausePermission" in cloud:
    print("PASS: PC V12.4.9 Stop/Pause policy already applied")
    raise SystemExit(0)
if html.count("const APP_VERSION = '"+OLD+"';")!=1:
    raise SystemExit("PC V12.4.8 index version anchor mismatch")
if renderer.count(OLD)!=1:
    raise SystemExit("PC V12.4.8 renderer version anchor mismatch")
if "APP='V12.4.8-DB-ANDROID'" not in cloud:
    raise SystemExit("PC DB Android app version anchor mismatch")
if package.get("version")!="12.4.8" or lock.get("version")!="12.4.8":
    raise SystemExit("PC package metadata is not V12.4.8")

# Read policy from the existing paired-device API only when the renter clicks.
cloud_anchor="  window.v11CheckFreeTestPermission=async function(){"
if cloud.count(cloud_anchor)!=1:
    raise SystemExit("PC Free Test API helper anchor mismatch")
helper="""  window.v11CheckStopPausePermission=async function(){
    const c=read();
    if(!c||!c.token)throw new Error('PAIRING_REQUIRED');
    const d=await request('/device/session-control-policy',{token:c.token},{retries:1,timeoutMs:7000});
    if(!d||typeof d.enabled!=='boolean')throw new Error(d?.error||d?.message||'BILLING_STOP_PAUSE_POLICY_UNAVAILABLE');
    return d;
  };
"""
cloud=cloud.replace(cloud_anchor,helper+cloud_anchor,1)
cloud=cloud.replace("APP='V12.4.8-DB-ANDROID'","APP='V12.4.9-DB-ANDROID'",1)
cloud=cloud.replace("// BUILD_ID: V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG","// BUILD_ID: "+MARKER,1)
renderer=renderer.replace(OLD,MARKER,1)

old_handlers="""        function pauseStopSessionFromTimer(event) {
            if (event) { event.preventDefault(); event.stopPropagation(); }
            stopActiveSession();
        }

        function finishSessionFromTimer(event) {
            if (event) { event.preventDefault(); event.stopPropagation(); }
            stopActiveSession();
        }
"""
new_handlers="""        // V12.4.9: renter PAUSE/STOP and X share one server-authorized gate.
        // Admin commands and automatic expiry still call pauseSession() directly.
        let stopPauseAuthorizationBusy = false;
        function setStopPauseAuthorizationVisual(locked) {
            const buttons = [
                document.getElementById('timer-pause-stop'),
                document.getElementById('timer-finish')
            ].filter(Boolean);
            for (const button of buttons) {
                button.classList.toggle('authorization-locked', locked === true);
                button.setAttribute('aria-disabled', locked === true ? 'true' : 'false');
                button.style.opacity = locked === true ? '0.58' : '';
                button.style.filter = locked === true ? 'grayscale(1)' : '';
                button.title = locked === true
                    ? 'Akses PAUSE / STOP dikunci oleh Admin. Hubungi Admin untuk meminta akses.'
                    : (button.id === 'timer-finish' ? 'Akhiri sesi' : 'Pause / Stop sesi');
            }
        }

        async function authorizeStopPauseAndStop(event) {
            if (event) { event.preventDefault(); event.stopPropagation(); }
            if (!currentActiveCode || stopPauseAuthorizationBusy) return;
            stopPauseAuthorizationBusy = true;
            try {
                if (typeof window.v11CheckStopPausePermission !== 'function') {
                    throw new Error('BILLING_STOP_PAUSE_POLICY_UNAVAILABLE');
                }
                const policy = await window.v11CheckStopPausePermission();
                const allowed = policy?.allow_stop_pause === true || policy?.enabled === true;
                setStopPauseAuthorizationVisual(!allowed);
                if (!allowed) {
                    showCustomModal(
                        'Akses PAUSE / STOP sedang dikunci oleh Admin. Silakan hubungi Admin untuk meminta akses dibuka. Timer rental tetap berjalan.',
                        'AKSES PAUSE / STOP DIKUNCI', false, '🔒'
                    );
                    return;
                }
                stopActiveSession();
            } catch (error) {
                setStopPauseAuthorizationVisual(true);
                showCustomModal(
                    'Izin PAUSE / STOP tidak dapat diverifikasi dari server. Demi keamanan, tombol tetap dikunci dan timer tetap berjalan. Silakan hubungi Admin.',
                    'IZIN TIDAK TERSEDIA', true, '🔒'
                );
                console.warn('[Billing] Stop/Pause authorization unavailable:', error?.message || error);
            } finally {
                stopPauseAuthorizationBusy = false;
            }
        }

        function pauseStopSessionFromTimer(event) {
            void authorizeStopPauseAndStop(event);
        }

        function finishSessionFromTimer(event) {
            void authorizeStopPauseAndStop(event);
        }
"""
if html.count(old_handlers)!=1:
    raise SystemExit("PC renter timer button handler anchor mismatch; pauseSession() left untouched")
html=html.replace(old_handlers,new_handlers,1)
html=html.replace("const APP_VERSION = '"+OLD+"';","const APP_VERSION = '"+MARKER+"';",1)

if "function stopActiveSession() {\n            if (!currentActiveCode) return;\n            pauseSession(false);\n        }" not in html:
    raise SystemExit("PC stopActiveSession anchor changed")
if "function pauseSession(showNotif = false)" not in html or "if (remaining <= 0)" not in html:
    raise SystemExit("PC automatic timer expiry / session implementation missing")
if html.count("pauseSession(false);")<3:
    raise SystemExit("Expected the existing timer-expiry and remote/admin pauseSession paths")
if "timer-pause-stop" not in html or "timer-finish" not in html:
    raise SystemExit("PC renter timer buttons missing")

package["version"]="12.4.9"
package["description"]="AniGames Billing V12.4.9: Owner-controlled PAUSE/STOP permission; preserves V12.4.8 timer geometry and V12.4.7 fullscreen safety."
lock["version"]="12.4.9"
if isinstance(lock.get("packages"),dict) and isinstance(lock["packages"].get(""),dict):
    lock["packages"][""]["version"]="12.4.9"

HTML.write_text(html,encoding="utf-8")
CLOUD.write_text(cloud,encoding="utf-8")
RENDERER.write_text(renderer,encoding="utf-8")
PACKAGE.write_text(json.dumps(package,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
LOCK.write_text(json.dumps(lock,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
VERSION.write_text(MARKER+"\n",encoding="utf-8")

for token in [MARKER,"authorizeStopPauseAndStop","setStopPauseAuthorizationVisual","Akses PAUSE / STOP sedang dikunci oleh Admin","pauseStopSessionFromTimer(event)","finishSessionFromTimer(event)"]:
    if token not in html: raise SystemExit("PC feature assertion missing: "+token)
if "request('/device/session-control-policy'" not in cloud or "window.v11CheckStopPausePermission" not in cloud:
    raise SystemExit("PC DB Android policy API helper missing")
if MARKER not in renderer or "// BUILD_ID: "+MARKER not in cloud:
    raise SystemExit("PC V12.4.9 runtime markers missing")
print("PASS: PC V12.4.9 renter PAUSE/STOP + X gated, API fail-closed, timer expiry and Admin paths preserved.")
