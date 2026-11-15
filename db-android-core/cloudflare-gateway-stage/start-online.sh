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
GATEWAY="${ANI_EDGE_GATEWAY_URL:-https://ani-games-db-android-stage-gateway.anigamesready.workers.dev}"
: "${ANI_EDGE_REGISTER_TOKEN:?ANI_EDGE_REGISTER_TOKEN belum dikonfigurasi}"
: "${ANI_EDGE_PROXY_SECRET:?ANI_EDGE_PROXY_SECRET belum dikonfigurasi}"

if ! curl -fsS --max-time 5 http://127.0.0.1:8788/health >/dev/null; then
  echo "[ANI ONLINE] API staging port 8788 belum online. Mencoba start..."
  bash "$STAGE_HOME/start-stage.sh"
fi

# Install only the missing Termux packages. termux-chroot binds
# $PREFIX/etc to /etc so Go binaries can read a conventional resolver file.
NEEDED_PACKAGES=()
[ -x "$PREFIX/bin/cloudflared" ] || NEEDED_PACKAGES+=(cloudflared)
[ -x "$PREFIX/bin/termux-chroot" ] || NEEDED_PACKAGES+=(proot)
[ -x "$PREFIX/bin/dig" ] || NEEDED_PACKAGES+=(dnsutils)
if [ "${#NEEDED_PACKAGES[@]}" -gt 0 ]; then
  echo "[ANI ONLINE] Memasang dependensi Termux yang belum ada: ${NEEDED_PACKAGES[*]}"
  pkg install -y "${NEEDED_PACKAGES[@]}"
fi
[ -x "$PREFIX/bin/cloudflared" ] || { echo "[ANI ONLINE] cloudflared Termux belum tersedia."; exit 1; }
[ -x "$PREFIX/bin/termux-chroot" ] || { echo "[ANI ONLINE] proot/termux-chroot belum tersedia."; exit 1; }
[ -x "$PREFIX/bin/dig" ] || { echo "[ANI ONLINE] dnsutils/dig belum tersedia."; exit 1; }
[ -r "$PREFIX/etc/resolv.conf" ] || { echo "[ANI ONLINE] Resolver Termux $PREFIX/etc/resolv.conf tidak dapat dibaca."; exit 1; }

echo "[ANI ONLINE] Menguji DNS SRV Cloudflare melalui resolver Termux..."
DNS_OK=0
for DNS_SERVER in 1.1.1.1 8.8.8.8; do
  DNS_RESULT="$(termux-chroot "dig +time=3 +tries=1 +short SRV _v2-origintunneld._tcp.argotunnel.com @$DNS_SERVER" 2>/dev/null || true)"
  if [ -n "$DNS_RESULT" ]; then
    echo "[ANI ONLINE] DNS SRV berhasil melalui $DNS_SERVER:"
    printf '%s\n' "$DNS_RESULT"
    DNS_OK=1
    break
  fi
done
if [ "$DNS_OK" -ne 1 ]; then
  echo "[ANI ONLINE] DNS SRV gagal melalui 1.1.1.1 dan 8.8.8.8."
  echo "[ANI ONLINE] Isi resolver yang dilihat dari termux-chroot:"
  termux-chroot "cat /etc/resolv.conf" 2>&1 || true
  echo "[ANI ONLINE] Tunnel tidak dijalankan. Periksa koneksi/DNS Android; port 8787 tidak disentuh."
  exit 1
fi

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
echo "[ANI ONLINE] cloudflared dijalankan melalui termux-chroot agar /etc/resolv.conf tersedia."
echo "[ANI ONLINE] Biarkan Termux berjalan agar koneksi online tetap aktif."
echo "[ANI ONLINE] Tekan CTRL+C untuk menghentikan tunnel saja."
echo

while [ "$STOPPING" -eq 0 ]; do
  : > "$TUNNEL_LOG"
  termux-chroot "/bin/cloudflared tunnel --url http://127.0.0.1:8788" >"$TUNNEL_LOG" 2>&1 &
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
    tail -n 30 "$TUNNEL_LOG" || true
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
  echo "[ANI ONLINE] Uji status registry gateway:"
  if ! curl -fsS --max-time 15 "$GATEWAY/_ani_gateway/health"; then
    echo
    echo "[ANI ONLINE] Gateway belum melaporkan upstream aktif. Tunnel akan dibuat ulang."
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    curl -fsS --max-time 8 -X POST "$GATEWAY/_ani_gateway/clear" \
      -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" >/dev/null 2>&1 || true
    sleep 10
    continue
  fi
  echo

  # This checks the actual public API path, not just the Worker's KV registry.
  PUBLIC_HEALTH=""
  for _ in $(seq 1 8); do
    PUBLIC_HEALTH="$(curl -fsS --max-time 10 "$GATEWAY/health" 2>/dev/null || true)"
    [ -n "$PUBLIC_HEALTH" ] && break
    sleep 2
  done
  if [ -z "$PUBLIC_HEALTH" ]; then
    echo "[ANI ONLINE] Gateway tercatat aktif, tetapi API publik /health belum berhasil."
    echo "[ANI ONLINE] Membersihkan URL lama dan membuat tunnel baru."
    kill "$TUNNEL_PID" 2>/dev/null || true
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    curl -fsS --max-time 8 -X POST "$GATEWAY/_ani_gateway/clear" \
      -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" >/dev/null 2>&1 || true
    sleep 10
    continue
  fi
  echo "[ANI ONLINE] API publik /health berhasil:"
  printf '%s\n' "$PUBLIC_HEALTH"
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
