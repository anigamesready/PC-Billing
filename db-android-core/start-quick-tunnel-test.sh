#!/data/data/com.termux/files/usr/bin/bash
# TEMPORARY TEST ONLY — exposes the isolated local API over a random HTTPS Quick Tunnel.
# It does not create a named tunnel, change DNS, or touch the existing Blynk/WoL relay.
set -euo pipefail

STAGE_HOME="\${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
API_URL="http://127.0.0.1:8788/health"

if ! curl -fsS "$API_URL" >/dev/null 2>&1; then
  echo "[ANI TUNNEL] API staging port 8788 is not online."
  echo "[ANI TUNNEL] Start it first:"
  echo "  bash $STAGE_HOME/start-stage.sh"
  exit 1
fi

if ! command -v cloudflared >/dev/null 2>&1; then
  if ! command -v pkg >/dev/null 2>&1; then
    echo "[ANI TUNNEL] Termux pkg command not found."
    exit 1
  fi
  echo "[ANI TUNNEL] Installing cloudflared from the Termux package repository..."
  pkg install cloudflared -y
fi

command -v cloudflared >/dev/null 2>&1 || {
  echo "[ANI TUNNEL] cloudflared installation did not complete."
  exit 1
}

echo
echo "[ANI TUNNEL] TEMPORARY TEST TUNNEL — do not rely on it for 24/7 production."
echo "[ANI TUNNEL] Cloudflare assigns a random HTTPS URL. It changes after restart."
echo "[ANI TUNNEL] Anyone who knows the URL can reach the API endpoint; app login/device tokens still apply."
echo "[ANI TUNNEL] Copy the https://....trycloudflare.com URL printed below into the PC Billing Server URL field."
echo "[ANI TUNNEL] Press CTRL+C to close the tunnel. API 8788 and server 8787 remain running."
echo

exec cloudflared tunnel --url http://127.0.0.1:8788
