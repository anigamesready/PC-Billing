#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
export ANI_CLOUDFLARED_MODE="proot"
export ANI_CLOUDFLARED_PROOT_CONTAINER="${ANI_CLOUDFLARED_PROOT_CONTAINER:-ani-cf-tunnel}"

exec bash "$SCRIPT_DIR/start-online.sh"
