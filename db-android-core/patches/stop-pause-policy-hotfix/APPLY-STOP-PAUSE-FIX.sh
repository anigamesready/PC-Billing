#!/data/data/com.termux/files/usr/bin/bash
# Safe one-time hotfix for the isolated DB Android stage API on port 8788.
# Does not touch the main API/database on port 8787 or the WoL/WebSocket relay.
set -Eeuo pipefail
umask 077

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE_HOME="\${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
DB_NAME="\${ANI_DB_STAGE_NAME:-ani_games_ready_stage}"
API_PORT="\${ANI_DB_STAGE_PORT:-8788}"
SERVER="$STAGE_HOME/server"
SERVER_MJS="$SERVER/server.mjs"
ENV_FILE="$SERVER/.env"
PID_FILE="$STAGE_HOME/stage-api.pid"
STOP_SCRIPT="$STAGE_HOME/stop-stage.sh"
START_SCRIPT="$STAGE_HOME/start-stage.sh"
SQL_FILE="$HERE/sql/012_billing_stop_pause_policy.sql"
PATCHER="$HERE/apply_stop_pause_policy_api_fix.py"

fail() { echo "[ANI STOP/PAUSE FIX] STOP: $*" >&2; exit 1; }

echo "[ANI STOP/PAUSE FIX] Audit awal DB Android stage."
[ "$DB_NAME" = "ani_games_ready_stage" ] || fail "Nama DB bukan ani_games_ready_stage; tidak ada perubahan."
[ "$API_PORT" = "8788" ] || fail "Port bukan 8788; API utama 8787 tidak disentuh."
[ -d "$SERVER" ] && [ -f "$SERVER_MJS" ] || fail "Server stage tidak ditemukan."
[ -f "$ENV_FILE" ] && [ -f "$PID_FILE" ] || fail ".env/PID stage tidak ditemukan."
[ -f "$STOP_SCRIPT" ] && [ -f "$START_SCRIPT" ] || fail "Kontrol start/stop stage tidak ditemukan."
[ -f "$SQL_FILE" ] && [ -f "$PATCHER" ] || fail "File patch/migrasi di paket tidak lengkap."

for cmd in node python3 psql pg_dump pg_restore curl; do
  command -v "$cmd" >/dev/null 2>&1 || fail "Perintah $cmd belum tersedia."
done
node -e "if(Number(process.versions.node.split('.')[0])<20)process.exit(1)" || fail "Node.js minimal versi 20 diperlukan."
python3 -m py_compile "$PATCHER" || fail "Patch Python gagal syntax check."

PID="$(cat "$PID_FILE" 2>/dev/null || true)"
[ -n "$PID" ] && kill -0 "$PID" 2>/dev/null || fail "API stage tidak sedang berjalan."
CWD="$(readlink "/proc/$PID/cwd" 2>/dev/null || true)"
CMD="$(tr '\0' ' ' <"/proc/$PID/cmdline" 2>/dev/null || true)"
[ "$CWD" = "$SERVER" ] || fail "PID bukan proses pada folder server stage."
printf '%s' "$CMD" | grep -q 'server.mjs' || fail "PID bukan server.mjs stage."

HEALTH="$(curl -fsS --max-time 5 "http://127.0.0.1:$API_PORT/health")" || fail "Health API stage gagal."
printf '%s' "$HEALTH" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{let h=JSON.parse(s);if(h.api!=="online"||h.database!=="online")process.exit(2)}catch{process.exit(2)}})' || fail "API/database stage belum ONLINE."
DB_EXISTS="$(psql -X -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='ani_games_ready_stage'")" || fail "Tidak bisa memeriksa PostgreSQL."
[ "$DB_EXISTS" = "1" ] || fail "Database ani_games_ready_stage tidak ditemukan."

PREREQ="$(psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -Atqc "
SELECT CASE WHEN
 to_regclass('private.admin_feature_settings') IS NOT NULL
 AND to_regclass('public.org_members') IS NOT NULL
 AND to_regclass('public.audit_logs') IS NOT NULL
 AND to_regclass('public.device_tokens') IS NOT NULL
 AND to_regprocedure('private.set_admin_actor(text)') IS NOT NULL
 AND EXISTS (SELECT 1 FROM information_schema.columns
   WHERE table_schema='private' AND table_name='admin_feature_settings' AND column_name='updated_by')
 AND EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime')
THEN 1 ELSE 0 END;
")" || fail "Preflight skema gagal."
[ "$PREREQ" = "1" ] || fail "Prasyarat skema 002-011 tidak lengkap. Migrasi tidak dijalankan."

CHECK_CONSTRAINTS="$(psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -Atqc "
SELECT count(*) FROM pg_constraint
WHERE conrelid=to_regclass('private.admin_feature_settings')
 AND contype='c' AND pg_get_constraintdef(oid) ILIKE '%feature_key%';
")" || fail "Pemeriksaan constraint gagal."
[ "$CHECK_CONSTRAINTS" = "0" ] || fail "Ada CHECK feature_key yang harus diaudit dulu. Tidak ada perubahan."

MIGRATION_READY="$(psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -Atqc "
SELECT CASE WHEN
 to_regprocedure('api.admin_get_billing_stop_pause_policy(text)') IS NOT NULL
 AND to_regprocedure('api.admin_set_billing_stop_pause_policy(text,boolean)') IS NOT NULL
 AND to_regprocedure('api.device_session_control_policy(text)') IS NOT NULL
 AND EXISTS (SELECT 1 FROM private.admin_feature_settings WHERE feature_key='billing_stop_pause_enabled')
THEN 1 ELSE 0 END;
")" || fail "Pemeriksaan status migrasi gagal."

