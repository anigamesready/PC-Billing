# Project State — 2026-11-14

## Current Skill System status
- Hybrid BOTH workflow is being used: GitHub is the permanent instruction/state source; ChatGPT reads the repository through the connected GitHub integration at task start.
- This chat successfully read the required Skill System documents and relevant Skills from `docs/ani-games-ready-ai-skill-system`.
- The connected GitHub repository was readable. Previous setup commits also demonstrated documentation-only updates on the dedicated docs branch.
- The user has not independently confirmed creation of a ChatGPT Project or pasting the Project Instructions. Do not claim Project-level setup is complete.
- No runtime source, database, APK/EXE, server, build workflow, or production configuration was changed in this activation/audit.

## Latest verified source tracks
- PC Billing DB Android: V12.4.8, branch `pc-billing-v12.4.8-DB-Android`, head `f938c574dfbd17ab84b07ca940115a280d3f8d78`, source baseline `bc6cd8561998dc0a2ccd8a8ec31b2d53b6a9ea19`.
- Admin DB Android: newer candidate V12.1.50, branch `admin-v12.1.50-DB-Android`, head `be56ede591c6ebc42b99a02e7731228e02ac40d4`, baseline `9460e8dcbdbf69706408dd0507016cf0037ff153`. V12.1.46 is retained as historical.
- Reseller DB Android: V1.0.6, branch `reseller-v1.0.6-DB-Android`, current head `62e14e8caea62c50269cd62f4122efeed19e8731`, source baseline `a67c2f6318230671a7d7776bf6040c39bca6ff97`.
- DB Android backend/schema: branch `backend/db-android-core-v1`, head `8e9797628ec4508dd5251d32d2a6faa983c7d106`. It contains schema and contract documentation, not a complete local API service.
- Full branch ancestry, workflow limitations and source warnings are recorded in `PROJECT_REGISTRY.md`.

## Redmi Termux server — latest reported state
- Working directory: `~/ani-games-server` (`/data/data/com.termux/files/home/ani-games-server`).
- Server Control 1.0.2 update was reported installed from `ANI_GAMES_READY_SERVER_CONTROL_FIX_1.0.2/UPDATE.sh`.
- Node.js v24.22.3 API uses port 8787.
- Last user-reported state on 2026-11-13: PostgreSQL ONLINE, API ONLINE, local `/health` endpoint responded, and a SQL backup checksum was verified.
- This was not re-queried from the phone in this chat. Current files, current process state, credentials/config, database contents and backup restore have not been revalidated.

## DB1-to-Redmi compatibility findings
- The DB1 live contract audit records 41 tables, 161 routines (152 SECURITY DEFINER), 116 triggers across 17 functions, and 14 active Edge Functions.
- `001_db1_catalog_snapshot.sql` is a full structure reference, not a ready-to-run replacement. `002_core_business_schema.sql` defines 24 operational business tables with constraints and indexes, but no complete local API, authentication handlers, RPC/function bodies, trigger port set or client contract tests.
- The local API still needs secure Admin/Owner/Reseller sessions, PC enrollment/device tokens, heartbeat/ack, sync cursor/pull, rental lookup/session lifecycle/release, offline leases/conflicts, global rental CRUD, reports/exports, audit, rate limits and role/org isolation.
- Do not apply schema files to the existing Redmi database until current server/schema state is inspected and a fresh staging database + restore plan are verified.
- Do not copy DB1/DB2 route/sync infrastructure, route-quiesce triggers, WoL Relay/Telegram sidecars or automatic shutdown scheduler into the local single-server path.

## Safety constraints
- Keep DB Android separate from Supabase DB1/DB2 dual-database development and production routes.
- Never expose PostgreSQL passwords, Supabase service-role keys, signing credentials or customer data in clients/docs.
- No production cutover, destructive sync or cross-database copy without explicit approval, dry-run, verified backup/restore, row-level parity, idempotency, audit and rollback.
- Do not reintroduce automatic shutdown countdown behavior.
- Reseller must remain limited to its own rentals; no Admin/Owner or PC/Windows/WoL control.

## Next action
Obtain a current, sanitized read-only copy/inventory of the Termux project at `~/ani-games-server`. Inspect source files, package dependencies, server routes, auth, schema, startup/control scripts, logs and backup/restore behavior. Then compare each endpoint against the versioned DB1 contract and define missing server work before touching any client branch.
