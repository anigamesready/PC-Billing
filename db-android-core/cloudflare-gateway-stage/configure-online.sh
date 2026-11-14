#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
ENV_FILE="$STAGE_HOME/server/.env"
SECRETS_FILE="$HERE/online-secrets.env"
PATCH_FILE="$HERE/patch_server_edge_proxy.py"

[ -d "$STAGE_HOME/server" ] || { echo "[ANI ONLINE] Folder staging tidak ditemukan: $STAGE_HOME"; exit 1; }
[ -f "$ENV_FILE" ] || { echo "[ANI ONLINE] .env staging tidak ditemukan."; exit 1; }
[ -f "$SECRETS_FILE" ] || { echo "[ANI ONLINE] online-secrets.env tidak ditemukan."; exit 1; }
[ -f "$PATCH_FILE" ] || { echo "[ANI ONLINE] Patch server tidak ditemukan."; exit 1; }

set -a
. "$SECRETS_FILE"
set +a
: "${GATEWAY_REGISTER_TOKEN:?GATEWAY_REGISTER_TOKEN kosong}"
: "${EDGE_PROXY_SECRET:?EDGE_PROXY_SECRET kosong}"
: "${GATEWAY_BASE_URL:?GATEWAY_BASE_URL kosong}"

case "$GATEWAY_BASE_URL" in https://*.workers.dev) ;; *) echo "[ANI ONLINE] Gateway harus HTTPS workers.dev."; exit 1;; esac
[ "${#GATEWAY_REGISTER_TOKEN}" -ge 32 ] || { echo "[ANI ONLINE] Register token terlalu pendek."; exit 1; }
[ "${#EDGE_PROXY_SECRET}" -ge 32 ] || { echo "[ANI ONLINE] Edge secret terlalu pendek."; exit 1; }

if ! grep -q '^ANI_BIND=127\.0\.0\.1$' "$ENV_FILE"; then
  echo "[ANI ONLINE] ANI_BIND bukan 127.0.0.1; dibatalkan demi keamanan."
  exit 1
fi
if ! grep -q '^PORT=8788$' "$ENV_FILE"; then
  echo "[ANI ONLINE] PORT bukan 8788; server lama tidak boleh disentuh."
  exit 1
fi

python3 "$PATCH_FILE" "$STAGE_HOME/server"

python3 - "$ENV_FILE" "$EDGE_PROXY_SECRET" "$GATEWAY_REGISTER_TOKEN" "$GATEWAY_BASE_URL" <<'PY'
import sys
from pathlib import Path

path = Path(sys.argv[1])
values = {
    "ANI_EDGE_PROXY_SECRET": sys.argv[2],
    "ANI_EDGE_REGISTER_TOKEN": sys.argv[3],
    "ANI_EDGE_GATEWAY_URL": sys.argv[4],
}
lines = path.read_text(encoding="utf-8").splitlines()
for key, value in values.items():
    replacement = f"{key}={value}"
    positions = [i for i, line in enumerate(lines) if line.startswith(key + "=")]
    if positions:
        lines[positions[0]] = replacement
        for i in reversed(positions[1:]):
            del lines[i]
    else:
        lines.append(replacement)
path.write_text("\n".join(lines) + "\n", encoding="utf-8")
PY

chmod 600 "$ENV_FILE"
echo "[ANI ONLINE] Memulai ulang API STAGING saja (port 8788)..."
bash "$STAGE_HOME/stop-stage.sh" || true
bash "$STAGE_HOME/start-stage.sh"
echo
echo "[ANI ONLINE] Konfigurasi HTTPS gateway selesai."
echo "[ANI ONLINE] API lokal masih loopback-only 127.0.0.1:8788."
echo "[ANI ONLINE] Tidak mengubah port 8787, database produksi, maupun relay Blynk/WoL."
echo "[ANI ONLINE] Selanjutnya jalankan: bash $HERE/start-online.sh"
