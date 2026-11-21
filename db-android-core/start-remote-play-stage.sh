#!/data/data/com.termux/files/usr/bin/bash
# One-command bootstrap for the isolated Ani Remote Play stage on Termux.
# Never targets the existing DB Android API on port 8787.
set -euo pipefail

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
SECRETS="$HERE/cloudflare-gateway-stage/online-secrets.env"

echo "[ANI REMOTE PLAY] Isolated staging setup"
echo "[ANI REMOTE PLAY] Main API 127.0.0.1:8787 and main database are out of scope."
echo

[ -f "$SECRETS" ] || {
  echo "[ANI REMOTE PLAY] File rahasia gateway belum ditemukan:"
  echo "  $SECRETS"
  echo "[ANI REMOTE PLAY] Salin file privat online-secrets.env ke lokasi tersebut, lalu jalankan ulang."
  exit 2
}
chmod 600 "$SECRETS"

if [ ! -f "$STAGE_HOME/server/.env" ]; then
  if [ -e "$STAGE_HOME" ]; then
    echo "[ANI REMOTE PLAY] STOP: folder staging sudah ada tetapi .env belum ada."
    echo "[ANI REMOTE PLAY] Tidak akan menimpa instalasi yang mungkin belum selesai."
    echo "[ANI REMOTE PLAY] Periksa folder $STAGE_HOME dan lakukan pemulihan manual."
    exit 2
  fi
  echo "[ANI REMOTE PLAY] Membuat database staging baru dan memasang skema 000, 002–019..."
  bash "$HERE/setup-stage.sh"
else
  echo "[ANI REMOTE PLAY] Instalasi staging sudah ada; tidak membuat ulang database."
fi

[ -f "$STAGE_HOME/server/.env" ] || {
  echo "[ANI REMOTE PLAY] STOP: konfigurasi staging belum lengkap."
  exit 2
}

echo
echo "[ANI REMOTE PLAY] Mengaktifkan HTTPS gateway staging..."
bash "$HERE/cloudflare-gateway-stage/configure-online.sh"

echo
echo "[ANI REMOTE PLAY] Memulai tunnel. Biarkan Termux berjalan."
echo "[ANI REMOTE PLAY] Tunggu pesan API PUBLIK BERHASIL sebelum membuka aplikasi Android."
exec bash "$HERE/cloudflare-gateway-stage/start-online.sh"
