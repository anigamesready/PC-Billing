#!/data/data/com.termux/files/usr/bin/bash
# ANI GAMES READY — safe Owner-bootstrap alignment repair for DB Android staging.
# Never resets schema/data, changes passwords, or touches port 8787 / Supabase / WoL.
set -euo pipefail

STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
SERVER_DIR="$STAGE_HOME/server"
ENV_FILE="$SERVER_DIR/.env"
PID_FILE="$STAGE_HOME/stage-api.pid"
DB_NAME="ani_games_ready_stage"
API_URL="http://127.0.0.1:8788"

fail() {
  printf '[ANI BOOTSTRAP FIX] STOP: %s\n' "$1" >&2
  exit "${2:-1}"
}

read_env_value() {
  local key="$1"
  sed -n "s/^${key}=//p" "$ENV_FILE" | head -n 1 | tr -d '\r'
}

[[ -d "$STAGE_HOME" && ! -L "$STAGE_HOME" ]] || fail "folder staging tidak ditemukan atau bukan folder biasa: $STAGE_HOME"
[[ -f "$ENV_FILE" && ! -L "$ENV_FILE" ]] || fail "file .env staging tidak ditemukan atau bukan file biasa."
[[ -f "$PID_FILE" ]] || fail "PID API staging tidak ditemukan. Jalankan start-stage.sh terlebih dahulu."
command -v psql >/dev/null 2>&1 || fail "psql belum tersedia di Termux."
command -v curl >/dev/null 2>&1 || fail "curl belum tersedia di Termux."
command -v sha256sum >/dev/null 2>&1 || fail "sha256sum belum tersedia di Termux."

# Read only the generated KEY=value entries; do not execute the .env as shell code.
ANI_BIND="$(read_env_value ANI_BIND)"
PORT="$(read_env_value PORT)"
DATABASE_URL="$(read_env_value DATABASE_URL)"
BOOTSTRAP_TOKEN="$(read_env_value ANI_ADMIN_BOOTSTRAP_TOKEN)"

[[ "$ANI_BIND" == "127.0.0.1" && "$PORT" == "8788" ]] || fail "konfigurasi API bukan staging loopback 127.0.0.1:8788. Tidak ada perubahan dibuat."
[[ "$DATABASE_URL" == postgresql://ani_api_stage_login:*@127.0.0.1:5432/ani_games_ready_stage* ]] || fail "DATABASE_URL tidak menunjuk database staging lokal yang diharapkan. Tidak ada perubahan dibuat."
[[ "$BOOTSTRAP_TOKEN" =~ ^[0-9a-f]{64}$ ]] || fail "token bootstrap lokal tidak valid atau tidak ditemukan. Tidak ada perubahan dibuat."
chmod 600 "$ENV_FILE"

PID="$(cat "$PID_FILE" 2>/dev/null || true)"
[[ "$PID" =~ ^[0-9]+$ ]] || fail "PID staging tidak valid."
kill -0 "$PID" 2>/dev/null || fail "proses API staging tidak aktif. Jalankan start-stage.sh terlebih dahulu."
CWD="$(readlink "/proc/$PID/cwd" 2>/dev/null || true)"
CMD="$(tr '\0' ' ' <"/proc/$PID/cmdline" 2>/dev/null || true)"
[[ "$CWD" == "$SERVER_DIR" && "$CMD" == *server.mjs* ]] || fail "PID tidak cocok dengan server staging. Tidak akan menghentikan proses lain."

HEALTH="$(curl -fsS --max-time 8 "$API_URL/health")" || fail "health API staging gagal."
[[ "$HEALTH" == *'"api":"online"'* && "$HEALTH" == *'"database":"online"'* && "$HEALTH" == *'"bind_host":"127.0.0.1"'* ]] || fail "health bukan API staging lokal yang sehat."

TOKEN_HASH="$(printf '%s' "$BOOTSTRAP_TOKEN" | sha256sum | awk '{print $1}')"

read_db_state() {
  psql -X -q -t -A -v ON_ERROR_STOP=1 -v "token_hash=$TOKEN_HASH" -d "$DB_NAME" <<'SQL'
SELECT
  CASE WHEN EXISTS (
    SELECT 1 FROM public.admin_accounts
    WHERE role='SUPER_ADMIN' AND status='active'
  ) THEN 't' ELSE 'f' END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1 FROM private.admin_bootstrap_control WHERE singleton=true
  ) THEN 't' ELSE 'f' END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1 FROM private.admin_bootstrap_control
    WHERE singleton=true AND consumed_at IS NOT NULL
  ) THEN 't' ELSE 'f' END || '|' ||
  CASE WHEN EXISTS (
    SELECT 1 FROM private.admin_bootstrap_control
    WHERE singleton=true AND consumed_at IS NULL AND token_hash=:'token_hash'
  ) THEN 't' ELSE 'f' END;
SQL
}

STATE="$(read_db_state)" || fail "gagal membaca status kontrol bootstrap dari database staging. Tidak ada perubahan dibuat."
IFS='|' read -r OWNER_ACTIVE ROW_EXISTS CONSUMED TOKEN_MATCH <<<"$STATE"
[[ "$OWNER_ACTIVE" == "f" ]] || fail "Owner aktif sudah ada. Bootstrap tidak boleh diulang; coba login ke Admin APK."
[[ "$CONSUMED" == "f" ]] || fail "bootstrap sudah pernah dikonsumsi. Demi keamanan, token tidak di-reset. Perlu audit manual sebelum tindakan lanjutan."

