#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PROJECT_DIR="${1:-$HOME/ani-games-db-android-stage}"
BASE_URL="${ANI_STAGE_BASE_URL:-http://127.0.0.1:8788}"
TARGET_FILE="$PROJECT_DIR/server/server.mjs"

[ -f "$TARGET_FILE" ] || { echo "[ANI CHECK] server.mjs tidak ditemukan: $TARGET_FILE" >&2; exit 1; }
command -v node >/dev/null 2>&1 || { echo "[ANI CHECK] Node.js tidak ditemukan." >&2; exit 1; }
command -v curl >/dev/null 2>&1 || { echo "[ANI CHECK] curl tidak ditemukan." >&2; exit 1; }

node --check "$TARGET_FILE"
node --input-type=module - "$TARGET_FILE" <<'NODE'
import assert from "node:assert/strict";
import fs from "node:fs";
const code = fs.readFileSync(process.argv[2], "utf8");
assert.ok(code.includes("async function authRequest(req, res, url, path) {"));
assert.ok(code.includes('if (path === prefix || path.startsWith(prefix + "/"))'));
assert.ok(code.includes("authRequest(req,res,url,path)"));
assert.ok(code.includes("api.dashboard_billing_user($1::text,$2::text,$3::text,$4::text,$5::text,$6::text,$7::uuid,$8::text,$9::uuid) AS result"));
console.log("[ANI CHECK] Source patch assertions: PASS");
NODE

TMP="$(mktemp)"
trap 'rm -f "$TMP"' EXIT

STATUS="$(curl -sS -o "$TMP" -w '%{http_code}' "$BASE_URL/health")"
[ "$STATUS" = "200" ] || { echo "[ANI CHECK] Health returned HTTP $STATUS"; cat "$TMP"; exit 1; }
grep -q '"api":"online"' "$TMP"
grep -q '"database":"online"' "$TMP"
echo "[ANI CHECK] API + database health: PASS"

for ROUTE in "/auth/v1/user" "/functions/v1/ani-games-api/auth/v1/user"; do
  STATUS="$(curl -sS -o "$TMP" -w '%{http_code}' "$BASE_URL$ROUTE")"
  [ "$STATUS" = "401" ] || { echo "[ANI CHECK] $ROUTE returned HTTP $STATUS (expected 401)"; cat "$TMP"; exit 1; }
  grep -q '"message":"AUTH_REQUIRED"' "$TMP" || { echo "[ANI CHECK] Auth response mismatch: $ROUTE"; cat "$TMP"; exit 1; }
  echo "[ANI CHECK] $ROUTE: PASS"
done

echo "[ANI CHECK] Read-only verification selesai; tidak membuat login, sesi, atau rental."
