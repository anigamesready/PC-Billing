from pathlib import Path
import json

ROOT = Path(".")
cloud_path = ROOT / "v11-cloud.js"
index_path = ROOT / "index.html"
renderer_path = ROOT / "renderer.js"
package_path = ROOT / "package.json"
version_path = ROOT / "VERSION.txt"

MARKER = "V12.3.1-HEARTBEAT-WRITE-OPTIMIZATION"
OLD_MARKER = "V12.3.0-FREE-TEST-GATE-SHUTDOWN-TIMER"
cloud = cloud_path.read_text(encoding="utf-8")
index = index_path.read_text(encoding="utf-8")
renderer = renderer_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))

def replace_once(source, old, new, label):
    count = source.count(old)
    if count != 1:
        raise SystemExit(f"{label} anchor mismatch: expected one, found {count}")
    return source.replace(old, new, 1)

if MARKER in cloud:
    if package.get("version") != "12.3.1":
        raise SystemExit("V12.3.1 marker/package version mismatch")
    for token in ["resolveDbRoute(attempt>0)", "heartbeatInFlight", "window.v11HeartbeatNow", "free_test_disabled"]:
        if token not in cloud:
            raise SystemExit("V12.3.1 marker exists but runtime change is missing: " + token)
    print("PASS: V12.3.1 heartbeat/session performance patch already applied")
    raise SystemExit(0)

if package.get("version") != "12.3.0" or OLD_MARKER not in cloud:
    raise SystemExit(f"Expected exact V12.3.0 base, got package {package.get('version')}")
if "V12.3.0-TEST-POLICY-PREFLIGHT" not in index or "window.v11CheckFreeTestPermission" not in index:
    raise SystemExit("V12.3.0 FREE TEST preflight missing; refusing unknown source")

# Cache the previously verified route for normal operations; retries re-read the authority.
cloud = replace_once(cloud, "const DB_ROUTE_CACHE_MS=5000;", "const DB_ROUTE_CACHE_MS=30000;", "PC route cache")
cloud = replace_once(
    cloud,
    "const route=await resolveDbRoute(true),cfg=DB_ENDPOINTS[route.target]",
    "const route=await resolveDbRoute(attempt>0),cfg=DB_ENDPOINTS[route.target]",
    "PC request route refresh",
)

# Do not retry deterministic HTTP 4xx business errors (notably FREE_TEST_DISABLED).
http_old = "if(!r.ok){const detail=d.error||d.message||('HTTP '+r.status);if(r.status===401&&/invalid api key|UNAUTHORIZED_INVALID_API_KEY/i.test(String(detail)))throw new Error('API key Supabase ditolak oleh gateway. Periksa versi key aplikasi.');throw new Error(detail)}return d"
http_new = "if(!r.ok){const detail=d.error||d.message||('HTTP '+r.status);if(r.status===401&&/invalid api key|UNAUTHORIZED_INVALID_API_KEY/i.test(String(detail))){const keyError=new Error('API key Supabase ditolak oleh gateway. Periksa versi key aplikasi.');keyError.status=r.status;keyError.retryable=false;throw keyError}const err=new Error(detail);err.status=r.status;err.retryable=(r.status===408||r.status===425||r.status===429||r.status>=500);throw err}return d"
cloud = replace_once(cloud, http_old, http_new, "PC HTTP error policy")
catch_old = "catch(e){last=e;if(attempt<retries){dbRouteCheckedAt=0;await new Promise(res=>setTimeout(res,350*(attempt+1)));}}finally{clearTimeout(timer)}"
catch_new = "catch(e){last=e;if(e?.retryable===false)break;if(attempt<retries){dbRouteCheckedAt=0;await new Promise(res=>setTimeout(res,350*(attempt+1)));}}finally{clearTimeout(timer)}"
cloud = replace_once(cloud, catch_old, catch_new, "PC request retry loop")

# Serialize heartbeat/sync/pull. If several status transitions happen while busy, coalesce to one fresh read.
cloud = replace_once(cloud, "async function heartbeat(){", "async function heartbeatOnce(){", "PC heartbeat implementation")
wrapper = """  // V12.3.1-HEARTBEAT-WRITE-OPTIMIZATION: serialize polling and coalesce event-triggered updates.
  let heartbeatInFlight=false,heartbeatPending=false;
  async function heartbeat(){
    if(heartbeatInFlight){heartbeatPending=true;return;}
    heartbeatInFlight=true;
    try{await heartbeatOnce();}
    finally{
      heartbeatInFlight=false;
      if(heartbeatPending){heartbeatPending=false;setTimeout(()=>{void heartbeat();},0);}
    }
  }
  window.v11HeartbeatNow=(reason='event')=>{
    if(heartbeatInFlight){heartbeatPending=true;return;}
    void heartbeat();
  };
"""
cloud = replace_once(
    cloud,
    "  async function reconcileLocalRentals(){",
    wrapper + "  async function reconcileLocalRentals(){",
    "PC heartbeat wrapper insertion",
)

