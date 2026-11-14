#!/data/data/com.termux/files/usr/bin/bash
# ANI GAMES READY — isolated DB Android staging installer for Termux.
# Creates a NEW database/role/service on port 8788. Never replaces the existing port 8787 API.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
STAGE_HOME="${ANI_DB_STAGE_HOME:-$HOME/ani-games-db-android-stage}"
DB_NAME="${ANI_DB_STAGE_NAME:-ani_games_ready_stage}"
API_PORT="${ANI_DB_STAGE_PORT:-8788}"
ROLE_NAME="ani_api_stage_login"

case "$DB_NAME" in
  ani_games_ready_stage) ;;
  *) echo "[ANI STAGE] STOP: nama database staging harus ani_games_ready_stage."; exit 2 ;;
esac
case "$API_PORT" in
  8788) ;;
  *) echo "[ANI STAGE] STOP: port staging harus 8788."; exit 2 ;;
esac
if [ -e "$STAGE_HOME" ]; then
  echo "[ANI STAGE] STOP: folder $STAGE_HOME sudah ada."
  echo "[ANI STAGE] Tidak menimpa folder staging yang mungkin berisi data."
  exit 2
fi

for cmd in node npm psql createdb pg_isready openssl sha256sum curl nohup; do
  command -v "$cmd" >/dev/null 2>&1 || { echo "[ANI STAGE] Perintah belum tersedia: $cmd"; exit 1; }
done
node -e "const major=Number(process.versions.node.split('.')[0]);if(major<20)process.exit(1)" || {
  echo "[ANI STAGE] Node.js minimal versi 20 diperlukan."; exit 1;
}
pg_isready -q || { echo "[ANI STAGE] PostgreSQL belum online. Tidak ada perubahan dibuat."; exit 1; }

DB_EXISTS="$(psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'")"
ROLE_EXISTS="$(psql -d postgres -Atqc "SELECT 1 FROM pg_roles WHERE rolname='$ROLE_NAME'")"
if [ "$DB_EXISTS" = "1" ] || [ "$ROLE_EXISTS" = "1" ]; then
  echo "[ANI STAGE] STOP: database atau role staging sudah ada."
  echo "[ANI STAGE] Tidak mengubah database/role yang sudah ada."
  exit 2
fi
if curl -fsS "http://127.0.0.1:$API_PORT/health" >/dev/null 2>&1; then
  echo "[ANI STAGE] STOP: port $API_PORT sudah dipakai layanan lain."
  exit 2
fi

mkdir -p "$STAGE_HOME"
cp -R "$HERE/schema" "$STAGE_HOME/schema"
cp -R "$HERE/server" "$STAGE_HOME/server"
cp "$HERE/README-STAGE-ID.txt" "$STAGE_HOME/README-STAGE-ID.txt"
cp "$HERE/setup-stage.sh" "$STAGE_HOME/setup-stage.sh"
cp "$HERE/start-stage.sh" "$STAGE_HOME/start-stage.sh"
cp "$HERE/status-stage.sh" "$STAGE_HOME/status-stage.sh"
cp "$HERE/stop-stage.sh" "$STAGE_HOME/stop-stage.sh"
chmod 700 "$STAGE_HOME"
export ANI_DB_NAME="$DB_NAME"
bash "$STAGE_HOME/server/migrate-local.sh"

umask 077
DB_PASSWORD="$(openssl rand -hex 32)"
API_PEPPER="$(openssl rand -hex 32)"
BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"
psql -X -v ON_ERROR_STOP=1 -d postgres -v db_password="$DB_PASSWORD" <<SQL
SELECT format(
  'CREATE ROLE $ROLE_NAME LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L',
  :'db_password'
) \gexec
GRANT ani_api_runtime TO $ROLE_NAME;
SQL

BOOTSTRAP_HASH="$(printf '%s' "$BOOTSTRAP_TOKEN" | sha256sum | awk '{print $1}')"
psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -v token_hash="$BOOTSTRAP_HASH" <<'SQL'
INSERT INTO private.admin_bootstrap_control(singleton,token_hash)
VALUES(true, :'token_hash')
ON CONFLICT(singleton) DO NOTHING;
SQL

cat > "$STAGE_HOME/server/.env" <<EOF
DATABASE_URL=postgresql://$ROLE_NAME:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME?sslmode=disable
ANI_BIND=127.0.0.1
PORT=$API_PORT
ANI_API_PEPPER=$API_PEPPER
ANI_ADMIN_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN
ANI_ALLOWED_ORIGINS=
EOF
chmod 600 "$STAGE_HOME/server/.env"
cd "$STAGE_HOME/server"
npm install --no-audit --no-fund
npm run check
mkdir -p "$STAGE_HOME/logs"
chmod 700 "$STAGE_HOME/logs"

echo
echo "[ANI STAGE] Instalasi staging selesai."
echo "[ANI STAGE] Database baru: $DB_NAME"
echo "[ANI STAGE] Role baru: $ROLE_NAME"
echo "[ANI STAGE] API hanya localhost: http://127.0.0.1:$API_PORT"
echo "[ANI STAGE] Layanan lama port 8787 tidak disentuh."
echo "[ANI STAGE] Jalankan: bash $STAGE_HOME/start-stage.sh"
echo "[ANI STAGE] Owner pertama dibuat melalui browser Redmi setelah API stage ONLINE."
