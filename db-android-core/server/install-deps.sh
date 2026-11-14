#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
command -v node >/dev/null 2>&1 || { echo "[ANI API] Node.js belum terpasang"; exit 1; }
command -v npm >/dev/null 2>&1 || { echo "[ANI API] npm belum terpasang"; exit 1; }
cd "$HERE"
npm install --no-audit --no-fund
npm run check
echo "[ANI API] Dependensi terpasang dan syntax check lulus."
