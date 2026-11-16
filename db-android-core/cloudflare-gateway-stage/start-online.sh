#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH_FILE="$SCRIPT_DIR/patch_server_edge_proxy.py"
STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
ENV_FILE="$STAGE_HOME/server/.env"
LOG_DIR="$STAGE_HOME/logs"
TUNNEL_LOG="$LOG_DIR/cloudflare-quick-tunnel.log"
HEALTH_RESPONSE_FILE="$LOG_DIR/public-health-last.json"
PID_FILE="$STAGE_HOME/cloudflare-online.pid"

[ -f "$ENV_FILE" ] || { echo "[ANI ONLINE] .env staging tidak ditemukan. Jalankan configure-online.sh."; exit 1; }
mkdir -p "$LOG_DIR"
set -a
. "$ENV_FILE"
set +a
GATEWAY="${ANI_EDGE_GATEWAY_URL:-https://ani-games-db-android-stage-gateway.anigamesready.workers.dev}"
: "${ANI_EDGE_REGISTER_TOKEN:?ANI_EDGE_REGISTER_TOKEN belum dikonfigurasi}"
: "${ANI_EDGE_PROXY_SECRET:?ANI_EDGE_PROXY_SECRET belum dikonfigurasi}"

# Bring the existing staging API source up to the audited edge + PostgreSQL resilience patch.
[ -f "$PATCH_FILE" ] || { echo "[ANI ONLINE] Patch API tidak ditemukan: $PATCH_FILE"; exit 1; }
command -v python3 >/dev/null 2>&1 || { echo "[ANI ONLINE] Python3 diperlukan untuk patch API staging."; exit 1; }
PATCH_OUTPUT="$(python3 "$PATCH_FILE" "$STAGE_HOME/server")"
printf '%s\n' "$PATCH_OUTPUT"
if printf '%s\n' "$PATCH_OUTPUT" | grep -q 'API_SOURCE_PATCH_APPLIED'; then
  echo "[ANI ONLINE] Source API berubah; memulai ulang API staging secara terkontrol..."
  if [ -f "$STAGE_HOME/stage-api.pid" ]; then
    bash "$STAGE_HOME/stop-stage.sh"
  fi
  if curl -fsS --max-time 3 http://127.0.0.1:8788/health >/dev/null 2>&1; then
    echo "[ANI ONLINE] STOP: port 8788 masih merespons tetapi PID staging tidak berhasil diverifikasi."
    echo "[ANI ONLINE] Tidak akan mematikan proses yang tidak dikenal."
    exit 1
  fi
  bash "$STAGE_HOME/start-stage.sh"
fi

if ! curl -fsS --max-time 5 http://127.0.0.1:8788/health >/dev/null; then
  echo "[ANI ONLINE] API staging port 8788 belum online. Mencoba start..."
  bash "$STAGE_HOME/start-stage.sh"
fi

# Use the native Termux cloudflared package. Termux's Go toolchain patches
# resolver lookup to read $PREFIX/etc/resolv.conf; do not use proot/chroot.
NEEDED_PACKAGES=()
[ -x "$PREFIX/bin/cloudflared" ] || NEEDED_PACKAGES+=(cloudflared)
[ -x "$PREFIX/bin/dig" ] || NEEDED_PACKAGES+=(dnsutils)
if [ "${#NEEDED_PACKAGES[@]}" -gt 0 ]; then
  echo "[ANI ONLINE] Memasang dependensi Termux yang belum ada: ${NEEDED_PACKAGES[*]}"
  pkg install -y "${NEEDED_PACKAGES[@]}"
fi
[ -x "$PREFIX/bin/cloudflared" ] || { echo "[ANI ONLINE] cloudflared Termux belum tersedia."; exit 1; }
[ -x "$PREFIX/bin/dig" ] || { echo "[ANI ONLINE] dnsutils/dig belum tersedia."; exit 1; }
[ -r "$PREFIX/etc/resolv.conf" ] || { echo "[ANI ONLINE] Resolver Termux $PREFIX/etc/resolv.conf tidak dapat dibaca."; exit 1; }


echo "[ANI ONLINE] Menguji DNS SRV Cloudflare melalui resolver Termux..."
DNS_OK=0
for DNS_SERVER in 1.1.1.1 8.8.8.8; do
  DNS_RESULT="$(dig +time=3 +tries=1 +short SRV _v2-origintunneld._tcp.argotunnel.com "@$DNS_SERVER" 2>/dev/null || true)"
  if [ -n "$DNS_RESULT" ]; then
    echo "[ANI ONLINE] DNS SRV berhasil melalui $DNS_SERVER:"
    printf '%s\n' "$DNS_RESULT"
    DNS_OK=1
    break
  fi
done
if [ "$DNS_OK" -ne 1 ]; then
  echo "[ANI ONLINE] DNS SRV gagal melalui 1.1.1.1 dan 8.8.8.8."
  echo "[ANI ONLINE] Resolver Termux:"
  cat "$PREFIX/etc/resolv.conf" 2>&1 || true
  echo "[ANI ONLINE] Tunnel tidak dijalankan. Periksa koneksi/DNS Android; port 8787 tidak disentuh."
  exit 1
fi

if command -v termux-wake-lock >/dev/null 2>&1; then termux-wake-lock || true; fi

TUNNEL_PID=""
STOPPING=0
CLEANED_UP=0
LAST_HEALTH_HTTP="000"
LAST_HEALTH_BODY=""
PUBLIC_HEALTH=""

