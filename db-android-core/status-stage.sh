#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
PID_FILE="$HERE/stage-api.pid"
if [ -f "$PID_FILE" ]; then
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  if [ -n "$PID" ] && kill -0 "$PID" 2>/dev/null; then
    CWD="$(readlink "/proc/$PID/cwd" 2>/dev/null || true)"
    if [ "$CWD" = "$HERE/server" ]; then
      echo "[ANI STAGE] PID=$PID"
      curl -fsS http://127.0.0.1:8788/health
      exit 0
    fi
  fi
fi
echo "[ANI STAGE] API staging OFFLINE."
exit 1
