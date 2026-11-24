#!/usr/bin/env python3
"""Verify PC Billing route/API/SQL/WSS compatibility for DB Android."""
from pathlib import Path
import re
import sys

if len(sys.argv) != 5:
    raise SystemExit("usage: checker PROJECT SERVER_MJS SCHEMA_DIR WORKER_MJS")
project, server_path, schema_dir, worker_path = map(Path, sys.argv[1:])
main = (project / "main.js").read_text(encoding="utf-8-sig")
cloud = (project / "v11-cloud.js").read_text(encoding="utf-8-sig")
index = (project / "index.html").read_text(encoding="utf-8-sig")
server = server_path.read_text(encoding="utf-8-sig")
worker = worker_path.read_text(encoding="utf-8-sig")
schema = "\n".join(p.read_text(encoding="utf-8-sig") for p in sorted(schema_dir.glob("*.sql")))

client = set(re.findall(r"request\(['\"](/device/[a-z0-9/_-]+)['\"]", cloud, re.I))
watchdog = {"/" + x for x in re.findall(r"watchdogRequest\(['\"](device/[a-z0-9/_-]+)['\"]", main, re.I)}
routes = client | watchdog
implemented = set(re.findall(r'path\s*===\s*["\'](/device/[a-z0-9/_-]+)["\']', server, re.I))
missing = sorted(routes - implemented)
if missing:
    raise SystemExit("PC_ROUTE_NOT_IMPLEMENTED_BY_REDMi_API:" + ",".join(missing))

routines = {
 "/device/enroll": ("api.redeem_device", "api.device_pairing_rate_limit_consume", "api.device_pairing_rate_limit_clear"),
 "/device/disconnect": ("api.device_disconnect",),
 "/device/alert": ("api.device_emit_admin_alert",),
 "/device/test-policy": ("api.device_free_test_policy",),
 "/device/session-control-policy": ("api.device_session_control_policy",),
 "/device/rental/lookup": ("api.device_rental_lookup",),
 "/device/session/start": ("api.device_start_rental_session",),
 "/device/session/end": ("api.device_end_rental_session",),
 "/device/rental/release": ("api.device_release_rental_lease",),
 "/device/sync-cursor": ("api.device_sync_cursor",),
 "/device/heartbeat": ("api.device_heartbeat",),
 "/device/watchdog": ("api.device_watchdog_poll",),
 "/device/ack": ("api.device_ack", "api.device_finalize_trial"),
 "/device/sync": ("api.device_sync",),
 "/device/pull": ("api.device_pull_sync",),
 "/device/rentals": ("api.device_rentals_snapshot",),
}
for route in routes:
    for routine in routines.get(route, ()):
        if not re.search(re.escape(routine) + r"\s*\(", server, re.I):
            raise SystemExit(f"SERVER_SQL_CALL_MISSING:{route}:{routine}")
        if not re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+" + re.escape(routine) + r"\s*\(", schema, re.I):
            raise SystemExit(f"SQL_ROUTINE_MISSING:{route}:{routine}")

if not re.search(r"device.*\[a-z0-9/_-\]", worker) or "ALLOWED_EXACT_PATHS" not in worker:
    raise SystemExit("WORKER_DEVICE_ALLOWLIST_MISSING")
if "RELAY_SHARED_SECRET" not in worker or "AGENT_UNAUTHORIZED" not in worker:
    raise SystemExit("WORKER_RELAY_AUTH_GATE_MISSING")
if "headers.authorization='Bearer '+token" not in cloud:
    raise SystemExit("DEVICE_BEARER_HEADER_MISSING")
url = "https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev"
if f"DEFAULT_API_BASE_URL='{url}'" not in cloud:
    raise SystemExit("DEFAULT_REDMi_WORKER_URL_MISSING")
if "request('/device/disconnect'" not in cloud:
    raise SystemExit("PC_SERVER_DISCONNECT_MISSING")
if "admin_get_billing_stop_pause_policy:" not in server or "admin_set_billing_stop_pause_policy:" not in server:
    raise SystemExit("ADMIN_STOP_PAUSE_RPC_NOT_ALLOWED_BY_REDMi_API")
for routine in ("api.admin_get_billing_stop_pause_policy", "api.admin_set_billing_stop_pause_policy"):
    if not re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+" + re.escape(routine) + r"\s*\(", schema, re.I):
        raise SystemExit("ADMIN_STOP_PAUSE_SQL_ROUTINE_MISSING:" + routine)
if "billing_stop_pause_enabled" not in schema:
    raise SystemExit("ADMIN_STOP_PAUSE_SETTING_MISSING")
if not re.search(r"CREATE\s+OR\s+REPLACE\s+FUNCTION\s+private\.is_billing_stop_pause_enabled\s*\(", schema, re.I):
    raise SystemExit("ADMIN_STOP_PAUSE_POLICY_HELPER_MISSING")
if not re.search(r"device_session_control_policy\s*\([^)]*\).*?private\.is_billing_stop_pause_enabled\s*\(", schema, re.I | re.S):
    raise SystemExit("DEVICE_STOP_PAUSE_POLICY_SQL_LINK_MISSING")
if '<script src="v11-cloud.js"></script>' not in index or 'v11-Server DB Android.js' in index:
    raise SystemExit("PC_BILLING_SYNC_SCRIPT_NOT_LOADED")
for key in ("billing_v11_cloud_config", "billing_v11_outbox", "billing_v11_session_outbox"):
    if key not in cloud:
        raise SystemExit("LOCAL_COMPATIBILITY_KEY_MISSING:" + key)

for name, value in (("main.js", main), ("v11-cloud.js", cloud), ("index.html", index)):
    for forbidden in ("supabase.co/functions", "DB1_API_URL", "DB2_API_URL", "DB1_ANON_KEY", "DB_ENDPOINTS", "resolveDbRoute", "shared-db-gateway", "x-db-target-key"):
        if forbidden.lower() in value.lower():
            raise SystemExit(f"LEGACY_DATABASE_ROUTE_REMAINS:{name}:{forbidden}")
for required in ("main.js", "preload.js", "renderer.js", "index.html", "v11-cloud.js"):
    if not (project / required).is_file():
        raise SystemExit("RUNTIME_ENTRY_MISSING:" + required)
print("PASS: PC routes, Redmi API handlers, SQL routines and WSS Worker contract match.")
print("PASS: PC Stop/Pause device gate and Admin Owner-only policy RPCs are present in server + SQL.")
print("PASS: single Redmi DB Android target; no active DB1/DB2 router; local state/outbox keys preserved.")