# When policy is OFF and an old client reports a new trial, do not fail the whole heartbeat:
# the server returns a denial flag, liveness and command delivery still succeed.
heartbeat_response_anchor = "},{retries:2,timeoutMs:7000});localStorage.removeItem('billing_v11_token_rejected_hold');"
heartbeat_response_replacement = """},{retries:2,timeoutMs:7000});if(d.free_test_disabled===true&&window.v11GetActiveCode?.()==='__TEST10__'){try{await window.v11ApplyRemoteCommand?.('stop',{reason:'FREE_TEST_DISABLED'})}catch(_){}status('☁️ FREE TEST ditolak oleh server • sesi lokal dihentikan');try{window.alert(d.free_test_message||'Silahkan hubungi admin untuk melakukan tes 082298316902')}catch(_){}}localStorage.removeItem('billing_v11_token_rejected_hold');"""
cloud = replace_once(cloud, heartbeat_response_anchor, heartbeat_response_replacement, "Heartbeat denied free-test response")

# Start/stop transitions immediately publish current state instead of waiting up to 15 seconds.
test_start_old = "            currentActiveCode = TEST_SESSION_CODE;\n            timerDeadlineMs = Date.now() + 600000;\n            persistActiveSession();\n            writeSystemLog('FREE TEST 10 menit dimulai dari halaman awal.');"
test_start_new = "            currentActiveCode = TEST_SESSION_CODE;\n            timerDeadlineMs = Date.now() + 600000;\n            persistActiveSession();\n            window.v11HeartbeatNow?.('session_started');\n            writeSystemLog('FREE TEST 10 menit dimulai dari halaman awal.');"
index = replace_once(index, test_start_old, test_start_new, "Live free-test start event")

# Avoid JS template literal characters in this patch-script source by building the exact anchor.
rental_log = "            writeSystemLog(" + chr(96) + "Sesi " + "$" + "{inputCode} dimulai." + chr(96) + ");"
rental_start_old = "            persistActiveSession();\n" + rental_log
rental_start_new = "            persistActiveSession();\n            window.v11HeartbeatNow?.('session_started');\n" + rental_log
index = replace_once(index, rental_start_old, rental_start_new, "Live rental start event")

stop_old = "            currentActiveCode = null;\n            document.getElementById('timer-display').innerText = '00:00:00';"
stop_new = "            currentActiveCode = null;\n            window.v11HeartbeatNow?.('session_stopped');\n            document.getElementById('timer-display').innerText = '00:00:00';"
index = replace_once(index, stop_old, stop_new, "Live rental stop event")

# Keep all app-visible version identity aligned with the live index.html runtime.
cloud = replace_once(cloud, "// BUILD_ID: V12.2.3-GLOBAL-ROUTE-READ-WRITE", "// BUILD_ID: " + MARKER, "PC cloud build marker")
cloud = replace_once(cloud, "APP='" + OLD_MARKER + "'", "APP='" + MARKER + "'", "PC cloud app version")
index = replace_once(index, "const APP_VERSION = '" + OLD_MARKER + "';", "const APP_VERSION = '" + MARKER + "';", "Live index app version")
footer_old = '<span id="app-version-code">V12.2.3-GLOBAL-ROUTE-READ-WRITE</span>'
footer_new = '<span id="app-version-code">' + MARKER + '</span>'
index = replace_once(index, footer_old, footer_new, "Visible PC version")
renderer = replace_once(renderer, "const APP_VERSION = 'V12.2.3-GLOBAL-ROUTE-READ-WRITE';", "const APP_VERSION = '" + MARKER + "';", "Renderer version")

package["version"] = "12.3.1"
package["description"] = "AniGames Billing V12.3.1: cached validated DB routing, serialized event-triggered heartbeat, immediate rental transitions, event-only heartbeat history writes and bounded account/session writes"
if isinstance(package.get("build"), dict):
    package["build"]["productName"] = "AniGames Billing V12.3.1"

lock_path = cloud_path.parent / "package-lock.json"
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = "12.3.1"
    if isinstance(lock.get("packages"), dict) and isinstance(lock.get("packages").get(""), dict):
        lock["packages"][""]["version"] = "12.3.1"
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

cloud_path.write_text(cloud, encoding="utf-8")
index_path.write_text(index, encoding="utf-8")
renderer_path.write_text(renderer, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
version_path.write_text(
    "AniGames Billing PC V12.3.1 — validated route cache; serialized heartbeat; immediate start/stop events; event-only heartbeat history; bounded account/session writes; deterministic 4xx handling.\n",
    encoding="utf-8",
)

for token in [
    MARKER, "const DB_ROUTE_CACHE_MS=30000;", "resolveDbRoute(attempt>0)",
    "err.retryable=(r.status===408||r.status===425||r.status===429||r.status>=500)",
    "if(e?.retryable===false)break", "async function heartbeatOnce(){", "async function heartbeat(){",
    "let heartbeatInFlight=false,heartbeatPending=false", "window.v11HeartbeatNow=",
    "d.free_test_disabled===true", "window.v11GetActiveCode?.()==='__TEST10__'",
]:
    if token not in cloud:
        raise SystemExit("V12.3.1 cloud assertion missing: " + token)
for token in [
    "window.v11HeartbeatNow?.('session_started')", "window.v11HeartbeatNow?.('session_stopped')",
    "V12.3.0-TEST-POLICY-PREFLIGHT", "window.v11CheckFreeTestPermission",
]:
    if token not in index:
        raise SystemExit("V12.3.1 live index assertion missing: " + token)
if package.get("version") != "12.3.1" or footer_new not in index:
    raise SystemExit("V12.3.1 version markers do not agree")
print("PASS: PC V12.3.1 route caching/retry policy, serialized heartbeat, immediate rental transitions, and visible version identity patched.")
