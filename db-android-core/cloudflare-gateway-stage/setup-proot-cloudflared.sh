#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail

CONTAINER="${ANI_CLOUDFLARED_PROOT_CONTAINER:-ani-cf-tunnel}"
VERSION="2026.11.0"
CLOUDFLARED_SHA256="abe54a006acf9faf2d19ee9d953cb0d0804e92f59c5382a162e57b84d086f56f"
IMAGE="debian:bookworm"

echo "[ANI PROOT] Memeriksa arsitektur HP..."
case "$(uname -m)" in
  aarch64|arm64) ;;
  *) echo "[ANI PROOT] STOP: image Cloudflared ini disiapkan untuk ARM64."; exit 1 ;;
esac

if ! command -v proot-distro >/dev/null 2>&1; then
  echo "[ANI PROOT] Memasang PRoot-Distro (tidak memerlukan root)..."
  pkg install -y proot-distro
fi

if ! proot-distro list -q | grep -Fxq "$CONTAINER"; then
  echo "[ANI PROOT] Memasang Linux $IMAGE sebagai container terpisah: $CONTAINER"
  proot-distro install "$IMAGE" --name "$CONTAINER"
else
  echo "[ANI PROOT] Container $CONTAINER sudah ada; tidak di-reset."
fi

echo "[ANI PROOT] Menyiapkan DNS khusus di dalam Linux guest..."
proot-distro login "$CONTAINER" -- /bin/bash -lc "
set -euo pipefail
printf 'nameserver 1.1.1.1\\nnameserver 8.8.8.8\\noptions timeout:3 attempts:2\\n' > /etc/resolv.conf
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends ca-certificates curl dnsutils
if ! /usr/local/bin/cloudflared --version 2>/dev/null | grep -Fq '$VERSION'; then
  echo '[ANI PROOT] Mengunduh Cloudflared resmi versi $VERSION ARM64...'
  rm -f /tmp/cloudflared
  curl -fL --retry 3 --retry-delay 2 'https://github.com/cloudflare/cloudflared/releases/download/$VERSION/cloudflared-linux-arm64' -o /tmp/cloudflared
  ACTUAL_SHA256="$(sha256sum /tmp/cloudflared | awk '{print $1}')"
  if [ "$ACTUAL_SHA256" != '$CLOUDFLARED_SHA256' ]; then
    rm -f /tmp/cloudflared
    echo '[ANI PROOT] STOP: SHA-256 binary tidak cocok dengan rilis resmi.'
    exit 1
  fi
  install -m 0755 /tmp/cloudflared /usr/local/bin/cloudflared
  rm -f /tmp/cloudflared
fi
echo '[ANI PROOT] Versi Cloudflared:'
/usr/local/bin/cloudflared --version
echo '[ANI PROOT] Menguji A record API Quick Tunnel...'
getent ahostsv4 api.trycloudflare.com | sed -n '1,2p'
echo '[ANI PROOT] Menguji DNS SRV edge Cloudflare...'
dig +time=4 +tries=1 +short SRV _v2-origintunneld._tcp.argotunnel.com @1.1.1.1 | grep '7844'
"

echo "[ANI PROOT] SETUP SELESAI."
echo "[ANI PROOT] API PostgreSQL/Node tetap di Termux; hanya tunnel memakai Linux guest."
echo "[ANI PROOT] Jalankan: bash ~/ani-games-db-android-stage/cloudflare-gateway-stage/start-online-proot.sh"