probe_public_health() {
  : > "$HEALTH_RESPONSE_FILE"
  LAST_HEALTH_HTTP="$(curl -sS --connect-timeout 3 --max-time 5 \
    -o "$HEALTH_RESPONSE_FILE" -w '%{http_code}' "$GATEWAY/health" 2>/dev/null || true)"
  LAST_HEALTH_BODY="$(cat "$HEALTH_RESPONSE_FILE" 2>/dev/null || true)"
  if [ "$LAST_HEALTH_HTTP" = "200" ] && \
      grep -Eq '"api"[[:space:]]*:[[:space:]]*"online"' "$HEALTH_RESPONSE_FILE" && \
      grep -Eq '"database"[[:space:]]*:[[:space:]]*"online"' "$HEALTH_RESPONSE_FILE"; then
    PUBLIC_HEALTH="$LAST_HEALTH_BODY"
    return 0
  fi
  return 1
}

refresh_registration() {
  curl -fsS --max-time 12 -X POST "$GATEWAY/_ani_gateway/register" \
    -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" \
    -H "content-type: application/json" \
    --data-binary "{\"url\":\"$UPSTREAM\"}" >/dev/null
}
cleanup() {
  if [ "$CLEANED_UP" -eq 1 ]; then return; fi
  CLEANED_UP=1
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
echo "[ANI ONLINE] cloudflared dijalankan native dari paket Termux (tanpa proot/chroot)."
echo "[ANI ONLINE] Biarkan Termux berjalan agar koneksi online tetap aktif."
echo "[ANI ONLINE] Tekan CTRL+C untuk menghentikan tunnel saja."
echo

while [ "$STOPPING" -eq 0 ]; do
  : > "$TUNNEL_LOG"
  "$PREFIX/bin/cloudflared" tunnel --url http://127.0.0.1:8788 >"$TUNNEL_LOG" 2>&1 &
  TUNNEL_PID=$!
  echo "$TUNNEL_PID" > "$PID_FILE"

  UPSTREAM=""
  for _ in $(seq 1 60); do
    # Accept only an issued Quick Tunnel hostname (random label is 8-63 chars).
    # Do not mistake Cloudflare's API endpoint api.trycloudflare.com for an upstream.
    UPSTREAM="$(grep -Eo 'https://[a-zA-Z0-9-]{8,63}\.trycloudflare\.com' "$TUNNEL_LOG" | tail -n 1 || true)"
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

  # Do not delete a registered tunnel while the temporary hostname is still warming up.
  echo "[ANI ONLINE] Menunggu API publik siap (hingga sekitar 3 menit)..."
  PUBLIC_HEALTH=""
  for attempt in $(seq 1 24); do
    if probe_public_health; then break; fi
    if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then break; fi
    if (( attempt % 6 == 0 )); then
      echo "[ANI ONLINE] Masih menunggu; HTTP $LAST_HEALTH_HTTP; respons: \${LAST_HEALTH_BODY:-kosong}"
      refresh_registration || echo "[ANI ONLINE] Refresh registry belum berhasil; tunnel tetap dipertahankan."
    fi
    sleep 3
  done

  # Keep the same registered URL and retry until the API is healthy or cloudflared exits.
  if [ -z "$PUBLIC_HEALTH" ] && kill -0 "$TUNNEL_PID" 2>/dev/null; then
    echo "[ANI ONLINE] API publik belum sehat (HTTP $LAST_HEALTH_HTTP). Tunnel TIDAK diputus."
    echo "[ANI ONLINE] Pemeriksaan dilanjutkan otomatis setiap 15 detik."
    HEALTH_RECHECK=0
    while kill -0 "$TUNNEL_PID" 2>/dev/null && [ "$STOPPING" -eq 0 ]; do
      sleep 15
      if ! kill -0 "$TUNNEL_PID" 2>/dev/null; then break; fi
      if probe_public_health; then break; fi
      HEALTH_RECHECK=$((HEALTH_RECHECK + 1))
      if (( HEALTH_RECHECK % 8 == 0 )); then
        echo "[ANI ONLINE] API belum siap; HTTP $LAST_HEALTH_HTTP; respons: \${LAST_HEALTH_BODY:-kosong}"
        refresh_registration || echo "[ANI ONLINE] Refresh registry gagal sementara; mencoba lagi otomatis."
      fi
    done
  fi

  if [ -n "$PUBLIC_HEALTH" ]; then
    echo "[ANI ONLINE] API PUBLIK BERHASIL:"
    printf '%s\n' "$PUBLIC_HEALTH"
    echo
  else
    echo "[ANI ONLINE] Proses tunnel terhenti. Log Cloudflare terakhir:"
    tail -n 30 "$TUNNEL_LOG" || true
    if [ "$STOPPING" -eq 0 ]; then
      curl -fsS --max-time 8 -X POST "$GATEWAY/_ani_gateway/clear" \
        -H "Authorization: Bearer $ANI_EDGE_REGISTER_TOKEN" >/dev/null 2>&1 || true
    fi
    wait "$TUNNEL_PID" 2>/dev/null || true
    TUNNEL_PID=""
    sleep 5
    continue
  fi

  while kill -0 "$TUNNEL_PID" 2>/dev/null && [ "$STOPPING" -eq 0 ]; do
    sleep 120
    kill -0 "$TUNNEL_PID" 2>/dev/null || break
    refresh_registration || echo "[ANI ONLINE] Refresh tunnel gagal; mencoba lagi..."
    if ! probe_public_health; then
      echo "[ANI ONLINE] Tunnel masih berjalan; health HTTP $LAST_HEALTH_HTTP. Pemeriksaan otomatis berlanjut."
    fi
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
