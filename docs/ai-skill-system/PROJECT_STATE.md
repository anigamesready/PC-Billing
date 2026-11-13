# Project State — 2026-11-14

## Current system status
- AI Skill System: documentation and modular Skills are stored in isolated GitHub branch `docs/ani-games-ready-ai-skill-system`.
- Hybrid mode selected: GitHub is the permanent source of instructions/state; ChatGPT is the execution workspace and must re-read GitHub at task start.
- ChatGPT integration guide and copy-ready Project Instructions are documented in `CHATGPT_SETUP.md`.
- Manual activation test has not yet been run in a fresh ChatGPT Project/chat. Do not claim the ChatGPT side is fully configured until the user completes that step and the test passes.
- No runtime project source changed during Skill System setup.
- Main focus carried forward: Ani Games Ready DB Android development using Redmi 6 Pro as intended local server, with PC Billing, Admin APK, and Reseller APK as separate client tracks.
- Existing Supabase DB1/DB2 dual-database system remains a separate development/production track. Do not merge these designs or alter production routing as part of DB Android work.

## Current DB Android baselines
- PC Billing: V12.4.8, branch `pc-billing-v12.4.8-DB-Android`.
- Admin APK: V12.1.46, branch `admin-v12.1.46-DB-Android`.
- Reseller APK: V1.0.6, branch `reseller-v1.0.6-DB-Android`.
- Their source commits and baseline ancestry are in `PROJECT_REGISTRY.md`.

## Known backend gap — do not claim feature parity
- Redmi Termux local health endpoint was previously observed responding.
- A local health endpoint is not the full production API.
- PC client requires pairing/enrollment, heartbeat, command acknowledgement, sync cursor/pull, rental lookup, session start/end, rental release, offline leases and conflict handling.
- Admin requires secure admin authentication/context, PC status/recovery, notifications, global rental CRUD, command dispatch/ack, monthly/yearly reporting and export.
- Reseller requires isolated reseller authentication/scope, own-rental CRUD, ACTIVE/DISABLE/EXPIRED states and active-session delete safeguards.
- Full API parity, authorization, TLS/tunnel exposure, migration parity and client regression tests were not established by the repository audit.

## Safety constraints
- Keep DB Android branches independent from Supabase dual-DB branches and production routes.
- Do not expose PostgreSQL passwords, Supabase service-role keys, signing credentials, or privileged secrets in client apps or docs.
- Do not make production cutover, destructive sync, or cross-database copy without explicit approval, dry-run, verified backup, row-level parity, idempotency, audit trail and rollback.
- Do not reintroduce automatic shutdown countdown behavior. Manual/admin Windows controls are separate from database service control.
- Reseller must not gain Admin/Owner permissions or PC/Windows control features.
- Preserve PC timer, fullscreen, pairing, offline queue, rental session and WoL/Blynk behaviors.

## Next step
First finish the manual ChatGPT activation test using `CHATGPT_SETUP.md`. After that, continue Priority 1: inspect the current Redmi server source/workdir and latest three client branch audit documents; map required endpoints and RPC equivalents into a versioned API contract and test plan. Do not start client porting until server-side authentication, authorization, data model, backup/restore, and endpoint contracts are defined.