# If the running Node process has a stale/missing token environment, restart only API 8788.
# PostgreSQL, the legacy API on 8787, and the separate WSS/Blynk/WoL relay are not stopped.
LIVE_TOKEN="$(tr '\0' '\n' <"/proc/$PID/environ" 2>/dev/null | sed -n 's/^ANI_ADMIN_BOOTSTRAP_TOKEN=//p' | head -n 1 || true)"
if [[ "$LIVE_TOKEN" != "$BOOTSTRAP_TOKEN" ]]; then
  unset LIVE_TOKEN
  printf '[ANI BOOTSTRAP FIX] Environment proses API berbeda dari .env; restart API staging saja...\n'
  bash "$STAGE_HOME/stop-stage.sh" || fail "API staging tidak dapat dihentikan dengan aman. Database belum diubah."
  bash "$STAGE_HOME/start-stage.sh" || fail "API staging gagal start ulang. PostgreSQL dan port 8787 tetap tidak disentuh."
  PID="$(cat "$PID_FILE" 2>/dev/null || true)"
  [[ "$PID" =~ ^[0-9]+$ ]] || fail "PID API setelah restart tidak valid."
  HEALTH="$(curl -fsS --max-time 8 "$API_URL/health")" || fail "health API gagal setelah restart."
  [[ "$HEALTH" == *'"api":"online"'* && "$HEALTH" == *'"database":"online"'* && "$HEALTH" == *'"bind_host":"127.0.0.1"'* ]] || fail "API setelah restart tidak sesuai staging lokal."
fi

if [[ "$TOKEN_MATCH" != "t" || "$ROW_EXISTS" != "t" ]]; then
  printf '[ANI BOOTSTRAP FIX] Menyelaraskan hash token bootstrap lokal (tanpa mengubah token atau data akun)...\n'
  psql -X -v ON_ERROR_STOP=1 -v "token_hash=$TOKEN_HASH" -d "$DB_NAME" <<'SQL'
BEGIN;
DO $guard$
BEGIN
  IF EXISTS (
    SELECT 1 FROM public.admin_accounts
    WHERE role='SUPER_ADMIN' AND status='active'
  ) THEN
    RAISE EXCEPTION 'ADMIN_BOOTSTRAP_ALREADY_CONFIGURED';
  END IF;
END
$guard$;
INSERT INTO private.admin_bootstrap_control(singleton, token_hash)
VALUES (true, :'token_hash')
ON CONFLICT (singleton) DO UPDATE
SET token_hash = EXCLUDED.token_hash
WHERE private.admin_bootstrap_control.consumed_at IS NULL;
COMMIT;
SQL
fi

STATE="$(read_db_state)" || fail "gagal memverifikasi status bootstrap setelah perbaikan."
IFS='|' read -r OWNER_ACTIVE ROW_EXISTS CONSUMED TOKEN_MATCH <<<"$STATE"
[[ "$OWNER_ACTIVE" == "f" && "$ROW_EXISTS" == "t" && "$CONSUMED" == "f" && "$TOKEN_MATCH" == "t" ]] || fail "status kontrol tidak aman setelah pemeriksaan; tidak akan mencoba membuat Owner."

# Intentionally invalid values: the DB routine checks the secret gate before input validation.
# Expected ADMIN_BOOTSTRAP_INPUT_INVALID proves local POST + token check pass, without creating an account.
PROBE="$(curl -sS --max-time 10 -X POST "$API_URL/api/admin/bootstrap" \
  -H 'content-type: application/json' \
  --data '{"username":"x","password":"x","org_name":"x"}' \
  -w $'\n%{http_code}')" || fail "POST probe gagal terhubung ke API staging."
HTTP_CODE="${PROBE##*$'\n'}"
BODY="${PROBE%$'\n'*}"
if [[ "$HTTP_CODE" != "400" || "$BODY" != *'ADMIN_BOOTSTRAP_INPUT_INVALID'* ]]; then
  printf '[ANI BOOTSTRAP FIX] Probe belum lolos: HTTP %s; respons %s\n' "$HTTP_CODE" "$BODY" >&2
  printf '[ANI BOOTSTRAP FIX] Tidak ada akun dibuat. Periksa alamat localhost / log API; jangan jalankan installer ulang.\n' >&2
  exit 4
fi

printf '\n[ANI BOOTSTRAP FIX] BERHASIL — token lokal dan kontrol database sudah cocok.\n'
printf '[ANI BOOTSTRAP FIX] Probe POST aman lolos; input sengaja tidak valid sehingga TIDAK membuat akun.\n'
printf '[ANI BOOTSTRAP FIX] Buka Chrome di Redmi: %s/setup\n' "$API_URL"
printf '[ANI BOOTSTRAP FIX] Buat Owner menggunakan username dan password milikmu (password minimal 12 karakter).\n'
printf '[ANI BOOTSTRAP FIX] Setelah sukses, login Admin APK dengan username/password yang sama.\n'
printf '[ANI BOOTSTRAP FIX] PostgreSQL, port 8787, Supabase DB1/DB2 dan relay Blynk/WoL tidak diubah.\n'