mkdir -p "$STAGE_HOME/backups"
chmod 700 "$STAGE_HOME/backups"
STAMP="$(date -u +%Y%m%dT%H%M%SZ)"
DB_BACKUP="$STAGE_HOME/backups/ani_games_ready_stage_before_stop_pause_$STAMP.dump"
SERVER_BACKUP="$SERVER/server.mjs.before_stop_pause_$STAMP.bak"

echo "[ANI STOP/PAUSE FIX] Membuat backup DB staging."
pg_dump --format=custom --no-owner --no-acl --file "$DB_BACKUP" "$DB_NAME" || fail "Backup DB gagal; tidak ada perubahan."
[ -s "$DB_BACKUP" ] || fail "Backup DB kosong."
pg_restore --list "$DB_BACKUP" >/dev/null || fail "Backup DB tidak valid."
cp -p "$SERVER_MJS" "$SERVER_BACKUP"
[ -s "$SERVER_BACKUP" ] || fail "Backup server.mjs gagal."

MIGRATION_APPLIED=0
if [ "$MIGRATION_READY" = "1" ]; then
 echo "[ANI STOP/PAUSE FIX] Migrasi 012 sudah terpasang."
else
 echo "[ANI STOP/PAUSE FIX] Terapkan migrasi 012 (default izin OFF)."
 psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -f "$SQL_FILE" || fail "Migrasi 012 gagal; transaksi SQL dibatalkan."
 MIGRATION_APPLIED=1
fi

PATCH_OUTPUT="$(python3 "$PATCHER" "$SERVER_MJS")" || {
 echo "$PATCH_OUTPUT" 2>/dev/null || true
 fail "Patch server.mjs gagal. API belum direstart; backup tersedia."
}
echo "$PATCH_OUTPUT"
node --check "$SERVER_MJS" || {
 cp -p "$SERVER_BACKUP" "$SERVER_MJS"
 fail "Node syntax check gagal; server.mjs dipulihkan."
}

API_PATCHED=0
case "$PATCH_OUTPUT" in
 PATCHED:*) API_PATCHED=1 ;;
 ALREADY_OK:*) API_PATCHED=0 ;;
 *) cp -p "$SERVER_BACKUP" "$SERVER_MJS"; fail "Status patch tidak dikenal." ;;
esac

rollback_api() {
 echo "[ANI STOP/PAUSE FIX] Rollback server API dari backup."
 cp -p "$SERVER_BACKUP" "$SERVER_MJS"
 node --check "$SERVER_MJS" || true
 bash "$STOP_SCRIPT" || true
 bash "$START_SCRIPT" || true
}

if [ "$API_PATCHED" = "1" ]; then
 echo "[ANI STOP/PAUSE FIX] Restart API stage 8788 saja."
 if ! bash "$STOP_SCRIPT"; then
   cp -p "$SERVER_BACKUP" "$SERVER_MJS"
   fail "Stop API stage ditolak oleh pemeriksaan PID; source dipulihkan."
 fi
 if ! bash "$START_SCRIPT"; then
   rollback_api
   fail "API gagal start; source lama dipulihkan. Periksa log stage."
 fi
fi

HEALTH_AFTER="$(curl -fsS --max-time 8 "http://127.0.0.1:$API_PORT/health")" || {
 rollback_api
 fail "Health check pascarestart gagal; source lama dipulihkan."
}
printf '%s' "$HEALTH_AFTER" | node -e 'let s="";process.stdin.on("data",d=>s+=d).on("end",()=>{try{let h=JSON.parse(s);if(h.api!=="online"||h.database!=="online")process.exit(2)}catch{process.exit(2)}})' || {
 rollback_api
 fail "API/database tidak ONLINE setelah restart; source lama dipulihkan."
}

probe_rpc() {
 local rpc_name="$1" response_file code
 response_file="$(mktemp)"
 code="$(curl -sS --max-time 8 -o "$response_file" -w '%{http_code}' \
   -X POST -H 'content-type: application/json' -H 'accept: application/json' \
   --data '{}' "http://127.0.0.1:$API_PORT/rest/v1/rpc/$rpc_name")" || { rm -f "$response_file"; return 1; }
 if [ "$code" != "401" ] || ! grep -q 'AUTH_REQUIRED' "$response_file"; then
   echo "[ANI STOP/PAUSE FIX] Probe $rpc_name gagal: HTTP $code"
   cat "$response_file"
   rm -f "$response_file"
   return 1
 fi
 rm -f "$response_file"
 echo "[ANI STOP/PAUSE FIX] PASS $rpc_name: route dikenali, token tetap wajib."
}

if ! probe_rpc "admin_get_billing_stop_pause_policy" || ! probe_rpc "admin_set_billing_stop_pause_policy"; then
 rollback_api
 fail "Smoke test gagal; server.mjs lama dipulihkan. Migrasi 012 tetap additive dan default izin OFF."
fi

echo
echo "[ANI STOP/PAUSE FIX] SELESAI."
echo "[ANI STOP/PAUSE FIX] API stage port 8788 ONLINE; GET/SET RPC dikenal dan tetap wajib token."
echo "[ANI STOP/PAUSE FIX] Migrasi 012: $([ "$MIGRATION_APPLIED" = "1" ] && echo "diterapkan" || echo "sudah terpasang")."
echo "[ANI STOP/PAUSE FIX] Backup database: $DB_BACKUP"
echo "[ANI STOP/PAUSE FIX] Backup server: $SERVER_BACKUP"
echo "[ANI STOP/PAUSE FIX] Default izin tenant tetap OFF. Master/Owner yang mengaktifkannya dari Admin."
echo "[ANI STOP/PAUSE FIX] Port 8787, data rental/session, pairing, Remote Play, relay WoL tidak diubah."
