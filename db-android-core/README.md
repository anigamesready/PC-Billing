# DB Android Core — DB1 structure snapshot

**Source:** Supabase Primary `wzkjpycjizexxcxrfdvr`, read-only catalog inspection on 2026-11-14.

## Included
- 41 tables across `public`, `private`, and `reporting_private`.
- Column types, defaults, nullability, primary/unique/check/foreign-key constraints and indexes.
- No row data, secrets, session tokens, passwords or service-role keys.

## Important compatibility limits
- Supabase Auth is not cloned. The `auth.users` table here is a minimal identity reference only; it has no password/session data.
- Supabase RLS policies, Auth JWT runtime, Edge Functions, triggers, scheduled jobs, Storage, Realtime, and RPC bodies are not in this snapshot.
- 161 PostgreSQL routines and 14 deployed Edge Functions were inventoried separately; these need reviewed ports to the Redmi API, not blind copying.
- Supabase-specific routing/sync tables are retained as catalog references. The DB Android runtime must not use DB1/DB2 route switching or cross-database sync.
- WoL relay tables are retained for compatibility reference only. Relay app/runtime is separate and must not be stopped or reconfigured by database controls.

## Safe use
This file is a schema reference for a fresh local staging database, not an instruction to overwrite any running database. Apply only after testing on an empty throwaway database and resolving all compatibility gaps. Never apply to Supabase DB1/DB2.

## Critical dependencies to implement before connecting apps
1. Owner/Admin/Reseller authentication, authorization, session expiry/revocation, rate limiting and audit log.
2. PC device enrollment/recovery, token hashing/revocation, heartbeat, command queue/acknowledgement.
3. Global rental CRUD with transaction-level locking and active-session protection.
4. Rental session start/end, pause/resume, remaining-time reconciliation, offline lease/queue/idempotency.
5. Reports, monthly/yearly member rankings, per-PC rollups and exports.
6. Relay remains independent; the DB server may store relay metadata only after an explicit future design, but current relay operation stays on its existing backend.

