from pathlib import Path
import json
import re

root = Path(".")
cloud_path = root / "v11-cloud.js"
index_path = root / "index.html"
renderer_path = root / "renderer.js"
main_path = root / "main.js"
package_path = root / "package.json"
lock_path = root / "package-lock.json"
version_path = root / "VERSION.txt"

cloud = cloud_path.read_text(encoding="utf-8")
index = index_path.read_text(encoding="utf-8")
renderer = renderer_path.read_text(encoding="utf-8")
main = main_path.read_text(encoding="utf-8")
package = json.loads(package_path.read_text(encoding="utf-8"))

if package.get("version") != "12.3.4":
    raise SystemExit(f"Unexpected PC base package version: {package.get('version')}")
if package.get("build", {}).get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("Electron productName/userData identity changed; refusing build to protect pairing/cache/outbox.")

# All device data/business endpoints must pass through the DB1 shared gateway.
old = r"viaGateway=/^device\\/(?:alert|disconnect|enroll|heartbeat|ack|sync|pull|rentals|watchdog)$/.test(clean)"
new = r"viaGateway=/^device\\/(?:alert|disconnect|enroll|heartbeat|ack|sync|pull|rentals|watchdog|rental\\/lookup|session\\/start|session\\/end|rental\\/release|sync-cursor)$/.test(clean)"
if cloud.count(old) != 1:
    raise SystemExit(f"Shared-gateway route anchor mismatch: found {cloud.count(old)}")
cloud = cloud.replace(old, new, 1)
for path in (
    "/device/rental/lookup",
    "/device/session/start",
    "/device/session/end",
    "/device/rental/release",
    "/device/sync-cursor",
):
    if path not in cloud:
        raise SystemExit("Missing global rental API call: " + path)
if not all(x in cloud for x in ("device/rental/lookup", "device/session/start", "device/session/end", "device/rental/release", "device/sync-cursor")):
    raise SystemExit("Global rental API routes incomplete")

# App/runtime version changes only. Keep Electron userData identity fixed at V12.3.3.
old_app = "V12.3.4-GLOBAL-RENTAL-DB-FIRST"
new_app = "V12.3.5-GLOBAL-RENTAL-DB-FIRST"
if old_app not in index or old_app not in cloud:
    raise SystemExit("V12.3.4 global-rental source marker not found")
index = index.replace(old_app, new_app)
cloud = cloud.replace(old_app, new_app)
renderer, count = re.subn(
    r"const APP_VERSION = '[^']+';",
    "const APP_VERSION = 'V12.3.5-GLOBAL-RENTAL-DB-FIRST';",
    renderer,
    count=1,
)
if count != 1:
    raise SystemExit("renderer.js APP_VERSION anchor mismatch")
main, count = re.subn(
    r"appVersion: 'V12\\.3\\.4-watchdog'",
    "appVersion: 'V12.3.5-watchdog'",
    main,
    count=1,
)
if count != 1:
    raise SystemExit("main.js watchdog appVersion anchor mismatch")

package["version"] = "12.3.5"
package["description"] = (
    "AniGames Billing V12.3.5: shared gateway routing for global rental lookup, "
    "exclusive sessions, offline leases and conflict-safe incremental sync"
)
package["build"]["productName"] = "AniGames Billing V12.3.3"
if lock_path.exists():
    lock = json.loads(lock_path.read_text(encoding="utf-8"))
    lock["version"] = "12.3.5"
    if isinstance(lock.get("packages"), dict) and isinstance(lock["packages"].get(""), dict):
        lock["packages"][""]["version"] = "12.3.5"
    lock_path.write_text(json.dumps(lock, indent=2, ensure_ascii=False) + "\\n", encoding="utf-8")

cloud_path.write_text(cloud, encoding="utf-8")
index_path.write_text(index, encoding="utf-8")
renderer_path.write_text(renderer, encoding="utf-8")
main_path.write_text(main, encoding="utf-8")
package_path.write_text(json.dumps(package, indent=2, ensure_ascii=False) + "\\n", encoding="utf-8")
version_path.write_text(
    "AniGames Billing PC V12.3.5 — DB-first global rental routing through shared DB gateway; stable local identity.\\n",
    encoding="utf-8",
)

# Regression guards: preserve normal/legacy flows and local state.
if "TEST_SESSION_CODE" not in index or "startTenMinuteTest" not in index:
    raise SystemExit("Free Test branch missing from login; refusing build")
if "billing_v11_client_id" not in cloud or "billing_v11_cloud_config" not in cloud:
    raise SystemExit("Pairing storage keys missing; refusing build")
if "localStorage.removeItem(CLOUD_KEY)" in cloud and "v11DisconnectDevice" not in cloud:
    raise SystemExit("Unexpected broad pairing-state cleanup")
if "fullRentalSnapshot" not in cloud or "device/rentals" in cloud[cloud.find("async function fullRentalSnapshot"):cloud.find("window.v11FullRentalSnapshot")]:
    raise SystemExit("Full rental table download path reintroduced")
if package["build"].get("productName") != "AniGames Billing V12.3.3":
    raise SystemExit("Stable Electron userData identity was not preserved")
if package["build"].get("appId") != "com.anigames.billing.v12test":
    raise SystemExit("PC test appId changed unexpectedly")

print("PASS: V12.3.5 routes lookup/start/end/release/cursor through shared gateway.")
print("PASS: one central DB rental lookup; no full table snapshot; Free Test and pairing/cache/outbox flows retained.")
print("PASS: Electron productName/appId unchanged to preserve previous local pairing and data.")
