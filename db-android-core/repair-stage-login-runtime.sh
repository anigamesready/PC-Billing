#!/data/data/com.termux/files/usr/bin/bash
# Safe, isolated repair for the Remote Play staging API login path.
# Does not reset/drop DB, change passwords, alter production API 8787, or stop PostgreSQL.
set -euo pipefail

STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
ENV_FILE="$STAGE_HOME/server/.env"
SERVER_FILE="$STAGE_HOME/server/server.mjs"
DB_NAME="ani_games_ready_stage"
LOGIN_ROLE="ani_api_stage_login"
RUNTIME_ROLE="ani_api_runtime"
PATCHER_REF="808404a66fab30b63aaea078077bcea5b4ae108b"
PATCH_URL="https://raw.githubusercontent.com/anigamesready/PC-Billing/$PATCHER_REF/db-android-core/cloudflare-gateway-stage/patch_server_edge_proxy.py"

say() { printf '[ANI REPAIR] %s\n' "$*"; }
fail() { say "STOP: $*"; exit 1; }

say "Audit staging saja; API utama 8787, PostgreSQL, database produksi, Worker dan secret tidak direset."
[ -s "$ENV_FILE" ] || fail "File .env staging tidak ditemukan: $ENV_FILE"
[ -s "$SERVER_FILE" ] || fail "Source API staging tidak ditemukan: $SERVER_FILE"
[ -f "$STAGE_HOME/stop-stage.sh" ] || fail "File stop-stage.sh staging tidak ditemukan."
[ -f "$STAGE_HOME/start-stage.sh" ] || fail "File start-stage.sh staging tidak ditemukan."

python3 - "$ENV_FILE" "$DB_NAME" "$LOGIN_ROLE" <<'PY'
import sys
from urllib.parse import urlsplit, unquote
p, expected_db, expected_user = sys.argv[1:]
values = {}
for raw in open(p, encoding="utf-8"):
    line = raw.strip()
    if not line or line.startswith("#") or "=" not in line:
        continue
    k, v = line.split("=", 1)
    values[k.strip()] = v.strip().strip("'").strip('"')
url = values.get("DATABASE_URL", "")
u = urlsplit(url)
db = unquote(u.path.lstrip("/").split("?", 1)[0])
user = unquote(u.username or "")
if values.get("PORT") != "8788":
    raise SystemExit("STOP: PORT staging bukan 8788.")
if values.get("ANI_BIND") != "127.0.0.1":
    raise SystemExit("STOP: ANI_BIND staging bukan 127.0.0.1.")
if db != expected_db or user != expected_user:
    raise SystemExit("STOP: DATABASE_URL tidak menunjuk role/database staging yang diharapkan.")
print("PASS: .env hanya menunjuk API 127.0.0.1:8788 dan DB ani_games_ready_stage.")
PY

command -v psql >/dev/null 2>&1 || fail "psql tidak tersedia di Termux."
command -v pg_isready >/dev/null 2>&1 || fail "pg_isready tidak tersedia di Termux."
command -v python3 >/dev/null 2>&1 || fail "python3 tidak tersedia di Termux."
command -v node >/dev/null 2>&1 || fail "Node.js tidak tersedia di Termux."
command -v curl >/dev/null 2>&1 || fail "curl tidak tersedia di Termux."

pg_isready -h 127.0.0.1 -p 5432 -d "$DB_NAME" >/dev/null 2>&1 || fail "PostgreSQL staging tidak siap; tidak ada perubahan dilakukan."

