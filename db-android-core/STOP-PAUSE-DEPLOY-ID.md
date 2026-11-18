# Ani Games Ready — Deploy PAUSE / STOP Billing authorization

This patch adds one Owner-controlled setting, initially OFF, to the existing DB Android API. It does not change rental rows, active sessions, pairing, PC identity, the WoL relay, or timer calculations.

## Before updating
1. Take a copy of the existing DB Android API folder and database backup/snapshot.
2. Stop the current local DB Android API process on the Redmi/Termux phone.
3. Keep the same DATABASE_URL, API pepper, port, Worker/gateway URL and device tokens.

## Install the patch
1. Copy the bundle's `db-android-core/server/server.mjs` over the current API `server.mjs`. Preserve all environment files and local config.
2. Apply the additive SQL migration once to the same PostgreSQL database used by the DB Android API:
   `psql "$DATABASE_URL" -v ON_ERROR_STOP=1 -f db-android-core/schema/012_billing_stop_pause_policy.sql`
3. Start the DB Android API again and check its existing `/health` endpoint.
4. Install the new Admin V12.1.51 APK and PC Billing V12.4.9 EXE built from their matching feature branches.

The migration creates `billing_stop_pause_enabled = false` only when the row does not already exist. Re-running it is safe. The default is locked until an Owner turns the setting ON in Admin.

## Behavior
- OFF: renter PAUSE / STOP and the timer X button are denied by the PC on the next press; the timer keeps running.
- ON: renter PAUSE / STOP and X are permitted for the next press.
- If the API is unavailable or the permission cannot be verified, renter actions are denied (fail-closed).
- Admin remote controls and automatic time expiry do not use this gate.
- The PC reads the policy only after a renter presses one of the controlled buttons; it adds no periodic policy polling.

Do not install the new EXE/APK before the DB Android API and SQL migration are updated. A PC build calling the new policy route against an old server will fail closed and will block renter PAUSE / STOP.
