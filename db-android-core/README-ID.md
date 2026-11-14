# Ani Games Ready — Redmi DB Android Local API

## Status
This folder is the isolated DB Android implementation branch. It is not a production cutover and it does not modify Supabase DB1/DB2.

- PostgreSQL core schema: 24 DB1 operational tables, plus local Admin session storage.
- SQL API ports: PC device/pairing/session/sync, Billing Control, Reseller auth/rental CRUD and rotating refresh tokens, and local Admin auth/RPC wrappers.
- Node API: local HTTP adapter for the existing PC device routes, Admin auth/RPC, and Reseller auth/RPC.
- Default network binding: `127.0.0.1:8787` only.
- Blynk/WoL relay: deliberately separate; this service does not start, stop, proxy, or reconfigure it.
- Admin APK and Reseller APK client-side source adaptation/build: still pending source-package and integration audit.
- Redmi installation/runtime regression: not yet run on the actual device.

## Important source rule
Apply only these schema files to a fresh, empty local database:

1. `schema/000_prerequisites.sql`
2. `schema/002_core_business_schema.sql`
3. `schema/003_pc_device_api_functions.sql`
4. `schema/004_billing_reseller_api.sql`
5. `schema/005_runtime_privileges.sql`
6. `schema/006_admin_local_auth_and_rpc.sql`
7. `schema/007_billing_control_commands.sql`
8. `schema/008_local_business_triggers.sql`
9. `schema/009_admin_db1_business_routines.sql`
10. `schema/010_billing_reseller_refresh_and_devices.sql`

Do **not** apply `schema/001_db1_catalog_snapshot.sql`; it is a catalog/reference snapshot, not a migration. Do not import DB1/DB2 routing, route-quiesce/before-image triggers, Telegram outbox, or shutdown scheduler sidecars.

## Termux first-time setup

Run the scripts from this folder after PostgreSQL and Node.js are installed and running:

```bash
bash migrate-local.sh
bash provision-runtime-role.sh
bash install-deps.sh
bash start.sh
```

What each step does:

- `migrate-local.sh`: creates a separate `ani_games_ready` database if needed; refuses to apply the schema if any public/auth/private application tables already exist; applies the eight approved migrations only.
- `provision-runtime-role.sh`: creates a restricted `ani_api_login` role, grants only the approved API role, generates random API/bootstrap secrets, writes a mode-600 `.env`, and stores only the SHA-256 bootstrap-token hash in the local database.
- `install-deps.sh`: installs the pinned `pg` Node dependency and runs a syntax check.
- `start.sh`: loads the protected `.env` and starts the local API.

Then open this address in the Redmi browser:

`http://127.0.0.1:8787/setup`

Create the first local Owner account there. The setup page is available only from localhost and the bootstrap token is never sent to the browser. The database consumes the bootstrap token after the first successful Owner creation.

## API compatibility routes

### PC Billing device API
- `POST /device/enroll`
- `POST /device/heartbeat`
- `POST /device/disconnect`
- `POST /device/watchdog`
- `POST /device/ack`
- `POST /device/alert`
- `POST /device/sync`
- `POST /device/pull`
- `POST /device/sync-cursor`
- `POST /device/rentals`
- `POST /device/test-policy`
- `POST /device/rental/lookup`
- `POST /device/session/start`
- `POST /device/session/end`
- `POST /device/rental/release`

The same device routes are also available under `/functions/v1/ani-games-api/` for the existing Edge Function path shape.

### Admin local authentication
- `POST /auth/v1/token?grant_type=password`
- `POST /auth/v1/token?grant_type=refresh_token`
- `GET /auth/v1/user`
- `POST /auth/v1/logout`
- `POST /rest/v1/rpc/admin_context`
- `POST /rest/v1/rpc/admin_context_v2`
- Admin login lookup, device list/state/rename/disconnect, active sessions/activity, free-test policy/trial, global rental CRUD, alerts, selected sessions, commands, recovery enrollment and period report RPCs from the allowlist in `server.mjs`.

### Billing Control / Reseller
- `POST /rest/v1/rpc/billing_login`
- `POST /rest/v1/rpc/billing_context`
- `POST /rest/v1/rpc/billing_change_password`
- Reseller rental list/create/edit/delete RPCs.
- Billing Control PC command/status RPCs. Reseller role is denied Windows/PC control.

### Health
- `GET /health`

The API does not expose direct PostgREST table reads. It only exposes the explicit function allowlist. If the current Admin/Reseller UI uses direct `.from(...)` queries, the app adapter must be audited and updated before those screens can be connected.

## Security boundaries
- Never put a PostgreSQL password, service-role key, DB secret or bootstrap token in an APK/EXE.
- Node connects as `ani_api_login`, not as the PostgreSQL owner.
- Runtime role has function execution only; it has no direct SELECT/INSERT/UPDATE/DELETE on business tables.
- Local Admin and Billing Control sessions are distinct token families. Tokens are random; only SHA-256 hashes are stored.
- Admin access tokens last 12 hours and refresh tokens rotate with a 30-day expiry.
- Reseller sessions remain separate and are scoped by their own organization.
- Default binding is loopback. Do not set `ANI_BIND=0.0.0.0` until LAN origins, network access, TLS/reverse-proxy and firewall rules are reviewed.
- Request logs exclude passwords, tokens, bootstrap secrets and request bodies.

## Relay separation
Blynk and WoL relay are not part of this local DB server. The Node API returns `RELAY_IS_SEPARATE_SERVICE` for relay routes. Do not use DB start/stop controls to manage the relay service.

## Verification
PostgreSQL CI runs against a disposable PostgreSQL 16 database and synthetic data. A passing CI run does not mean the Redmi phone has been updated, that APKs have been rebuilt, or that Admin/Reseller clients are already connected. Check the current GitHub Actions result before calling a revision tested.

## Rollback
- This work is on `backend/db-android-core-v1`; master and Supabase branches are untouched.
- Before applying schema on Redmi, create and checksum a PostgreSQL backup.
- If the new API is not yet activated, stop only the new Node API process; do not stop PostgreSQL or the separate Blynk/WoL relay.
- Do not drop the local database to roll back. Restore only from a verified backup after reviewing the exact target database.
