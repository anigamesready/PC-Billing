#!/usr/bin/env bash
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "$0")/.." && pwd)"
SCRIPT="$ROOT_DIR/repair-stage-bootstrap.sh"
ROOT="$(mktemp -d)"
FAKE_PID=""
cleanup() {
  if [[ -n "$FAKE_PID" ]]; then kill "$FAKE_PID" 2>/dev/null || true; fi
  rm -rf "$ROOT"
}
trap cleanup EXIT

export MOCK_ROOT="$ROOT"
export TOKEN='aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
mkdir -p "$ROOT/bin" "$ROOT/stage/server" "$ROOT/stage/logs"
cat > "$ROOT/stage/server/.env" <<EOF2
DATABASE_URL=postgresql://ani_api_stage_login:bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb@127.0.0.1:5432/ani_games_ready_stage?sslmode=disable
ANI_BIND=127.0.0.1
PORT=8788
ANI_API_PEPPER=cccccccccccccccccccccccccccccccc
ANI_ADMIN_BOOTSTRAP_TOKEN=$TOKEN
ANI_ALLOWED_ORIGINS=
EOF2
chmod 600 "$ROOT/stage/server/.env"

cat > "$ROOT/bin/psql" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *" -c "* ]]; then SQL=""; else SQL="$(cat)"; fi
if [[ "$args" != *"-h 127.0.0.1"* || "$args" != *"-p 5432"* ]]; then
  echo "psql did not use loopback TCP 127.0.0.1:5432" >&2
  exit 91
fi
if [[ "$args" == *"rolsuper"* ]]; then
  printf '%s\n' "${MOCK_ADMIN_SUPERUSER:-t}"
  exit 0
fi
if [[ "$SQL" == *"INSERT INTO private.admin_bootstrap_control"* ]]; then
  touch "$MOCK_ROOT/updated" "$MOCK_ROOT/row"
  exit 0
fi
if [[ "$SQL" == *"SELECT"* ]]; then
  if [[ -f "$MOCK_ROOT/owner" ]]; then owner=t; else owner=f; fi
  if [[ -f "$MOCK_ROOT/row" ]]; then row=t; else row=f; fi
  if [[ -f "$MOCK_ROOT/consumed" ]]; then consumed=t; else consumed=f; fi
  if [[ -f "$MOCK_ROOT/updated" || -f "$MOCK_ROOT/matched" ]]; then match=t; else match=f; fi
  printf '%s|%s|%s|%s\n' "$owner" "$row" "$consumed" "$match"
  exit 0
fi
echo 'unexpected SQL in mock' >&2
exit 2
EOF2

cat > "$ROOT/bin/curl" <<'EOF2'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
if [[ "$args" == *"/health"* ]]; then
  printf '%s\n' '{"app":"Ani Games Ready Local Server","api":"online","database":"online","apiVersion":"db-android-v1","remote_access_enabled":false,"bind_host":"127.0.0.1","relay":"separate"}'
else
  printf '%s\n400' '{"ok":false,"error":"ADMIN_BOOTSTRAP_INPUT_INVALID"}'
fi
EOF2
chmod +x "$ROOT/bin/psql" "$ROOT/bin/curl"

# Fake a verified Node process. Its argv and current directory mimic the stage API PID guard.
( cd "$ROOT/stage/server" && env ANI_ADMIN_BOOTSTRAP_TOKEN="$TOKEN" bash -c 'exec -a "node server.mjs" sleep 120' ) &
FAKE_PID=$!
sleep 0.2
printf '%s\n' "$FAKE_PID" > "$ROOT/stage/stage-api.pid"
export HOME="$ROOT"
export ANI_DB_STAGE_HOME="$ROOT/stage"
export PATH="$ROOT/bin:$PATH"

printf 'TEST 1 — missing bootstrap-control row\n'
bash "$SCRIPT"
test -f "$ROOT/updated"
printf 'PASS: inserted matching hash; safe invalid-input probe passed.\n\n'

printf 'TEST 2 — existing unconsumed row with stale hash\n'
rm -f "$ROOT/updated"
touch "$ROOT/row"
bash "$SCRIPT"
test -f "$ROOT/updated"
printf 'PASS: stale hash updated only while unconsumed.\n\n'

printf 'TEST 3 — active Owner safety guard\n'
rm -f "$ROOT/updated" "$ROOT/row" "$ROOT/consumed"
touch "$ROOT/owner"
set +e
OUT="$(bash "$SCRIPT" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 && "$OUT" == *"Owner aktif sudah ada"* ]]
[[ ! -f "$ROOT/updated" ]]
printf 'PASS: active Owner blocks repair; no DB write.\n\n'

printf 'TEST 4 — consumed bootstrap safety guard\n'
rm -f "$ROOT/owner" "$ROOT/updated" "$ROOT/row"
touch "$ROOT/consumed"
set +e
OUT="$(bash "$SCRIPT" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 && "$OUT" == *"bootstrap sudah pernah dikonsumsi"* ]]
[[ ! -f "$ROOT/updated" ]]
printf 'PASS: consumed bootstrap blocks repair; no DB write.\n'


printf 'TEST 5 — non-superuser TCP connection safety guard\n'
rm -f "$ROOT/updated" "$ROOT/row" "$ROOT/owner" "$ROOT/consumed"
export MOCK_ADMIN_SUPERUSER=f
set +e
OUT="$(bash "$SCRIPT" 2>&1)"
RC=$?
set -e
[[ "$RC" -ne 0 && "$OUT" == *"akun PostgreSQL lokal bukan superuser"* ]]
[[ ! -f "$ROOT/updated" ]]
export MOCK_ADMIN_SUPERUSER=t
printf 'PASS: non-superuser blocked before any database write.\n'
