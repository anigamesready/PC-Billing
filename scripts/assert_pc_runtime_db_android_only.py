#!/usr/bin/env python3
"""Fail the PC Billing build if any active Electron runtime still uses the retired Supabase/Blynk API."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
runtime_names = ("main.js", "preload.js", "renderer.js", "index.html", "v11-cloud.js")
forbidden = {
    "Supabase hostname": re.compile(r"https?://[^\s\"'<>]*supabase\.(?:co|in)", re.I),
    "legacy Supabase Edge Function": re.compile(r"functions/v1/ani-games-api", re.I),
    "legacy Supabase database routing": re.compile(r"DB1_API_URL|DB1_ANON_KEY|DB2_API_URL|DB2_ANON_KEY|shared-db-gateway|x-db-target-key", re.I),
    "legacy Supabase configuration": re.compile(r"SUPABASE_URL|SUPABASE_ANON_KEY|SUPABASE_API_NOT_CONFIGURED", re.I),
    "Blynk API/secret in PC runtime": re.compile(r"blynk\.cloud|BLYNK_AUTH_TOKEN|BLYNK_POWER_PIN|iot/status|iot/power", re.I),
}
for name in runtime_names:
    path = root / name
    if not path.is_file():
        raise SystemExit("FAIL: required runtime file missing: " + name)
    body = path.read_text(encoding="utf-8-sig", errors="replace")
    for label, pattern in forbidden.items():
        match = pattern.search(body)
        if match:
            line = body.count("\n", 0, match.start()) + 1
            raise SystemExit(f"FAIL: {label} remains in active {name}:{line}")
    print("PASS: no legacy Supabase/Blynk route in active " + name)

cloud = (root / "v11-cloud.js").read_text(encoding="utf-8-sig")
index = (root / "index.html").read_text(encoding="utf-8-sig")
if "https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev" not in cloud:
    raise SystemExit("FAIL: PC default API is not the pinned DB Android WSS Worker")
if '<script src="v11-cloud.js"></script>' not in index:
    raise SystemExit("FAIL: DB Android sync module is not loaded by the actual Electron page")
if "request('/device/heartbeat'" not in cloud or "request('/device/sync'" not in cloud:
    raise SystemExit("FAIL: PC heartbeat/sync routes are not connected to DB Android")
if "wake_on_lan_relay" not in index or "wolLanMac" not in cloud:
    raise SystemExit("FAIL: DB Android WOL relay identity/metadata contract is missing")

print("PASS: PC runtime is DB Android-only; heartbeat, sync and paired-PC WOL metadata are connected.")
print("NOTE: Supabase source/Edge Function files are excluded from final app.asar by the build allow-list; this test scans all files that are actually packaged.")
