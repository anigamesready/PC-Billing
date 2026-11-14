#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/server"
PID_FILE="$HERE/stage-api.pid"
[ -f "$PID_FILE" ] || { echo "[ANI STAGE] PID stage tidak ditemukan."; exit 0; }
PID="$(cat "$PID_FILE" 2>/dev/null || true)"
if [ -z "$PID" ] || ! kill -0 "$PID" 2>/dev/null; then
  rm -f "$PID_FILE"
  echo "[ANI STAGE] API staging sudah berhenti."
  exit 0
fi
CWD="$(readlink "/proc/$PID/cwd" 2>/dev/null || true)"
CMD="$(tr '\0' ' ' <"/proc/$PID/cmdline" 2>/dev/null || true)"
if [ "$CWD" != "$SERVER" ] || ! printf '%s' "$CMD" | grep -q 'server.mjs'; then
  echo "[ANI STAGE] STOP: PID tidak cocok dengan server staging. Tidak dihentikan."
  exit 2
fi
kill "$PID"
for _ in $(seq 1 10); do
  kill -0 "$PID" 2>/dev/null || break
  sleep 1
done
if kill -0 "$PID" 2>/dev/null; then
  echo "[ANI STAGE] Server staging belum berhenti. Tidak memaksa proses lain."
  exit 1
fi
rm -f "$PID_FILE"
echo "[ANI STAGE] API staging berhenti. PostgreSQL dan layanan port 8787 tetap hidup."
