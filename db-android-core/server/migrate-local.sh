#!/data/data/com.termux/files/usr/bin/bash
set -euo pipefail
HERE="$(cd "$(dirname "$0")" && pwd)"
SCHEMA="$HERE/../schema"
DB_NAME="${ANI_DB_NAME:-ani_games_ready}"

command -v psql >/dev/null 2>&1 || { echo "[ANI DB] psql belum terpasang"; exit 1; }
command -v createdb >/dev/null 2>&1 || { echo "[ANI DB] createdb belum terpasang"; exit 1; }

if ! psql -d postgres -Atqc "SELECT 1 FROM pg_database WHERE datname='$DB_NAME'" | grep -q 1; then
  createdb "$DB_NAME"
fi

TABLES="$(psql -d "$DB_NAME" -Atqc "SELECT count(*) FROM information_schema.tables WHERE table_schema IN ('public','auth','private','reporting_private') AND table_type='BASE TABLE'")"
if [ "$TABLES" != "0" ]; then
  echo "[ANI DB] STOP: database $DB_NAME sudah berisi $TABLES tabel aplikasi (public/auth/private)."
  echo "[ANI DB] Migrasi ini hanya untuk database staging kosong. Jangan menimpa data."
  exit 2
fi

for file in \
  000_prerequisites.sql \
  002_core_business_schema.sql \
  003_pc_device_api_functions.sql \
  004_billing_reseller_api.sql \
  005_runtime_privileges.sql \
  006_admin_local_auth_and_rpc.sql \
  007_billing_control_commands.sql \
  008_local_business_triggers.sql
  009_admin_db1_business_routines.sql
do
  echo "[ANI DB] Menerapkan $file"
  psql -X -v ON_ERROR_STOP=1 -d "$DB_NAME" -f "$SCHEMA/$file"
done

echo "[ANI DB] Skema DB Android terpasang. Snapshot 001_db1_catalog_snapshot.sql sengaja TIDAK diterapkan."
echo "[ANI DB] Berikutnya jalankan provision-runtime-role.sh."
