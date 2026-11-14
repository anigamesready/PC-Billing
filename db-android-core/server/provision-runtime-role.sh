#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
DB_NAME="${ANI_DB_NAME:-ani_games_ready}"
ENV_FILE="$HERE/.env"

command -v psql >/dev/null 2>&1 || { echo "[ANI DB] psql belum terpasang"; exit 1; }
command -v openssl >/dev/null 2>&1 || { echo "[ANI DB] openssl belum terpasang"; exit 1; }

umask 077
DB_PASSWORD="$(openssl rand -hex 32)"
API_PEPPER="$(openssl rand -hex 32)"
BOOTSTRAP_TOKEN="$(openssl rand -hex 32)"

psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -v db_password="$DB_PASSWORD" <<'SQL'
SELECT format(
  'ALTER ROLE ani_api_login LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L',
  :'db_password'
)
WHERE EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_login')
\gexec
SELECT format(
  'CREATE ROLE ani_api_login LOGIN INHERIT NOSUPERUSER NOCREATEDB NOCREATEROLE NOBYPASSRLS PASSWORD %L',
  :'db_password'
)
WHERE NOT EXISTS (SELECT 1 FROM pg_roles WHERE rolname='ani_api_login')
\gexec
GRANT ani_api_runtime TO ani_api_login;
SQL

BOOTSTRAP_HASH="$(printf '%s' "$BOOTSTRAP_TOKEN" | sha256sum | awk '{print $1}')"
psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -v token_hash="$BOOTSTRAP_HASH" <<'SQL'
INSERT INTO private.admin_bootstrap_control(singleton,token_hash)
VALUES(true, :'token_hash')
ON CONFLICT(singleton) DO NOTHING;
SQL

cat > "$ENV_FILE" <<EOF
DATABASE_URL=postgresql://ani_api_login:$DB_PASSWORD@127.0.0.1:5432/$DB_NAME?sslmode=disable
ANI_BIND=127.0.0.1
PORT=8787
ANI_API_PEPPER=$API_PEPPER
ANI_ADMIN_BOOTSTRAP_TOKEN=$BOOTSTRAP_TOKEN
ANI_ALLOWED_ORIGINS=
EOF
chmod 600 "$ENV_FILE"
echo "[ANI DB] Akun runtime ani_api_login dibuat dengan hak minimum."
echo "[ANI DB] File rahasia dibuat: $ENV_FILE (permission 600)."
echo "[ANI DB] Buka browser Redmi ke http://127.0.0.1:8787/setup untuk membuat Owner pertama."
echo "[ANI DB] Token bootstrap disimpan di .env dan tidak dicetak ke layar."