# Match the running server with the installed Termux PostgreSQL binaries.
command -v postgres >/dev/null 2>&1 || fail "Binary postgres tidak tersedia."
command -v pg_ctl >/dev/null 2>&1 || fail "pg_ctl tidak tersedia."
BIN_VERSION="$(postgres --version | sed -E 's/.*PostgreSQL\) ([0-9]+\.[0-9]+).*/\1/')"
PGCTL_VERSION="$(pg_ctl --version | sed -E 's/.* ([0-9]+\.[0-9]+)$/\1/')"
SERVER_VERSION="$(psql -X -h 127.0.0.1 -p 5432 -d "$DB_NAME" -Atqc 'SHOW server_version' | cut -d. -f1-2)"
[ -n "$BIN_VERSION" ] && [ -n "$PGCTL_VERSION" ] && [ -n "$SERVER_VERSION" ] || fail "Tidak bisa membaca versi PostgreSQL."
[ "$BIN_VERSION" = "$PGCTL_VERSION" ] || fail "Binary postgres dan pg_ctl berbeda versi; tidak restart otomatis."
if [ "$SERVER_VERSION" != "$BIN_VERSION" ]; then
  say "Versi server $SERVER_VERSION berbeda dari binary/library terpasang $BIN_VERSION."
  DATA_DIR="$(psql -X -h 127.0.0.1 -p 5432 -d "$DB_NAME" -Atqc 'SHOW data_directory')"
  [ -n "$DATA_DIR" ] && [ -d "$DATA_DIR" ] || fail "data_directory PostgreSQL tidak ditemukan."
  case "$DATA_DIR" in
    "$PREFIX"/*) ;;
    *) fail "data_directory berada di luar PREFIX Termux; restart otomatis dibatalkan." ;;
  esac
  [ -s "$DATA_DIR/PG_VERSION" ] || fail "PG_VERSION tidak ditemukan; cluster tidak disentuh."
  DATA_MAJOR="$(cut -d. -f1 "$DATA_DIR/PG_VERSION")"
  BIN_MAJOR="$(printf '%s' "$BIN_VERSION" | cut -d. -f1)"
  [ "$DATA_MAJOR" = "$BIN_MAJOR" ] || fail "Major version data directory dan binary berbeda; tidak menjalankan upgrade otomatis."
  say "Restart normal cluster yang sama memakai pg_ctl $PGCTL_VERSION (tanpa initdb/pg_upgrade)..."
  pg_ctl -D "$DATA_DIR" -m fast -w -t 60 restart || fail "Restart PostgreSQL gagal. Jangan jalankan perintah reset/reinstall."
  pg_isready -h 127.0.0.1 -p 5432 -d "$DB_NAME" >/dev/null 2>&1 || fail "PostgreSQL belum siap setelah restart."
  SERVER_VERSION="$(psql -X -h 127.0.0.1 -p 5432 -d "$DB_NAME" -Atqc 'SHOW server_version' | cut -d. -f1-2)"
  [ "$SERVER_VERSION" = "$BIN_VERSION" ] || fail "Versi server masih tidak cocok sesudah restart."
  say "PASS: server kini berjalan dengan binary/library $SERVER_VERSION."
else
  say "PASS: server dan binary PostgreSQL sama-sama $SERVER_VERSION."
fi
say "Menguji PL/pgSQL tanpa mengubah data..."
psql -X -h 127.0.0.1 -p 5432 -d "$DB_NAME" -v ON_ERROR_STOP=1 -c 'DO $ BEGIN NULL; END $;' >/dev/null \
  || fail "PL/pgSQL masih gagal dimuat; grant dan API belum diubah."
say "PASS: PL/pgSQL berhasil dimuat."


say "Memeriksa fungsi login dan memperbaiki hanya grant runtime yang semestinya..."
psql -X -h 127.0.0.1 -p 5432 -d "$DB_NAME" -v ON_ERROR_STOP=1 <<'SQL'
BEGIN;
DO $check$
DECLARE
  v_super boolean;
BEGIN
  SELECT rolsuper INTO v_super FROM pg_roles WHERE rolname = current_user;
  IF coalesce(v_super,false) IS NOT TRUE THEN
    RAISE EXCEPTION 'STAGE_REPAIR_NEEDS_LOCAL_DB_ADMIN';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_runtime' AND rolcanlogin=false) THEN
    RAISE EXCEPTION 'STAGE_RUNTIME_ROLE_MISSING_OR_LOGIN_ENABLED';
  END IF;
  IF NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_stage_login' AND rolcanlogin=true AND rolsuper=false) THEN
    RAISE EXCEPTION 'STAGE_LOGIN_ROLE_MISSING_OR_UNSAFE';
  END IF;
  IF to_regprocedure('api.admin_login(text,text)') IS NULL
     OR to_regprocedure('api.admin_login_rate_limit_consume(text)') IS NULL
     OR to_regprocedure('api.admin_login_rate_limit_clear(text[])') IS NULL
     OR to_regprocedure('api.admin_get_user(text)') IS NULL
     OR to_regprocedure('api.admin_refresh_session(text)') IS NULL
     OR to_regprocedure('api.admin_logout(text)') IS NULL THEN
    RAISE EXCEPTION 'STAGE_ADMIN_LOGIN_SCHEMA_INCOMPLETE';
  END IF;
END;
$check$;

GRANT USAGE ON SCHEMA api TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login(text,text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_consume(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_login_rate_limit_clear(text[]) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_get_user(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_refresh_session(text) TO ani_api_runtime;
GRANT EXECUTE ON FUNCTION api.admin_logout(text) TO ani_api_runtime;
GRANT ani_api_runtime TO ani_api_stage_login;
ALTER ROLE ani_api_stage_login INHERIT;

DO $verify$
BEGIN
  IF NOT pg_has_role('ani_api_stage_login','ani_api_runtime','MEMBER') THEN
    RAISE EXCEPTION 'STAGE_RUNTIME_MEMBERSHIP_NOT_ACTIVE';
  END IF;
  IF NOT has_function_privilege('ani_api_stage_login','api.admin_login(text,text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_stage_login','api.admin_login_rate_limit_consume(text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_stage_login','api.admin_login_rate_limit_clear(text[])','EXECUTE')
     OR NOT has_function_privilege('ani_api_stage_login','api.admin_get_user(text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_stage_login','api.admin_refresh_session(text)','EXECUTE')
     OR NOT has_function_privilege('ani_api_stage_login','api.admin_logout(text)','EXECUTE') THEN
    RAISE EXCEPTION 'STAGE_ADMIN_LOGIN_GRANTS_NOT_READY';
  END IF;
END;
$verify$;
COMMIT;
SQL
say "PASS: hak akses login staging terverifikasi. Tidak ada hak akses tabel langsung yang ditambahkan."

TMP_DIR="$(mktemp -d)"
trap 'rm -rf "$TMP_DIR"' EXIT
say "Memasang patch diagnostik SQLSTATE yang tidak membocorkan query, password atau token..."
curl -fsSL "$PATCH_URL" -o "$TMP_DIR/patch_server_edge_proxy.py"
python3 -m py_compile "$TMP_DIR/patch_server_edge_proxy.py"
python3 "$TMP_DIR/patch_server_edge_proxy.py" "$STAGE_HOME/server"
node --check "$SERVER_FILE"
grep -q "ANI-DB-ANDROID-REQUEST-SQLSTATE-DIAGNOSTIC-V1" "$SERVER_FILE" || fail "Patch diagnostik SQLSTATE belum terpasang."
grep -q 'sqlstate:' "$SERVER_FILE" || fail "Field SQLSTATE aman tidak ditemukan."

say "Restart hanya API staging port 8788 memakai PID guard bawaan..."
bash "$STAGE_HOME/stop-stage.sh"
bash "$STAGE_HOME/start-stage.sh"

say "Memeriksa health lokal staging..."
LOCAL_HEALTH="$(curl -fsS --max-time 10 http://127.0.0.1:8788/health)" || fail "Health lokal staging gagal setelah restart."
printf '%s\n' "$LOCAL_HEALTH" | python3 -c 'import json,sys; d=json.load(sys.stdin); assert d.get("api")=="online" and d.get("database")=="online"; print("PASS: API dan database staging ONLINE.")'

GATEWAY_URL="$(python3 - "$ENV_FILE" <<'PY'
import sys
for raw in open(sys.argv[1], encoding="utf-8"):
    line=raw.strip()
    if line.startswith("ANI_EDGE_GATEWAY_URL="):
        print(line.split("=",1)[1].strip().strip("'").strip('"').rstrip("/"))
        break
PY
)"
if [ -n "$GATEWAY_URL" ]; then
  say "Menguji jalur HTTPS gateway publik..."
  if PUBLIC_HEALTH="$(curl -fsS --max-time 20 "$GATEWAY_URL/health" 2>/dev/null)"; then
    printf '%s\n' "$PUBLIC_HEALTH" | python3 -c 'import json,sys; d=json.load(sys.stdin); print("Gateway:", "ONLINE" if d.get("api")=="online" and d.get("database")=="online" else "RESPON TIDAK SEHAT", "| API:",d.get("api"),"| DB:",d.get("database"))'
  else
    say "PERINGATAN: gateway HTTPS belum merespons; API lokal tetap sehat."
  fi
else
  say "ANI_EDGE_GATEWAY_URL belum ada di .env; gateway tidak diubah."
fi

RELAY_URL="$(python3 - "$ENV_FILE" <<'PY'
import sys
for raw in open(sys.argv[1], encoding="utf-8"):
    line=raw.strip()
    if line.startswith("ANI_DB_RELAY_URL="):
        print(line.split("=",1)[1].strip().strip("'").strip('"').rstrip("/"))
        break
PY
)"
if [ -n "$RELAY_URL" ]; then
  say "Menguji WebSocket Relay terpisah..."
  if RELAY_HEALTH="$(curl -sS --max-time 12 -w '\nHTTP_STATUS=%{http_code}' "$RELAY_URL/_relay/health" 2>/dev/null)"; then
    printf '%s\n' "$RELAY_HEALTH" | tail -n 2
  else
    say "Relay masih belum memberi respons; proses Agent tidak dihentikan atau dihapus."
  fi
fi

say "Selesai. Backup source dibuat otomatis oleh patcher bila ada perubahan."
say "API utama 8787, PostgreSQL, data staging, Worker bindings, dan secret tidak direset."
say "Bila login masih gagal, API kini mengembalikan kode SQLSTATE aman seperti DATABASE_PERMISSION_DENIED atau API_FUNCTION_MISSING, bukan REQUEST_FAILED generik."
