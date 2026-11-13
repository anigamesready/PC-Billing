# Next Tasks

## Priority 0 — Activate BOTH workflow (documentation only)
- [ ] User creates a ChatGPT Project named "ANI GAMES READY — Engineering & Operations", if Projects is available.
- [ ] Paste Project Instructions from `CHATGPT_SETUP.md`; otherwise use the start prompt in each new chat.
- [ ] Run the manual activation test in a fresh chat and record the actual result.
- [ ] Verify the connected GitHub repository can be read and that the AI does not claim access when unavailable.
- [ ] Confirm the AI can update only the documentation branch when asked; do not merge it.
- [ ] Do not change runtime source as part of activation.

## Priority 1 — DB Android server/API contract
- [ ] Re-audit the latest Redmi 6 Pro Termux server project and exact working directory/source.
- [ ] Inventory current server endpoints, database schema, auth, backup/restore, startup/restart behavior, logs, and network exposure.
- [ ] Design versioned API contract for PC Billing, Admin, and Reseller separately.
- [ ] Map every required existing RPC/API behavior; identify missing endpoints and authorization boundaries.
- [ ] Define PostgreSQL schema/migrations, indexes, constraints, transaction boundaries, idempotency keys, audit events and conflict strategy.
- [ ] Define automated backup plus tested restore and off-device backup strategy.
- [ ] Create staging-only endpoint tests and role-isolation tests.

## Priority 2 — Client migration planning
- [ ] PC Billing: map pairing, heartbeat, commands, rental sync, session lifecycle, offline leases, conflict queue, timer and WoL/Blynk behavior.
- [ ] Admin: map admin login/context, PC status/recovery, alerts, rental CRUD, commands, reports and Excel/PDF exports.
- [ ] Reseller: map reseller login/session, own-rental CRUD, status lifecycle and active-session delete protection.
- [ ] Resolve remembered-password storage security issue in Reseller.
- [ ] Create a fresh-install test matrix for each client.

## Priority 3 — Build and release discipline
- [ ] Confirm dedicated DB Android build workflows and branch push filters; do not reuse Supabase workflows as DB Android proof.
- [ ] Add artifact provenance: commit SHA, source archive SHA-256, patch list, app version, package ID, workflow run, artifact SHA-256.
- [ ] Run syntax/build/regression tests before producing each candidate.
- [ ] Test clean install and upgrade/replace path before release.
- [ ] Keep master branches and stable artifacts untouched.

## Done only when
- API contract is implemented and tested in staging;
- authentication and role isolation pass;
- automated backup and restore are demonstrated;
- all three clients pass relevant regression tests;
- artifact provenance is recorded;
- production cutover has separate explicit approval and rollback plan.
