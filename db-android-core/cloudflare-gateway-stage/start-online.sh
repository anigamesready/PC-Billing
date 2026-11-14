#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
ENV_FILE="$STAGE_HOME/server/.env"
LOG_DIR="$STAGE_HOME/logs"
TUNNEL_LOG="$LOG_DIR/cloudflare-quick-tunnel.log"
PID_FILE="$STAGE_HOME/cloudflare-online.pid"

[ -f "$ENV_FILE" ] || { echo "[ANI ONLINE] .env staging tidak ditemukan. Jalankan configure-online.sh."; exit 1; }
mkdir -p "$LOG_DIR"
set -a
. "$ENV_FILE"
set +a
GATEWAY="${ANI_EDGE_GATEWAY_URL:-https://ani-games-db-android-stage.anigamesready.workers.dev}"
: "${ANI_EDGE_REGISTER_TOKEN:?ANI_EDGE_REGISTER_TOKEN belum dikonfigurasi}"
: "${ANI_EDGE_PROXY_SECRET:?ANI_EDGE_PROXY_SECRET belum dikonfigurasi}"

if ! curl -fsS --max-time 5 http://127.0.0.1:8788/health >/dev/null; then
  echo "[ANI ONLINE] API staging port 8788 belum online. Mencoba start..."
  bash "$STAGE_HOME/start-stage.sh"
fi
if ! command -v cloudflared >/dev/null 2>&1; then
  echo "[ANI ONLINE] Menginstal cloudflared dari repository resmi Termux..."
  pkg install cloudflared -y
fi
command -v cloudflared >/dev/null 2>&1 || { echo "[ANI ONLINE] cloudflared belum terpasang."; exit 1; }

if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock || true; fi

TUNNEL_PID=""
STOPPING=0
cleanup() {
  STOPPING=1
  if [ -n "$TUNNEL_PID" ]; then
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
  fi
  curl -fsS --max-time 8 -X POST "$GATEWAY/_ani_gateway/clear" \
    -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" >/dev/null 2>&1 || true
  rm -f "$PID_FILE"
  if command -v termux-wake-unlock >/dev/null 2>&1; then termux-wake-unlock || true; fi
  echo "[ANI ONLINE] Tunnel dihentikan. API lokal dan port 8787 tidak disentuh."
}
trap cleanup EXIT INT TERM

echo "[ANI ONLINE] Gateway HTTPS: $GATEWAY"
echo "[ANI ONLINE] Port lokal tetap 127.0.0.1:8788; tunnel akan reconnect otomatis."
echo "[ANI ONLINE] Biarkan Termux berjalan agar koneksi online tetap aktif."
echo "[ANI ONLINE] Tekan CTRL+C untuk menghentikan tunnel saja."
echo

while [ "$STOPPING" -eq 0 ]; do
  : > "$TUNNEL_LOG"
  cloudflared tunnel --url http://127.0.0.1:8788 >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  echo "$TUNNEL_PID" > "$PID_FILE"

  UPSTREAM=""
  for _ in $(seq 1 60); do
    UPSTREAM="$(grep -Eo 'https://[a-zA-Z0-9-]+\.trycloudflare\.com' "$TUNNEL_LOG" | tail -n 1 || true)"
    [ -n "$UPSTREAM" ] && break
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    sleep 1
  done

  if [ -z "$UPSTREAM" ]; then
    echo "[ANI ONLINE] URL tunnel belum muncul. Log:"
    tail -n 20 "$TUNNEL_LOG" || true
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    sleep 10
    continue
  fi

  echo "[ANI ONLINE] Tunnel mendapat URL sementara, mendaftarkan ke gateway..."
  if ! curl -fsS --max-time 12 -X POST "$GATEWAY/_ani_gateway/register" \
      -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" \
      -H "content-type: application/json" \
      --data-binary "{\"url\":\"$UPSTREAM\"}"; then
    echo
    echo "[ANI ONLINE] Registrasi gagal. Tunnel akan dibuat ulang."
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    sleep 10
    continue
  fi
  echo
  echo "[ANI ONLINE] Uji gateway:"
  curl -fsS --max-time 15 "$GATEWAY/_ani_gateway/health" || true
  echo

  while kill -0 "$TUNNEL_PID" 2>/dev/null && [ "$STOPPING" -eq 0 ]; do
    sleep 120
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    curl -fsS --max-time 12 -X POST "$GATEWAY/_ani_gateway/register" \
      -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" \
      -H "content-type: application/json" \
      --data-binary "{\"url\":\"$UPSTREAM\"}" >/dev/null || echo "[ANI ONLINE] Refresh tunnel gagal; mencoba lagi..."
  done

  if [ "$STOPPING" -eq 0 ]; then
    echo "[ANI ONLINE] Tunnel terputus; membersihkan alamat lama lalu reconnect..."
    curl -fsS --max-time 8 -X POST "$GATEWAY/_ani_gateway/clear" \
      -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" >/dev/null 2>&1 || true
  fi
  wait "$TUNNEL_PID" 2>/dev/null || true
  TUNNEL_PID=""
  sleep 5
done
