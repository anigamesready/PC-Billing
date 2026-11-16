#!/usr/bin/env python3
"""Apply Cloudflare edge security and PostgreSQL pool resilience to the isolated DB Android API."""
from datetime import datetime, timezone
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
server = root / "server.mjs"
if not server.is_file():
    raise SystemExit("DB_ANDROID_SERVER_NOT_FOUND")

source = server.read_text(encoding="utf-8")
original = source
edge_marker = "ANI-DB-ANDROID-CLOUDFLARE-EDGE-TRUST-V1"
pool_marker = "ANI-DB-ANDROID-PG-POOL-ERROR-HANDLER-V1"

if edge_marker not in source:
    # A previous local patch may already have added these declarations without
    # installing the full edge-trust marker. Reuse them instead of duplicating
    # Python-injected JavaScript imports/constants.
    net_import = 'import net from "node:net";'
    net_count = source.count(net_import)
    if net_count > 1:
        raise SystemExit("DUPLICATE_NODE_NET_IMPORT")
    if net_count == 0:
        crypto_import = 'import crypto from "node:crypto";'
        if source.count(crypto_import) != 1:
            raise SystemExit("NODE_CRYPTO_IMPORT_ANCHOR_MISMATCH")
        source = source.replace(crypto_import, crypto_import + "\\n" + net_import, 1)

    secret_decl = "const EDGE_PROXY_SECRET = process.env.ANI_EDGE_PROXY_SECRET || '';"
    existing_secret_decls = re.findall(r"(?m)^const\\s+EDGE_PROXY_SECRET\\s*=.*?;\\s*$", source)
    if len(existing_secret_decls) > 1:
        raise SystemExit("DUPLICATE_EDGE_PROXY_SECRET_DECLARATION")
    if len(existing_secret_decls) == 0:
        anchor = 'const BOOTSTRAP_TOKEN = process.env.ANI_ADMIN_BOOTSTRAP_TOKEN || "";'
        if source.count(anchor) != 1:
            raise SystemExit("BOOTSTRAP_CONFIG_ANCHOR_MISMATCH")
        source = source.replace(anchor, anchor + "\\n" + secret_decl, 1)
    elif "process.env.ANI_EDGE_PROXY_SECRET" not in existing_secret_decls[0]:
        raise SystemExit("EXISTING_EDGE_PROXY_SECRET_SOURCE_MISMATCH")

    new_ip = r\"\"\"// ANI-DB-ANDROID-CLOUDFLARE-EDGE-TRUST-V1
function clientIp(req) {
  const remote = String(req.socket.remoteAddress || "unknown").replace(/^::ffff:/, "").slice(0, 128);
  const remoteIsLoopback = ["127.0.0.1", "::1", "localhost"].includes(remote);
  const forwardedIp = String(req.headers["x-ani-edge-client-ip"] || "").trim();
  const suppliedSecret = String(req.headers["x-ani-edge-secret"] || "");
  if (remoteIsLoopback && EDGE_PROXY_SECRET.length >= 32 &&
      suppliedSecret.length === EDGE_PROXY_SECRET.length &&
      crypto.timingSafeEqual(Buffer.from(suppliedSecret), Buffer.from(EDGE_PROXY_SECRET)) &&
      net.isIP(forwardedIp)) {
    return forwardedIp;
  }
  // Ignore X-Forwarded-For and all unverified forwarding headers.
  return remote;
}\"\"\"
    source, count = re.subn(
        r'function clientIp\\(req\\) \\{.*?\\n\\}',
        new_ip,
        source,
        count=1,
        flags=re.S
    )
    if count != 1:
        raise SystemExit("CLIENT_IP_FUNCTION_PATCH_FAILED")

    bootstrap_fn = r\"\"\"function localBootstrapRequestAllowed(req) {
  const remote = String(req.socket.remoteAddress || "").replace(/^::ffff:/, "");
  const fromLoopback = isLoopback && ["127.0.0.1", "::1", "localhost"].includes(remote);
  const hasEdgeIdentity = Boolean(
    req.headers["x-ani-edge-client-ip"] ||
    req.headers["x-ani-edge-secret"] ||
    req.headers["cf-connecting-ip"]
  );
  return fromLoopback && !hasEdgeIdentity;
}\"\"\"
    existing_bootstrap = re.findall(
        r"(?ms)^function localBootstrapRequestAllowed\\(req\\) \\{.*?^\\}",
        source
    )
    if len(existing_bootstrap) == 0:
        if source.count(new_ip) != 1:
            raise SystemExit("EDGE_CLIENT_IP_PATCH_RESULT_NOT_UNIQUE")
        source = source.replace(new_ip, new_ip + "\\n" + bootstrap_fn, 1)
    elif len(existing_bootstrap) == 1:
        existing = existing_bootstrap[0]
        if not all(x in existing for x in (
            'req.headers["x-ani-edge-client-ip"]',
            'req.headers["x-ani-edge-secret"]',
            'req.headers["cf-connecting-ip"]',
            "return fromLoopback && !hasEdgeIdentity;"
        )):
            raise SystemExit("EXISTING_LOCAL_BOOTSTRAP_GUARD_NOT_EDGE_SAFE")
    else:
        raise SystemExit("DUPLICATE_LOCAL_BOOTSTRAP_GUARD")

    old_setup = 'if (!BOOTSTRAP_TOKEN || !isLoopback || !["127.0.0.1","::1","::ffff:127.0.0.1"].includes(req.socket.remoteAddress))'
    if source.count(old_setup) != 2:
        raise SystemExit("EXPECTED_TWO_LOCAL_BOOTSTRAP_GUARDS")
    source = source.replace(old_setup, 'if (!BOOTSTRAP_TOKEN || !localBootstrapRequestAllowed(req))')
