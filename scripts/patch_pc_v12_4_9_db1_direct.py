#!/usr/bin/env python3
"""V12.4.9 recovery patch: pin PC Billing device traffic to Supabase DB1 directly.

This patch removes client-side dual-project route resolution and shared gateway
routing only from the PC device transport. It preserves the existing DB1 API,
local pairing/token state, outbox, timer, admin UI, and watchdog flow.
"""
from pathlib import Path
import json
import re
import sys

ROOT = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
CLOUD = ROOT / "v11-cloud.js"
MAIN = ROOT / "main.js"
INDEX = ROOT / "index.html"
RENDERER = ROOT / "renderer.js"
PACKAGE = ROOT / "package.json"
LOCK = ROOT / "package-lock.json"
VERSION = ROOT / "VERSION.txt"

required = [CLOUD, MAIN, INDEX, RENDERER, PACKAGE, LOCK, VERSION]
missing = [str(p.name) for p in required if not p.is_file()]
if missing:
    raise SystemExit("PC_DB1_DIRECT_REQUIRED_FILES_MISSING:" + ",".join(missing))

cloud = CLOUD.read_text(encoding="utf-8")

# Replace only the audited dual-project route block; fail closed on source drift.
start_marker = "  // Both keys are public anon JWTs. Runtime chooses a target only from read-only, project-verified route status."
end_marker = "  let heartbeatTimer=null"
if cloud.count(start_marker) != 1 or cloud.count(end_marker) != 1:
    raise SystemExit("PC_DB1_DIRECT_ROUTE_BLOCK_ANCHOR_MISMATCH")
start = cloud.index(start_marker)
end = cloud.index(end_marker, start)
if end <= start:
    raise SystemExit("PC_DB1_DIRECT_ROUTE_BLOCK_BOUNDARY_INVALID")
primary_url = "https://wzkjpycjizexxcxrfdvr.supabase.co"
primary_anon = "eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJpc3MiOiJzdXBhYmFzZSIsInJlZiI6Ind6a2pweWNqaXpleHhjeHJmZHZyIiwicm9sZSI6ImFub24iLCJpYXQiOjE3OTEwMzc0OTUsImV4cCI6MjEwNjYxMzQ5NX0.lxjSt7CqWDJhKItPi1ckVRIcc-kM7etMzxTu3txANaI"
replacement = (
    "  // V12.4.9 DB1 Direct: this PC build is pinned to DB1. No DB2 route checks or gateway selection.\n"
    f"  const DB1_API_URL='{primary_url}/functions/v1/ani-games-api';\n"
    f"  const DB1_ANON_KEY='{primary_anon}';\n"
)
cloud = cloud[:start] + replacement + cloud[end:]

# Replace the one transport function used by enrollment, heartbeat, sync, and rental sessions.
pattern = re.compile(r"  async function request\(path,body,opts=\{\}\)\{[^\r\n]*\}")
request_body = r'''  async function request(path,body,opts={}){
    const retries=Math.max(0,Number(opts.retries??0));
    const clean=String(path||'').replace(/^\/+/,''),url=DB1_API_URL+'/'+clean;
    let last;
    for(let attempt=0;attempt<=retries;attempt++){
      const ctl=new AbortController(),timer=setTimeout(()=>ctl.abort(),Number(opts.timeoutMs||8000));
      try{
        const response=await fetch(url,{
          method:'POST',
          headers:{'content-type':'application/json','apikey':DB1_ANON_KEY},
          body:JSON.stringify(body||{}),
          signal:ctl.signal,
          cache:'no-store'
        });
        const data=await response.json().catch(()=>({}));
        if(!response.ok){
          const detail=data.error||data.message||('HTTP '+response.status);
          const error=new Error(detail);error.status=response.status;
          error.retryable=response.status===408||response.status===425||response.status===429||response.status>=500;
          if(response.status===401&&/invalid api key|UNAUTHORIZED_INVALID_API_KEY/i.test(String(detail)))
            error.retryable=false;
          throw error;
        }
        return data;
      }catch(error){
        last=error;
        if(error?.retryable===false)break;
        if(attempt<retries)await new Promise(resolve=>setTimeout(resolve,350*(attempt+1)));
      }finally{clearTimeout(timer)}
    }
    throw last||new Error('DB1_API_NETWORK_ERROR');
  }'''
cloud, count = pattern.subn(request_body, cloud, count=1)
if count != 1:
    raise SystemExit(f"PC_DB1_DIRECT_REQUEST_FUNCTION_MISMATCH:{count}")

# Version/runtime markers in the same source family.
cloud = cloud.replace("// BUILD_ID: V12.3.3-RESILIENT-OFFLINE-TEST-WATCHDOG", "// BUILD_ID: V12.4.9-DB1-DIRECT-RECOVERY", 1)
cloud = cloud.replace("APP='V12.3.8-AUTO-WOL-LAN-MAC'", "APP='V12.4.9-DB1-DIRECT'", 1)

# Existing manual unpair and schema-upgrade paths may intentionally clear a token/cursor.
# The critical regression guard is that an API/route error must not auto-clear them.
catch_start_marker = "}catch(e){if(String(e?.message||'').includes('INVALID_DEVICE_TOKEN')"
catch_end_marker = "  // V12.3.1-HEARTBEAT-WRITE-OPTIMIZATION"
if catch_start_marker not in cloud or catch_end_marker not in cloud:
    raise SystemExit("PC_DB1_DIRECT_TOKEN_ERROR_HOLD_HANDLER_MISSING")
