#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
[ -f "$HERE/.env" ] || { echo "[ANI API] .env belum dibuat. Jalankan provision-runtime-role.sh."; exit 1; }
set -a
. "$HERE/.env"
set +a
cd "$HERE"
exec node server.mjs
