#!/usr/bin/env python3
"""Apply the isolated Cloudflare edge trust/bootstrap protection to DB Android API."""
from pathlib import Path
import re
import sys

root = Path(sys.argv[1] if len(sys.argv) > 1 else ".").resolve()
server = root / "server.mjs"
if not server.is_file():
    raise SystemExit("DB_ANDROID_SERVER_NOT_FOUND")
source = server.read_text(encoding="utf-8")
marker = "ANI-DB-ANDROID-CLOUDFLARE-EDGE-TRUST-V1"

if marker in source:
    required = (
        "const EDGE_PROXY_SECRET = process.env.ANI_EDGE_PROXY_SECRET || '';",
        "function localBootstrapRequestAllowed(req)",
        "x-ani-edge-client-ip",
        "crypto.timingSafeEqual"
    )
    if not all(x in source for x in required):
        raise SystemExit("EDGE_PATCH_MARKER_BUT_INCOMPLETE")
    print("PASS: Cloudflare edge trust patch already applied")
    raise SystemExit(0)

source = source.replace(
    'import crypto from "node:crypto";',
    'import crypto from "node:crypto";\nimport net from "node:net";',
    1
)
if 'import net from "node:net";' not in source:
    raise SystemExit("NODE_NET_IMPORT_FAILED")

anchor = 'const BOOTSTRAP_TOKEN = process.env.ANI_ADMIN_BOOTSTRAP_TOKEN || "";'
if source.count(anchor) != 1:
    raise SystemExit("BOOTSTRAP_CONFIG_ANCHOR_MISMATCH")
source = source.replace(
    anchor,
    anchor + "\nconst EDGE_PROXY_SECRET = process.env.ANI_EDGE_PROXY_SECRET || '';",
    1
)

if "function clientIp(req)" not in source:
    raise SystemExit("CLIENT_IP_FUNCTION_NOT_FOUND")
new_ip = r"""// ANI-DB-ANDROID-CLOUDFLARE-EDGE-TRUST-V1
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
}
function localBootstrapRequestAllowed(req) {
  const remote = String(req.socket.remoteAddress || "").replace(/^::ffff:/, "");
  const fromLoopback = isLoopback && ["127.0.0.1", "::1", "localhost"].includes(remote);
  const hasEdgeIdentity = Boolean(
    req.headers["x-ani-edge-client-ip"] ||
    req.headers["x-ani-edge-secret"] ||
    req.headers["cf-connecting-ip"]
  );
  return fromLoopback && !hasEdgeIdentity;
}"""
source, count = re.subn(
    r'function clientIp\(req\) \{.*?\n\}',
    new_ip,
    source,
    count=1,
    flags=re.S
)
if count != 1:
    raise SystemExit("CLIENT_IP_FUNCTION_PATCH_FAILED")

old_setup = 'if (!BOOTSTRAP_TOKEN || !isLoopback || !["127.0.0.1","::1","::ffff:127.0.0.1"].includes(req.socket.remoteAddress))'
if source.count(old_setup) != 2:
    raise SystemExit("EXPECTED_TWO_LOCAL_BOOTSTRAP_GUARDS")
source = source.replace(old_setup, 'if (!BOOTSTRAP_TOKEN || !localBootstrapRequestAllowed(req))')

if source.count("function clientIp(req)") != 1 or source.count("function localBootstrapRequestAllowed(req)") != 1:
    raise SystemExit("EDGE_HELPERS_NOT_UNIQUE")
if source.count("localBootstrapRequestAllowed(req)") != 2:
    raise SystemExit("LOCAL_BOOTSTRAP_GUARD_NOT_APPLIED_TWICE")
if "0.0.0.0" in source:
    raise SystemExit("UNEXPECTED_PUBLIC_BIND_CHANGE")

server.write_text(source, encoding="utf-8")
print("PASS: trusted edge IP is accepted only with a loopback socket and shared secret.")
print("PASS: X-Forwarded-For is ignored.")
print("PASS: /setup and /api/admin/bootstrap reject public/tunnel requests.")
print("PASS: API bind configuration remains unchanged.")
