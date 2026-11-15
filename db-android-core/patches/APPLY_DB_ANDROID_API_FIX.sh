#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

PROJECT_DIR="${1:-$HOME/ani-games-db-android-stage}"
TARGET_FILE="$PROJECT_DIR/server/server.mjs"

if [ ! -f "$TARGET_FILE" ]; then
  echo "[ANI PATCH] File tidak ditemukan: $TARGET_FILE" >&2
  echo "[ANI PATCH] Gunakan: bash APPLY_DB_ANDROID_API_FIX.sh ~/ani-games-db-android-stage" >&2
  exit 1
fi
command -v node >/dev/null 2>&1 || { echo "[ANI PATCH] Node.js tidak ditemukan." >&2; exit 1; }

TMP_FILE="$PROJECT_DIR/server/.server.mjs.api-fix-$$.mjs"
trap 'rm -f "$TMP_FILE"' EXIT

node --input-type=module - "$TARGET_FILE" "$TMP_FILE" <<'NODE'
import fs from "node:fs";

const [sourcePath, targetPath] = process.argv.slice(2);
let code = fs.readFileSync(sourcePath, "utf8");

function swap(oldPattern, replacement, label, alreadyPattern) {
  const matches = code.match(oldPattern);
  const count = matches ? matches.length : 0;
  if (count === 1) {
    code = code.replace(oldPattern, replacement);
    console.log("[ANI PATCH] " + label + ": dipatch");
    return;
  }
  if (count === 0 && alreadyPattern.test(code)) {
    console.log("[ANI PATCH] " + label + ": sudah benar");
    return;
  }
  throw new Error(label + ": pola tidak cocok atau tidak unik; file tidak diubah");
}

swap(
  /async function authRequest\(\s*req\s*,\s*res\s*,\s*url\s*\)\s*\{\s*const path\s*=\s*url\.pathname\s*;/,
  "async function authRequest(req, res, url, path) {",
  "Auth normalized path",
  /async function authRequest\(\s*req\s*,\s*res\s*,\s*url\s*,\s*path\s*\)\s*\{/
);

swap(
  /if\s*\(\s*path\.startsWith\(prefix\)\s*\)\s*path\s*=\s*path\.slice\(prefix\.length\)\s*\|\|\s*["']\/["']\s*;/,
  'if (path === prefix || path.startsWith(prefix + "/")) path = path.slice(prefix.length) || "/";',
  "Compatibility prefix boundary",
  /if\s*\(\s*path\s*===\s*prefix\s*\|\|\s*path\.startsWith\(prefix\s*\+\s*["']\/["']\)\s*\)/
);

swap(
  /if\s*\(\s*path\.startsWith\(\s*["']\/auth\/v1\/["']\s*\)\s*\)\s*return\s+await\s+authRequest\(\s*req\s*,\s*res\s*,\s*url\s*\)\s*;/,
  'if (path.startsWith("/auth/v1/")) return await authRequest(req,res,url,path);',
  "Pass normalized Auth path",
  /authRequest\(\s*req\s*,\s*res\s*,\s*url\s*,\s*path\s*\)/
);

swap(
  /api\.dashboard_billing_user\(\$1::text,\$2::text,\$3::text,\$4::text,\$5::text,\$6::uuid,\$7::text,\$8::uuid\)/,
  "api.dashboard_billing_user($1::text,$2::text,$3::text,$4::text,$5::text,$6::text,$7::uuid,$8::text,$9::uuid)",
  "Admin Billing User 9-parameter bind and type order",
  /api\.dashboard_billing_user\(\$1::text,\$2::text,\$3::text,\$4::text,\$5::text,\$6::text,\$7::uuid,\$8::text,\$9::uuid\)/
);

if (!code.includes("async function authRequest(req, res, url, path) {")
    || !code.includes('if (path === prefix || path.startsWith(prefix + "/"))')
    || !code.includes("authRequest(req,res,url,path)")
    || !code.includes("api.dashboard_billing_user($1::text,$2::text,$3::text,$4::text,$5::text,$6::text,$7::uuid,$8::text,$9::uuid) AS result")) {
  throw new Error("Post-patch assertions failed; original file remains untouched");
}

const originalMode = fs.statSync(sourcePath).mode & 0o777;
fs.writeFileSync(targetPath, code, { mode: originalMode });
NODE

node --check "$TMP_FILE"

STAMP="$(date +%Y%m%d-%H%M%S)"
BACKUP="$TARGET_FILE.backup-api-fix-$STAMP"
if [ -e "$BACKUP" ]; then
  echo "[ANI PATCH] Backup target sudah ada; berhenti aman." >&2
  exit 1
fi

cp -p "$TARGET_FILE" "$BACKUP"
mv "$TMP_FILE" "$TARGET_FILE"
trap - EXIT

echo "[ANI PATCH] Server source berhasil diperbaiki."
echo "[ANI PATCH] Backup tersimpan: $BACKUP"
if command -v sha256sum >/dev/null 2>&1; then
  sha256sum "$TARGET_FILE" "$BACKUP"
fi
echo "[ANI PATCH] Database, .env, PostgreSQL, port 8787, dan relay WoL tidak disentuh."
