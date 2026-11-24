# PC Billing — DB Android Integration Audit

Audit date: 2026-11-24
Scope: PC Billing V12.4.9 against the current DB Android staging source and Admin V12.1.53 source.

## Selected PC source
- Repository: anigamesready/PC-Billing.
- Selected PC baseline: feature/pc-v12.4.9-stop-pause-20261118.
- PC runtime version: 12.4.9; Electron appId: com.anigames.billing.v1249dbandroid.
- Original PC V12.4.8 timer/fullscreen source is retained, then the DB Android local API adapter and V12.4.9 Stop/Pause authorization patch are applied.
- The DB Android PC app is built as a separate Windows application. It does not replace the existing PC Billing app identity.

## Current DB Android backend source
- Current DB Android source branch: feature/db-android-stage-simple-menu-v1.
- Current branch head: bd11d9b4e53ece362715a772f210c7e3b13adba1.
- Current API server file blob: 7d0275687629c11faab8ce8080c4f1c0337d1ba1.
- Current Stop/Pause migration 012 blob: 5cc5d22191487a52ce1fa0ae38d0db0666101dad.
- Current WebSocket relay worker blob: 20948e7baf6b1456b154b8f2de4b43e9242e3367.
- The DB Android branch advanced 109 commits after the backend commit pinned by the original V12.4.9 build. The later server changes add Remote Play functionality; the existing PC device routes remain present.
- Migration 012 is byte-identical to the version used by the original PC V12.4.9 build. It creates the Owner-managed billing_stop_pause_enabled setting, the Admin get/set RPCs, and api.device_session_control_policy.
- Fresh staging setup applies schemas 000 and 002–019, with schema 001 intentionally excluded. Existing staging databases must not be re-created; migration 012 must be checked/applied additively if it is missing.

## PC-to-backend compatibility
- PC pairing, disconnect, heartbeat, watchdog, command ACK, alerts, rental lookup, session start/end, rental release, sync cursor, pull and sync endpoints are present in the current DB Android API.
- The current API server still implements POST /device/session-control-policy and calls api.device_session_control_policy using the PC device Bearer token.
- The WebSocket relay accepts /device/* API routes and carries authenticated requests to the loopback-only Termux API.
- The PC build uses the HTTPS endpoint https://ani-games-db-android-stage-ws-relay.anigamesready.workers.dev. It must not use a public HTTP LAN address or expose PostgreSQL directly.
- The PC keeps its pairing identity and local rental/session outboxes. A rejected or unavailable server does not silently erase local state.
- The renter PAUSE/STOP and timer-X controls are fail-closed: they are allowed only when the server returns an explicit enabled=true / allow_stop_pause=true response. Admin remote controls and automatic time expiry bypass this renter-only gate.

## Admin V12.1.53 compatibility
- Admin source branch: feature/admin-v12.1.53-remote-play-shared-db-20261121.
- Admin source commit: 31848d124d89d6be8b3fda62a4d43bb0d235d2f3.
- Its source chain includes the V12.1.51 Owner-only PAUSE/STOP menu, V12.1.52 Remote Play controls, and V12.1.53 shared DB Android port integration.
- Admin workflow run 44903607427 completed successfully and explicitly checked the PAUSE/STOP menu, admin_get_billing_stop_pause_policy, admin_set_billing_stop_pause_policy, and the V12.1.53 package identity.
- The V12.1.53 default local API address is 127.0.0.1:8787. For the currently isolated staging server on port 8788, select http://127.0.0.1:8788 in Admin while running on the Redmi. The PC client uses the HTTPS Worker endpoint instead.

## Automated evidence
- Original PC V12.4.9 workflow run 44319670687 succeeded: patch chain, syntax checks, PC route/SQL/WSS contract checker, runtime smoke tests, locked dependency install, portable Windows EXE build, and app.asar allow-list checks.
- The built EXE SHA-256 was EE059DAE4A92C0500D6B3306BB62797A234E6618135273F701CD4AD78C6A7CCA.
- The original provenance manifest contained incorrect branch/backend labels and the GitHub artifact display name was still V12.4.8. The parity-refresh patch corrects the metadata and pins the build to the current DB Android backend source.
- The parity-refresh patch strengthens tests so the PC smoke test calls /device/session-control-policy and the contract checker requires the Stop/Pause SQL function and Admin Owner RPCs.

## What is not yet proven on the physical Redmi
- A successful /health response proves the API process and database can answer health checks; it does not prove schema 012 exists in the live database.
- The Termux API process may need its server.mjs updated and schema 012 applied once if this staging database predates the Stop/Pause patch. The repository instructions specify a backup first, then a controlled API-only stop, the additive migration, and API restart.
- The current live database migration state, actual PC pairing, real rental-session round trip, physical Windows fullscreen behavior and live WoL were not tested from the build runner.
- Do not reset, recreate or migrate the live database using the fresh-install installer. Verify schema 012 read-only first and only apply it after a backup if missing.

## Safety boundary
- This audit and parity-refresh patch do not modify Termux, PostgreSQL data, Admin source, Cloudflare Worker secrets, Blynk/WoL relay services, or the existing production/Supabase databases.
- Runtime PC changes remain additive to the selected DB Android PC branch. No dual-DB Supabase routing is enabled in this PC runtime.

## Runtime inventory: Supabase/Blynk/WoL (2026-11-24)
- Workflow run 45324894141 extracted the exact V12.4.8 baseline, applied the selected V12.4.9 and DB Android patch chain, then scanned the actual Electron runtime files before packaging.
- The active `main.js`, `preload.js` and `renderer.js` had zero Supabase, DB1/DB2, Blynk or external API matches.
- Active `index.html` only referenced Google Fonts, the DB Android Worker URL and the paired-PC WOL relay command contract. Active `v11-cloud.js` used the DB Android Worker as its default API and kept WOL LAN MAC metadata in the normal DB Android heartbeat.
- A legacy source file `supabase/functions/ani-games-api/index.ts` still contains the old Blynk `iot/status` and `iot/power` handlers with a Supabase-stored Blynk token. This file is copied only into the temporary CI workspace for inspection, then the build explicitly removes `supabase/`; the final app.asar allow-list excludes `supabase/` and `admin.html`. It is not loaded by the PC Billing EXE.
- The PC build now has a strict runtime gate (commit `2499befc0d714061668caac6a9bad056b5329b06`, workflow gate commit `baaad36e48b23810d747438a78a2dcd0ac1d45f6`) that fails if an active packaged runtime file contains Supabase host/config/routing or Blynk API/secret routes.
- WOL is deliberately retained as the PC's local Magic Packet sender plus paired-device command/heartbeat metadata through DB Android. The Blynk cloud relay is a separate Admin-side service and is not part of this PC Billing runtime audit.

## Live stage sync status
- Redmi read-only checks on 2026-11-24 showed the active API process at `~/ani-games-db-android-stage/server`, but its on-disk `server.mjs` did not contain `/device/session-control-policy`; local API and public Worker path returned 404.
- The four Stop/Pause SQL functions checked on the active DB all returned false (missing).
- No changes were made to the Redmi API, PostgreSQL DB, Worker deployment, secrets, rentals, sessions, pairing or relay by this audit.
- A guarded updater is prepared separately. It validates the stage DB and existing Remote Play schema, takes a verified full database dump and server-file backup, applies migration 012 additively, replaces only `server.mjs`, restarts only the stage API PID, then requires the local dummy-token request to return `401 INVALID_DEVICE_TOKEN`. Do not run the fresh-stage installer on the existing database.
