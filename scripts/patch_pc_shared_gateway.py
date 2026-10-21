from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
clouds = list(root.rglob("v11-cloud.js"))
if len(clouds) != 1:
    raise SystemExit(f"Expected exactly one v11-cloud.js, found {len(clouds)}")
cloud_path = clouds[0]
src = cloud_path.read_text(encoding="utf-8")
lines = src.splitlines()
indices = [i for i, line in enumerate(lines) if line.lstrip().startswith("async function request(path,body,opts={}){")]
if len(indices) != 1:
    raise SystemExit(f"Expected one request() runtime, found {len(indices)}")

gateway_request = """  async function request(path,body,opts={}){const retries=Math.max(0,Number(opts.retries??0));let last;for(let attempt=0;attempt<=retries;attempt++){const ctl=new AbortController();const timer=setTimeout(()=>ctl.abort(),Number(opts.timeoutMs||8000));try{const route=await resolveDbRoute(attempt>0),cfg=DB_ENDPOINTS[route.target],clean=String(path||'').replace(/^\\/+/,''),viaGateway=/^device\\/(?:alert|disconnect|enroll|heartbeat|ack|sync|pull|rentals)$/.test(clean),targetUrl=viaGateway?'https://wzkjpycjizexxcxrfdvr.supabase.co/functions/v1/shared-db-gateway/v1/'+clean:cfg.baseUrl+'/functions/v1/ani-games-api/'+clean,headers={'content-type':'application/json','apikey':viaGateway?DB_ENDPOINTS.primary.apiKey:cfg.apiKey};if(viaGateway)headers['x-db-target-key']=cfg.apiKey;const r=await fetch(targetUrl,{method:'POST',headers,body:JSON.stringify(body),signal:ctl.signal});const d=await r.json().catch(()=>({}));if(!r.ok){const detail=d.error||d.message||('HTTP '+r.status);if(r.status===401&&/invalid api key|UNAUTHORIZED_INVALID_API_KEY/i.test(String(detail)))throw new Error('API key Supabase ditolak oleh gateway. Periksa versi key aplikasi.');throw new Error(detail)}return d}catch(e){last=e;if(attempt<retries){dbRouteCheckedAt=0;await new Promise(res=>setTimeout(res,350*(attempt+1)));}}finally{clearTimeout(timer)}}throw last||new Error('NETWORK_ERROR')}"""
lines[indices[0]] = gateway_request
src = "\n".join(lines) + "\n"
if "shared-db-gateway/v1/" not in src or "x-db-target-key" not in src:
    raise SystemExit("Shared gateway request markers missing after patch")
cloud_path.write_text(src, encoding="utf-8")

# Advance only the feature-branch build identity; do not overwrite the locked V11 release.
app_version = "V12.2.2-SHARED-DB-GATEWAY"
renderer_path = cloud_path.parent / "renderer.js"
renderer = renderer_path.read_text(encoding="utf-8")
renderer, n = re.subn(r"const APP_VERSION = '[^']+';", f"const APP_VERSION = '{app_version}';", renderer, count=1)
if n != 1:
    raise SystemExit("renderer.js APP_VERSION marker not found exactly once")
renderer_path.write_text(renderer, encoding="utf-8")

index_path = cloud_path.parent / "index.html"
index_html = index_path.read_text(encoding="utf-8")
index_html, n = re.subn(r"(const APP_VERSION = )'[^']+';", rf"\1'{app_version}';", index_html, count=1)
if n != 1:
    raise SystemExit("index.html APP_VERSION marker not found exactly once")
index_html, footer_n = re.subn(r'(<span id="app-version-code">)[^<]+(</span>)', rf"\g<1>{app_version}\g<2>", index_html, count=1)
if footer_n != 1:
    raise SystemExit("index.html footer version marker not found exactly once")
index_path.write_text(index_html, encoding="utf-8")

package_path = cloud_path.parent / "package.json"
package = json.loads(package_path.read_text(encoding="utf-8"))
if package.get("version") not in ("12.2.1", "12.2.0"):
    raise SystemExit(f"Unexpected feature branch PC package version: {package.get('version')}")
package["version"] = "12.2.2"
package["description"] = "AniGames Billing V12.2.2: shared DB route gateway for device API operations; strict global route and pairing-state preservation"
if isinstance(package.get("build"), dict):
    package["build"]["productName"] = "AniGames Billing V12.2.2"
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

lock_path = cloud_path.parent / "package-lock.json"
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = "12.2.2"
    if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
        lock["packages"][""]["version"] = "12.2.2"
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

(cloud_path.parent / "VERSION.txt").write_text("AniGames Billing PC V12.2.2 - shared DB route gateway\n", encoding="utf-8")
print("PASS: device API requests now use the shared DB gateway; non-device auth/routing calls still use the verified active DB.")