else:
    required = (
        'const EDGE_PROXY_SECRET = process.env.ANI_EDGE_PROXY_SECRET || \'\';',
        "function localBootstrapRequestAllowed(req)",
        "x-ani-edge-client-ip",
        "crypto.timingSafeEqual",
        'import net from "node:net";'
    )
    if not all(item in source for item in required):
        raise SystemExit("EDGE_PATCH_MARKER_BUT_INCOMPLETE")
    if source.count("function localBootstrapRequestAllowed(req)") != 1 or source.count("localBootstrapRequestAllowed(req)") != 3:
        raise SystemExit("EDGE_BOOTSTRAP_GUARDS_INCOMPLETE")

# Preserve PostgreSQL SQLSTATE on a failed API boot without exposing connection details.
startup_marker = "ANI-DB-ANDROID-STARTUP-ERROR-DIAGNOSTIC-V1"
if startup_marker not in source:
    old_fatal = '  process.stderr.write(JSON.stringify({level:"fatal",error:publicError(error)})+"\\n");'
    current_fatal = '  process.stderr.write(JSON.stringify({level:"fatal",error:String(error?.code || publicError(error)).slice(0,32)})+"\\n");'
    if source.count(old_fatal) == 1:
        new_fatal = chr(10).join((
            '  // ANI-DB-ANDROID-STARTUP-ERROR-DIAGNOSTIC-V1',
            '  const diagnosticCode = String(error?.code || publicError(error)).slice(0, 32);',
            '  process.stderr.write(JSON.stringify({level:"fatal",error:diagnosticCode})+"\\n");'
        ))
        source = source.replace(old_fatal, new_fatal, 1)
    elif source.count(current_fatal) == 1:
        source = source.replace(current_fatal, '  // ANI-DB-ANDROID-STARTUP-ERROR-DIAGNOSTIC-V1' + chr(10) + current_fatal, 1)
    else:
        raise SystemExit("STARTUP_FATAL_LOG_ANCHOR_MISMATCH")
elif "diagnosticCode" not in source and "error:String(error?.code || publicError(error))" not in source:
    raise SystemExit("STARTUP_DIAGNOSTIC_MARKER_BUT_INCOMPLETE")

# node-postgres emits Pool-level "error" events when an idle client disconnects.
# If unhandled, Node treats the EventEmitter error as fatal and exits the API.
if pool_marker not in source:
    pool_anchor = '  application_name: "ani-games-ready-local-api"\n});'
    if source.count(pool_anchor) != 1:
        raise SystemExit("PG_POOL_CONFIG_ANCHOR_MISMATCH")
    pool_handler = pool_anchor + """

// ANI-DB-ANDROID-PG-POOL-ERROR-HANDLER-V1
pool.on("error", error => {
  // SQLSTATE only; never log connection strings or credentials.
  const code = String(error?.code || "POOL_CLIENT_ERROR").slice(0, 32);
  process.stderr.write(JSON.stringify({
    level: "error",
    component: "postgres_pool",
    code
  }) + "\\n");
});"""
    source = source.replace(pool_anchor, pool_handler, 1)
else:
    required_pool = (
        'pool.on("error", error => {',
        'component: "postgres_pool"',
        'POOL_CLIENT_ERROR',
        "ANI-DB-ANDROID-PG-POOL-ERROR-HANDLER-V1"
    )
    if not all(item in source for item in required_pool):
        raise SystemExit("PG_POOL_ERROR_HANDLER_MARKER_BUT_INCOMPLETE")

# Keep the API bound to loopback; this patch must not broaden network exposure.
if 'const HOST = process.env.ANI_BIND || "127.0.0.1";' not in source:
    raise SystemExit("API_BIND_CONFIG_CHANGED")
if "0.0.0.0" in source:
    raise SystemExit("UNEXPECTED_PUBLIC_BIND_CHANGE")

# Preserve a one-time local source backup before writing a modified server.
if source != original:
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    backup = server.with_name(f"server.mjs.pre-cloudflare-stage-{stamp}")
    if not backup.exists():
        backup.write_text(original, encoding="utf-8")
    server.write_text(source, encoding="utf-8")
    print(f"PASS: API_SOURCE_PATCH_APPLIED backup={backup.name}")
else:
    print("PASS: API source patches already present")

if edge_marker in source and pool_marker in source:
    print("PASS: Cloudflare edge trust and PostgreSQL pool resilience are installed.")
