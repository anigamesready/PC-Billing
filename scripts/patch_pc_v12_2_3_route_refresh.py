from pathlib import Path
import json
import re
import sys

root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(".")
clouds = list(root.rglob("v11-cloud.js"))
if len(clouds) != 1:
    raise SystemExit(f"V12.2.3 expected one v11-cloud.js, found {len(clouds)}")
cloud = clouds[0]
src = cloud.read_text(encoding="utf-8")
package_path = cloud.parent / "package.json"
package = json.loads(package_path.read_text(encoding="utf-8"))

marker = "V12.2.3-GLOBAL-ROUTE-READ-WRITE"
if package.get("version") == "12.2.3" and marker in src:
    print("PASS: V12.2.3 route-refresh patch already applied")
    raise SystemExit(0)
if package.get("version") != "12.2.2" or "shared-db-gateway/v1/" not in src:
    raise SystemExit(f"V12.2.3 requires the V12.2.2 shared-gateway baseline, got {package.get('version')}")

# Every backend request must re-read both route status endpoints before choosing a read/write target.
old_request = "const route=await resolveDbRoute(attempt>0),cfg=DB_ENDPOINTS[route.target]"
new_request = "const route=await resolveDbRoute(true),cfg=DB_ENDPOINTS[route.target]"
if src.count(old_request) != 1:
    raise SystemExit(f"V12.2.3 request route-refresh anchor mismatch: {src.count(old_request)}")
src = src.replace(old_request, new_request, 1)

# Auth parity is intentionally optional when DB1/DB2 use separate Supabase Auth projects.
old_auth_guard = "r.backup_ready===true&&r.auth_parity_ready===true&&r.data_parity_ready===true"
new_auth_guard = "r.backup_ready===true&&(r.auth_parity_ready===true||r.auth_parity_optional===true)&&r.data_parity_ready===true"
if src.count(old_auth_guard) != 1:
    raise SystemExit(f"V12.2.3 optional-Auth guard anchor mismatch: {src.count(old_auth_guard)}")
src = src.replace(old_auth_guard, new_auth_guard, 1)

# A global route is trusted only when both projects agree and the target has a finalized proof.
old_finalized = """  function dbRouteFinalizedActive(r){
    if(!r||r.active_target!=='backup'||!Number.isFinite(Number(r.epoch))||Number(r.epoch)<1||!r.switch_id)return false;
    const expected='Coordinated global route finalized: backup epoch '+Number(r.epoch)+' switch '+String(r.switch_id);
    return !!r.last_cutover_test_at&&String(r.cutover_test_note||'')===expected;
  }"""
new_finalized = """  function dbRouteFinalizedActive(r){
    if(!r||!['primary','backup'].includes(r.active_target)||!Number.isInteger(Number(r.epoch))||Number(r.epoch)<1)return false;
    const epoch=Number(r.epoch),switchId=String(r.switch_id||'');
    if(r.active_target==='primary'&&epoch===1&&!switchId)return true;
    if(epoch<2||!switchId)return false;
    const expected='Coordinated global route finalized: '+r.active_target+' epoch '+epoch+' switch '+switchId;
    return !!r.last_cutover_test_at&&String(r.cutover_test_note||'')===expected;
  }"""
if src.count(old_finalized) != 1:
    raise SystemExit(f"V12.2.3 finalized-route helper anchor mismatch: {src.count(old_finalized)}")
src = src.replace(old_finalized, new_finalized, 1)

old_compare = "if(b.active_target!==route.active_target||Number(b.epoch)!==Number(route.epoch)||String(b.switch_id||'')!==String(route.switch_id||''))throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: DB1 and DB2 target, epoch, or switch ID differ');"
new_compare = old_compare + "\n      if(!dbRouteFinalizedActive(route)||!dbRouteFinalizedActive(b))throw new Error('DB_ROUTE_CUTOVER_INCOMPLETE: active route is not finalized on both projects');"
if src.count(old_compare) != 1:
    raise SystemExit(f"V12.2.3 route finalization anchor mismatch: {src.count(old_compare)}")
src = src.replace(old_compare, new_compare, 1)

# Keep all version labels consistent with the package/build identity.
old_build = "// BUILD_ID: V12.2.2-SHARED-DB-GATEWAY"
if src.count(old_build) != 1:
    raise SystemExit("V12.2.3 BUILD_ID anchor mismatch")
src = src.replace(old_build, "// BUILD_ID: " + marker, 1)
old_app = "APP='V12.2.0-DUAL-DB-ROUTE'"
if src.count(old_app) != 1:
    raise SystemExit("V12.2.3 cloud APP label anchor mismatch")
src = src.replace(old_app, "APP='" + marker + "'", 1)

checks = [
    "resolveDbRoute(true)",
    "auth_parity_optional===true",
    "function dbRouteFinalizedActive(r)",
    "Coordinated global route finalized: '+r.active_target+' epoch '+epoch+' switch '+switchId",
    "active route is not finalized on both projects",
    "shared-db-gateway/v1/",
    "x-db-target-key"
]
for token in checks:
    if token not in src:
        raise SystemExit("V12.2.3 required route guard missing: " + token)

cloud.write_text(src, encoding="utf-8")
package["version"] = "12.2.3"
package["description"] = "AniGames Billing V12.2.3: fresh global route resolution for every API read/write, optional cross-project Auth parity, finalized route guards in both directions"
if isinstance(package.get("build"), dict):
    package["build"]["productName"] = "AniGames Billing V12.2.3"
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

lock_path = cloud.parent / "package-lock.json"
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = "12.2.3"
    if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
        lock["packages"][""]["version"] = "12.2.3"
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")

for filename in ("renderer.js", "index.html"):
    path = cloud.parent / filename
    text = path.read_text(encoding="utf-8")
    if filename == "renderer.js":
        text, n = re.subn(r"const APP_VERSION = '[^']+';", "const APP_VERSION = '" + marker + "';", text, count=1)
        if n != 1:
            raise SystemExit("V12.2.3 renderer APP_VERSION marker mismatch")
    else:
        text, n = re.subn(r"(const APP_VERSION = )'[^']+';", lambda m: m.group(1) + "'" + marker + "';", text, count=1)
        if n != 1:
            raise SystemExit("V12.2.3 live index APP_VERSION marker mismatch")
        text, n = re.subn(r'(<span id="app-version-code">)[^<]+(</span>)', lambda m: m.group(1) + marker + m.group(2), text, count=1)
        if n != 1:
            raise SystemExit("V12.2.3 index footer version marker mismatch")
    path.write_text(text, encoding="utf-8")

(cloud.parent / "VERSION.txt").write_text("AniGames Billing PC V12.2.3 - global route read/write refresh and symmetric finalized-route guard\n", encoding="utf-8")
print("PASS: PC V12.2.3 refreshes both route states before every API read/write, accepts optional separate-Auth parity, and requires finalized proof for DB1/DB2 routes.")
