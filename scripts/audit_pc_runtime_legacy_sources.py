#!/usr/bin/env python3
"""Read-only inventory of the exact extracted PC runtime and retired edge-function routes."""
from pathlib import Path
import re

root = Path(".")
names = [
    "main.js", "preload.js", "renderer.js", "index.html", "v11-cloud.js",
    "supabase/functions/ani-games-api/index.ts",
]
terms = {
    "SUPABASE_HOST": re.compile(r"supabase\\.co|supabase\\.in", re.I),
    "SUPABASE_FUNCTION_OR_REST": re.compile(r"/functions/v1/|/rest/v1/|/auth/v1/|supabase-js", re.I),
    "BLYNK_SECRET_OR_HOST": re.compile(r"BLYNK_AUTH_TOKEN|BLYNK_POWER_PIN|blynk\\.cloud", re.I),
    "BLYNK_IOT_ROUTE": re.compile(r"iot/status|iot/power|/iot/", re.I),
    "WOL_RELAY_ROUTE": re.compile(r"/wol/|wake_on_lan_relay|targetMac|wolLanMac", re.I),
    "REMOTE_HTTP": re.compile(r"https?://[^\\s\"'<>]+", re.I),
}
for name in names:
    path = root / name
    if not path.is_file():
        print(f"MISSING {name}")
        continue
    lines = path.read_text(encoding="utf-8-sig", errors="replace").splitlines()
    print(f"FILE {name} lines={len(lines)}")
    count = 0
    for i, line in enumerate(lines, 1):
        matched = [tag for tag, rx in terms.items() if rx.search(line)]
        if matched:
            count += 1
            # Avoid writing any embedded key/token to public GitHub Actions logs.
            safe = re.sub(r"eyJ[A-Za-z0-9_=-]{32,}", "[REDACTED_JWT]", line)
            safe = re.sub(r"(?i)(token|apikey|api_key|secret)(\\s*[:=]\\s*['\"])[^'\"]+", r"\\1\\2[REDACTED]", safe)
            safe = safe[:260]
            print(f"  {i}: {','.join(matched)}: {safe}")
    print(f"  MATCHED_LINES={count}")