error_handler = cloud[cloud.index(catch_start_marker):cloud.index(catch_end_marker)]
if "localStorage.setItem('billing_v11_token_rejected_hold','1')" not in error_handler:
    raise SystemExit("PC_DB1_DIRECT_TOKEN_ERROR_HOLD_HANDLER_MISSING")
if "localStorage.removeItem(CLOUD_KEY)" in error_handler or "localStorage.removeItem(SYNC_CURSOR_KEY)" in error_handler or "localStorage.removeItem(SYNC_DIRTY_KEY)" in error_handler:
    raise SystemExit("PC_DB1_DIRECT_TOKEN_ERROR_WOULD_CLEAR_LOCAL_STATE")

# Update app metadata while retaining the existing Electron appId for in-place replacement.
package = json.loads(PACKAGE.read_text(encoding="utf-8"))
lock = json.loads(LOCK.read_text(encoding="utf-8"))
if package.get("version") != "12.4.8" or lock.get("version") != "12.4.8":
    raise SystemExit("PC_DB1_DIRECT_UNEXPECTED_PACKAGE_BASELINE")
if package.get("build", {}).get("appId") != "com.anigames.billing.v12test":
    raise SystemExit("PC_DB1_DIRECT_APP_ID_CHANGED_ABORT")
if package.get("build", {}).get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("PC_DB1_DIRECT_PRODUCT_NAME_CHANGED_ABORT")
package["version"] = "12.4.9"
package["description"] = "AniGames Billing V12.4.9: DB1 direct transport; DB2 router polling removed; V12.4.8 timer and fullscreen safeguards retained. Preserve legacy Electron productName/userData path."
# Keep productName unchanged: Electron derives the default userData folder from app name.
lock["version"] = "12.4.9"
if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
    lock["packages"][""]["version"] = "12.4.9"

for path in (INDEX, RENDERER):
    data = path.read_text(encoding="utf-8")
    data, n = re.subn(r"const APP_VERSION = 'V12\.4\.8-TIMER-SIZE-SYNC';", "const APP_VERSION = 'V12.4.9-DB1-DIRECT';", data, count=1)
    if n != 1:
        raise SystemExit(f"PC_DB1_DIRECT_VERSION_MARKER_MISSING:{path.name}")
    if path.name == "index.html":
        data, footer_n = re.subn(r'(<span id="app-version-code">)V12\.4\.8-TIMER-SIZE-SYNC(</span>)', r'\g<1>V12.4.9-DB1-DIRECT\g<2>', data, count=1)
        if footer_n != 1:
            raise SystemExit("PC_DB1_DIRECT_FOOTER_VERSION_MARKER_MISSING")
    path.write_text(data, encoding="utf-8")

PACKAGE.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
LOCK.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
VERSION.write_text("V12.4.9-DB1-DIRECT\n", encoding="utf-8")
CLOUD.write_text(cloud, encoding="utf-8")

# Static acceptance assertions: no route lookup, DB2 project, or shared gateway remains in PC transport.
for token in ("resolveDbRoute", "db-route-status", "shared-db-gateway", "DB_ENDPOINTS", "xcdbipgsvohesxhxydep", "x-db-target-key"):
    if token in cloud:
        raise SystemExit("PC_DB1_DIRECT_ROUTER_REFERENCE_REMAINS:" + token)
if cloud.count("const DB1_API_URL=") != 1 or cloud.count("const DB1_ANON_KEY=") != 1:
    raise SystemExit("PC_DB1_DIRECT_CONSTANTS_NOT_UNIQUE")
for route in (
    "/device/enroll", "/device/heartbeat", "/device/ack", "/device/sync", "/device/pull",
    "/device/test-policy", "/device/rental/lookup", "/device/session/start", "/device/session/end",
    "/device/rental/release", "/device/sync-cursor", "/device/alert"
):
    if f"request('{route}'" not in cloud:
        raise SystemExit("PC_DB1_DIRECT_CLIENT_ROUTE_MISSING:" + route)
for token in ("OUTBOX_KEY=", "SYNC_CURSOR_KEY=", "SYNC_DIRTY_KEY=", "function heartbeatOnce()", "function pullNow()", "function syncNow()"):
    if token not in cloud:
        raise SystemExit("PC_DB1_DIRECT_LEGACY_FLOW_MISSING:" + token)
main = MAIN.read_text(encoding="utf-8")
if "const DB1_API_URL = 'https://wzkjpycjizexxcxrfdvr.supabase.co/functions/v1/ani-games-api';" not in main:
    raise SystemExit("PC_DB1_DIRECT_WATCHDOG_DB1_BASELINE_MISSING")
if "v11ApplyRemoteCommand" not in (INDEX.read_text(encoding="utf-8") + RENDERER.read_text(encoding="utf-8")):
    raise SystemExit("PC_DB1_DIRECT_REMOTE_COMMAND_FLOW_MISSING")
print("PASS: PC Billing transport pinned to DB1; dual-DB route checks and gateway selection removed; local queues/timer/session flows retained; V12.4.9 metadata updated.")
