#!/usr/bin/env bash
set -euo pipefail
DIR="$(cd "$(dirname "$0")" && pwd)"
RUNNER="$DIR/start-online.sh"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
HOME_TEST="$TMP/home"
PREFIX_TEST="$TMP/prefix"
MOCK_BIN="$TMP/mock-bin"
mkdir -p "$HOME_TEST/stage/server" "$HOME_TEST/stage/logs" "$PREFIX_TEST/bin" "$PREFIX_TEST/etc" "$MOCK_BIN"

cat > "$HOME_TEST/stage/server/.env" <<'ENV'
ANI_EDGE_REGISTER_TOKEN=register-token-test-012345678901234567890123
ANI_EDGE_PROXY_SECRET=edge-secret-test-012345678901234567890123456789
ANI_EDGE_GATEWAY_URL=https://ani-games-db-android-stage-gateway.anigamesready.workers.dev
ENV

cp "$DIR/../server/server.mjs" "$HOME_TEST/stage/server/server.mjs"
printf '12345\n' > "$HOME_TEST/stage/stage-api.pid"
cat > "$HOME_TEST/stage/stop-stage.sh" <<'STOP'
#!/usr/bin/env bash
printf 'stop\n' >> "$HOME_TEST/api-restart.log"
STOP
cat > "$HOME_TEST/stage/start-stage.sh" <<'START'
#!/usr/bin/env bash
printf 'start\n' >> "$HOME_TEST/api-restart.log"
: > "$ANI_TEST_RESTART"
START
chmod +x "$HOME_TEST/stage/stop-stage.sh" "$HOME_TEST/stage/start-stage.sh"
printf 'nameserver 1.1.1.1\n' > "$PREFIX_TEST/etc/resolv.conf"

cat > "$PREFIX_TEST/bin/dig" <<'DIG'
#!/usr/bin/env bash
printf '1 1 7844 region1.v2.argotunnel.com\n'
DIG
cat > "$PREFIX_TEST/bin/cloudflared" <<'CLOUD'
#!/usr/bin/env bash
printf 'Your quick Tunnel has been created! Visit it at https://ani-stage-smoke-123.trycloudflare.com\n'
exec sleep 60
CLOUD
cat > "$MOCK_BIN/curl" <<'CURL'
#!/usr/bin/env bash
URL=""
OUT=""
WRITE=""
while [ "$#" -gt 0 ]; do
  case "$1" in
    -o) OUT="$2"; shift 2 ;;
    -w) WRITE="$2"; shift 2 ;;
    http://*|https://*) URL="$1"; shift ;;
    *) shift ;;
  esac
done
case "$URL" in
  http://127.0.0.1:8788/health)
    if [ ! -f "$ANI_TEST_RESTART" ]; then exit 7; fi
    BODY='{"app":"Ani Games Ready Local Server","api":"online","database":"online","apiVersion":"db-android-v1"}'
    CODE=200 ;;
  https://*/_ani_gateway/register)
    BODY='{"ok":true,"registered":true,"expires_in":600}'
    CODE=200 ;;
  https://*/_ani_gateway/clear)
    BODY='{"ok":true,"cleared":true}'
    CODE=200 ;;
  https://*/health)
    COUNT_FILE="$HOME/health-count"
    COUNT=0
    [ -f "$COUNT_FILE" ] && COUNT="$(cat "$COUNT_FILE")"
    COUNT=$((COUNT + 1))
    printf '%s' "$COUNT" > "$COUNT_FILE"
    if [ "$COUNT" -lt 3 ]; then
      BODY='{"error":"STAGE_UPSTREAM_UNREACHABLE"}'
      CODE=502
    else
      BODY='{"app":"Ani Games Ready Local Server","api":"online","database":"online","apiVersion":"db-android-v1"}'
      CODE=200
    fi ;;
  *) echo "unexpected curl URL: $URL" >&2; exit 90 ;;
esac
if [ -n "$OUT" ]; then
  printf '%s' "$BODY" > "$OUT"
elif [[ "$URL" != */health ]]; then
  printf '%s' "$BODY"
fi
if [ -n "$WRITE" ]; then printf '%s' "$CODE"; fi
exit 0
CURL

chmod +x "$PREFIX_TEST/bin/dig" "$PREFIX_TEST/bin/cloudflared" "$MOCK_BIN/curl"
set +e
OUTPUT="$(ANI_TEST_LOG="$HOME_TEST/api-restart.log" ANI_TEST_RESTART="$HOME_TEST/api-restarted" HOME="$HOME_TEST" PREFIX="$PREFIX_TEST" ANI_DB_STAGE_HOME="$HOME_TEST/stage" \
  PATH="$MOCK_BIN:$PREFIX_TEST/bin:$PATH" timeout -s TERM 9s bash "$RUNNER" 2>&1)"
set -e
printf '%s\n' "$OUTPUT"
printf '%s' "$OUTPUT" | grep -q 'API PUBLIK BERHASIL' || {
  echo "FAIL: runner did not recover to healthy public API" >&2
  exit 1
}
if printf '%s' "$OUTPUT" | grep -q 'Membersihkan URL lama'; then
  echo "FAIL: runner prematurely clears the tunnel on transient health failure" >&2
  exit 1
fi
echo "PASS: transient public-health failures do not trigger tunnel deletion; runner recovers automatically."
grep -q 'ANI-DB-ANDROID-CLOUDFLARE-EDGE-TRUST-V1' "$HOME_TEST/stage/server/server.mjs"
grep -q 'ANI-DB-ANDROID-PG-POOL-ERROR-HANDLER-V1' "$HOME_TEST/stage/server/server.mjs"
grep -q '^stop$' "$HOME_TEST/api-restart.log"
grep -q '^start$' "$HOME_TEST/api-restart.log"
echo "PASS: runner applies API security/resilience patch and restarts only the managed staging service."