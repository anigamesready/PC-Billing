#!/data/data/com.termux/files/usr/bin/bash
# Ani Games Ready — simple DB Android staging menu.
# Safe scope: staging API 8788 + Cloudflare gateway; never manages port 8787.
set -uo pipefail

GATEWAY="https://ani-games-db-android-stage-gateway.anigamesready.workers.dev"
HOST="ani-games-db-android-stage-gateway.anigamesready.workers.dev"
STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
RUNNER="${ANI_DB_STAGE_RUNNER:-$HOME/ani-remote-stage-package/Ani-Games-Ready-DB-Android-Termux-STAGE/cloudflare-gateway-stage/start-online-proot.sh}"
CA_BUNDLE="${PREFIX:-/data/data/com.termux/files/usr}/etc/tls/cert.pem"
TMP="$HOME/.ani-gateway-health.tmp"

export CURL_CA_BUNDLE="$CA_BUNDLE"
export SSL_CERT_FILE="$CA_BUNDLE"
unset CURL_CA_BUNDLE_OLD SSL_CERT_DIR

pause() { printf '\nTekan Enter untuk kembali ke menu...'; read -r _; }
line() { printf '%s\n' '-----------------------------------------------'; }

local_health() {
  if ! command -v curl >/dev/null 2>&1; then
    echo "curl belum tersedia."
    return 1
  fi
  echo "API staging lokal (127.0.0.1:8788):"
  curl -sS --connect-timeout 2 --max-time 5 http://127.0.0.1:8788/health || echo "API lokal belum merespons."
  echo
}
gateway_health() {
  local code
  echo "Gateway HTTPS (sertifikat diverifikasi):"
  if code="$(curl -sS --connect-timeout 5 --max-time 12 -o "$TMP" -w '%{http_code}' "$GATEWAY/_ani_gateway/health")"; then
    echo "HTTP $code"
    cat "$TMP" 2>/dev/null || true
    echo
    case "$code" in
      200) echo "TLS OK; gateway sudah punya upstream aktif." ;;
      503) echo "TLS OK; gateway terjangkau, tetapi upstream tunnel belum terdaftar." ;;
      *) echo "TLS OK; respons Worker perlu diperiksa." ;;
    esac
    return 0
  else
    echo "GAGAL TLS/DNS/JARINGAN: alamat Worker tidak dapat diverifikasi."
    echo "Jangan matikan verifikasi SSL dan jangan lanjutkan start tunnel."
    return 1
  fi
}
runner_process() {
  local pid=""
  if [ -f "$STAGE_HOME/cloudflare-online.pid" ]; then
    pid="$(cat "$STAGE_HOME/cloudflare-online.pid" 2>/dev/null || true)"
  fi
  if [ -n "$pid" ] && kill -0 "$pid" 2>/dev/null; then
    echo "$pid"
    return 0
  fi
  return 1
}
show_status() {
  line
  echo "STATUS ANI GAMES READY — DB ANDROID STAGING"
  line
  if [ -x "$CA_BUNDLE" ] || [ -s "$CA_BUNDLE" ]; then
    echo "CA Termux: tersedia"
  else
    echo "CA Termux: belum ditemukan ($CA_BUNDLE)"
  fi
  if runner_process >/dev/null; then
    echo "Tunnel runner: berjalan (PID $(runner_process))"
  else
    echo "Tunnel runner: tidak berjalan"
  fi
  local_health
  gateway_health || true
  line
}
start_service() {
  if [ ! -f "$RUNNER" ]; then
    echo "Runner tidak ditemukan:"
    echo "$RUNNER"
    echo "Periksa lokasi folder paket. Tidak ada data yang diubah."
    return 1
  fi
  if runner_process >/dev/null; then
    echo "Runner sudah berjalan (PID $(runner_process)). Tidak membuat tunnel kedua."
    return 0
  fi
  if [ ! -s "$CA_BUNDLE" ]; then
    echo "CA bundle Termux tidak ditemukan. Pilih menu 3 terlebih dahulu."
    return 1
  fi
  echo "Memeriksa HTTPS Worker sebelum membuat tunnel..."
  if ! gateway_health; then
    echo
    echo "Belum aman menjalankan tunnel. Periksa VPN/proxy/Private DNS atau coba jaringan lain."
    echo "Jangan mengganti alamat gateway dan jangan gunakan curl -k."
    return 1
  fi
  echo
  echo "Menjalankan API staging dan tunnel..."
  echo "Biarkan layar ini aktif sampai muncul: API PUBLIK BERHASIL"
  echo "Kembali dari runner dengan CTRL+C (tunnel saja yang dihentikan)."
  export PROOT_NO_SECCOMP=1
  exec bash "$RUNNER"
}
repair_ca() {
  echo "Memperbarui CA resmi Termux. Verifikasi SSL tetap aktif."
  if ! command -v apt-get >/dev/null 2>&1; then
    echo "apt-get tidak tersedia di Termux."
    return 1
  fi
  apt-get update && apt-get install -y ca-certificates
  if [ -s "$CA_BUNDLE" ]; then
    export CURL_CA_BUNDLE="$CA_BUNDLE" SSL_CERT_FILE="$CA_BUNDLE"
    echo "CA bundle siap: $CA_BUNDLE"
    gateway_health || true
  else
    echo "CA bundle belum tersedia setelah pembaruan."
    return 1
  fi
}
show_logs() {
  local f="$STAGE_HOME/logs/cloudflare-quick-tunnel.log"
  if [ -f "$f" ]; then
    echo "Log tunnel terakhir:"
    tail -n 45 "$f"
  else
    echo "Log tunnel belum ada: $f"
  fi
  echo
  f="$STAGE_HOME/logs/stage-api.log"
  if [ -f "$f" ]; then
    echo "Log API staging terakhir:"
    tail -n 30 "$f"
  fi
}

while true; do
  clear 2>/dev/null || true
  line
  echo "       ANI GAMES READY — DB ANDROID"
  echo "              MENU SERVER"
  line
  echo "1. Jalankan / Sambungkan server"
  echo "2. Cek status koneksi"
  echo "3. Perbaiki CA sertifikat Termux"
  echo "4. Lihat log error"
  echo "5. Keluar"
  line
  printf "Pilih menu [1-5]: "
  read -r choice
  case "$choice" in
    1) start_service; pause ;;
    2) show_status; pause ;;
    3) repair_ca; pause ;;
    4) show_logs; pause ;;
    5) rm -f "$TMP"; exit 0 ;;
    *) echo "Pilihan tidak dikenal."; pause ;;
  esac
done
