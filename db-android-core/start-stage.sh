#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SERVER="$HERE/server"
ENV_FILE="$SERVER/.env"
PID_FILE="$HERE/stage-api.pid"
LOG_FILE="$HERE/logs/stage-api.log"
[ -f "$ENV_FILE" ] || { echo "[ANI STAGE] .env tidak ada. Jalankan setup-stage.sh terlebih dahulu."; exit 1; }
mkdir -p "$HERE/logs"
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    CWD="$(readlink "/proc/$PID/cwd" 2>/dev/null || true)"
    CMD="$(tr '\0' ' ' <"/proc/$PID/cmdline" 2>/dev/null || true)"
    if [ "$CWD" = "$SERVER" ] && printf '%s' "$CMD" | grep -q 'server.mjs'; then
      curl -fsS http://127.0.0.1:8788/health
      echo "[ANI STAGE] API staging sudah berjalan."
      exit 0
    fi
    echo "[ANI STAGE] STOP: PID staging tersimpan tetapi proses bukan server staging yang dikenal."
    exit 2
  fi
  rm -f "$PID_FILE"
fi
if curl -fsS http://127.0.0.1:8788/health >/dev/null 2>&1; then
  echo "[ANI STAGE] STOP: port 8788 dipakai proses lain; tidak akan dihentikan."
  exit 2
fi
nohup bash -c '
  cd "$1"
  set -a
  . "$2"
  set +a
  exec node server.mjs
' _ "$SERVER" "$ENV_FILE" >>"$LOG_FILE" 2>&1 </dev/null &
PID=$!
echo "$PID" > "$PID_FILE"
sleep 2
if ! kill -0 "$PID" 2>/dev/null || ! curl -fsS http://127.0.0.1:8788/health; then
  echo "[ANI STAGE] API belum sehat. Log terakhir:"
  tail -40 "$LOG_FILE" || true
  exit 1
fi
echo
echo "[ANI STAGE] API staging ONLINE pada port 8788."
echo "[ANI STAGE] Layanan port 8787 tidak disentuh."
